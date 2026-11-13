import Testing
@testable import BBIconCore

struct BucketTests {
    // MARK: - Inclusion

    @Test(
        "archived, deleted, and hidden threads are left out everywhere",
        arguments: [
            (thread(archivedAt: 1), false),
            (thread(deletedAt: 1), false),
            (thread(visibility: "hidden"), false),
            (thread(), true),
        ]
    )
    func isIncluded(_ row: ThreadRow, _ expected: Bool) {
        #expect(BucketRule.isIncluded(row) == expected)
    }

    // MARK: - Unread

    @Test(
        "a thread is unread exactly when bb's own read test fails",
        arguments: [
            // Never opened: `lastReadAt ?? 0` is before any attention.
            (nil, 1, true),
            (2, 1, false),
            // Equal is read, because bb's test is `>=`.
            (1, 1, false),
            (1, 2, true),
        ] as [(Double?, Double, Bool)]
    )
    func isUnread(lastReadAt: Double?, latestAttentionAt: Double, expected: Bool) {
        let row = thread(lastReadAt: lastReadAt, latestAttentionAt: latestAttentionAt)
        #expect(BucketRule.isUnread(row) == expected)
    }

    // MARK: - Bucket

    /// One row of the spec's bucket table, named so a failure says which rule broke.
    struct BucketCase: Sendable, CustomTestStringConvertible {
        let name: String
        let row: ThreadRow
        let expected: ThreadBucket

        var testDescription: String { name }
    }

    // `thread()` defaults to read; a thread never opened is unread.
    private static let unread: Double? = nil

    static let bucketCases: [BucketCase] = [
        BucketCase(
            name: "a pending interaction outranks an unread error",
            row: thread(status: .error, lastReadAt: unread, pending: true),
            expected: .needsInput
        ),
        BucketCase(name: "unread error", row: thread(status: .error, lastReadAt: unread), expected: .failed),
        BucketCase(name: "read error", row: thread(status: .error), expected: .done),
        BucketCase(name: "unread idle", row: thread(status: .idle, lastReadAt: unread), expected: .readyToReview),
        BucketCase(name: "read idle", row: thread(status: .idle), expected: .done),
        BucketCase(name: "starting", row: thread(status: .starting), expected: .working),
        BucketCase(name: "active", row: thread(status: .active), expected: .working),
        BucketCase(name: "stopping", row: thread(status: .stopping), expected: .working),
        BucketCase(name: "pending status", row: thread(status: .pending), expected: .working),
        BucketCase(
            name: "read idle with a background command",
            row: thread(status: .idle, activity: ThreadActivity(activeBackgroundCommandCount: 1)),
            expected: .working
        ),
        BucketCase(
            name: "unread idle with busy activity is ready to review, because rule 3 precedes rule 4",
            row: thread(status: .idle, lastReadAt: unread, activity: ThreadActivity(activePlanModeCount: 1)),
            expected: .readyToReview
        ),
        BucketCase(
            name: "active while its machine is offline stays working",
            row: thread(status: .active, runtime: offline),
            expected: .working
        ),
        BucketCase(
            name: "a pending interaction on an offline machine still needs input",
            row: thread(status: .active, pending: true, runtime: offline),
            expected: .needsInput
        ),
    ]

    @Test("each thread lands in the first bucket whose rule matches", arguments: bucketCases)
    func bucket(_ testCase: BucketCase) {
        #expect(BucketRule.bucket(for: testCase.row) == testCase.expected)
    }

    // MARK: - Running now

    @Test(
        "a working thread runs now unless the only thing running is on an offline machine",
        arguments: [
            (thread(status: .active), true),
            (thread(status: .active, runtime: ThreadRuntime(displayStatus: "active")), true),
            (thread(status: .starting), true),
            (thread(status: .pending), true),
            (thread(status: .active, runtime: offline), false),
            // bb's own rule still counts background activity as working.
            (thread(status: .active, activity: ThreadActivity(activeWorkflowCount: 1), runtime: offline), true),
            (thread(status: .idle, activity: ThreadActivity(activeBackgroundAgentCount: 1)), true),
            (thread(status: .idle), false),
            // A display status this build does not know changes nothing.
            (thread(status: .active, runtime: ThreadRuntime(displayStatus: "hibernating")), true),
        ]
    )
    func isRunningNow(_ row: ThreadRow, _ expected: Bool) {
        #expect(BucketRule.isRunningNow(row) == expected)
    }

    @Test("only waiting-for-host marks a thread's machine offline", arguments: [
        (ThreadRuntime.unknown, false),
        (ThreadRuntime(displayStatus: "active"), false),
        (ThreadRuntime(displayStatus: "provisioning"), false),
        (ThreadRuntime(displayStatus: "Waiting-For-Host"), false),
        (offline, true),
    ])
    func isWaitingForHost(_ runtime: ThreadRuntime, _ expected: Bool) {
        #expect(BucketRule.isWaitingForHost(thread(status: .active, runtime: runtime)) == expected)
    }

    // MARK: - List order

    @Test("rows sort by attention, newest first")
    func attentionDescending() {
        let newer = thread("thr_b", latestAttentionAt: 5)
        let older = thread("thr_a", latestAttentionAt: 3)
        #expect(BucketRule.listOrder(newer, older))
        #expect(!BucketRule.listOrder(older, newer))
    }

    @Test("equal attention falls back to creation, newest first")
    func createdAtBreaksTies() {
        let newer = thread("thr_b", latestAttentionAt: 5, createdAt: 4)
        let older = thread("thr_a", latestAttentionAt: 5, createdAt: 2)
        #expect(BucketRule.listOrder(newer, older))
        #expect(!BucketRule.listOrder(older, newer))
    }

    @Test("equal attention and creation fall back to id, ascending")
    func idBreaksTies() {
        let first = thread("thr_a", latestAttentionAt: 5, createdAt: 4)
        let second = thread("thr_b", latestAttentionAt: 5, createdAt: 4)
        #expect(BucketRule.listOrder(first, second))
        #expect(!BucketRule.listOrder(second, first))
        // Strict: a row never sorts before itself.
        #expect(!BucketRule.listOrder(first, first))
    }
}
