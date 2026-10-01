import Testing
@testable import BBIconCore

struct TrayViewModelTests {
    private func state(
        _ threads: [ThreadRow],
        status: ConnectionStatus = .connected,
        projectNames: [String: String] = ["proj_a": "web-app"],
        truncated: Bool = false,
        errors: [String] = []
    ) -> BBState {
        BBState(status: status, threads: threads, projectNames: projectNames, truncated: truncated, errors: errors)
    }

    private func build(_ state: BBState) -> TrayViewModel {
        TrayViewModelBuilder.build(state)
    }

    // One thread per bucket, each landing there by the rule's first match.
    private let needsInput = thread("thr_n", pending: true)
    private let failed = thread("thr_f", status: .error, lastReadAt: nil)
    private let readyToReview = thread("thr_r", lastReadAt: nil)
    private let working = thread("thr_w", status: .active)
    private let done = thread("thr_d")

    @Test("shows the done mark, no count, and no rows when bb is not connected", arguments: [
        ConnectionStatus.notRunning, .connecting, .reconnecting,
    ])
    func notConnectedHasNoRowsAndIsDimmed(_ status: ConnectionStatus) {
        let model = build(state([needsInput, failed], status: status, truncated: true))
        #expect(model.sections.isEmpty)
        #expect(model.count == 0)
        #expect(model.icon == .done)
        #expect(!model.truncated)
        #expect(model.status == status)
        #expect(model.isDimmed)
        #expect(!model.needsAttention)
    }

    @Test("is not dimmed while connected")
    func connectedIsNotDimmed() {
        #expect(!build(state([])).isDimmed)
    }

    @Test("carries errors through whatever the connection state")
    func errorsSurvive() {
        #expect(build(state([], status: .notRunning, errors: ["a", "b"])).errors == ["a", "b"])
        #expect(build(state([], errors: ["c"])).errors == ["c"])
    }

    @Test("carries the server's name and the pairing whatever the connection state", arguments: ConnectionStatus.allCases)
    func carriesServerNameAndPairing(_ status: ConnectionStatus) {
        let named = BBState(status: status, threads: [done], projectNames: [:], truncated: false, errors: [], serverName: "mini", paired: "other")
        let model = build(named)
        #expect(model.serverName == "mini")
        #expect(model.paired == "other")
        let local = build(state([done], status: status))
        #expect(local.serverName == nil)
        #expect(local.paired == nil)
    }

    @Test("shows the done mark when there are no threads at all")
    func emptyIsDone() {
        let model = build(state([]))
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.sections.isEmpty)
    }

    @Test("picks the icon of the first non-empty section in section order")
    func iconIsFirstNonEmptySection() {
        // done, working, and failed are all present; only section order puts
        // failed first.
        let model = build(state([done, working, failed]))
        #expect(model.icon == .failed)
        #expect(build(state([done, working])).icon == .working)
        #expect(build(state([done])).icon == .done)
    }

    @Test("counts needs input, failed, and ready to review, never working or done")
    func countIsThreeUrgentBuckets() {
        let model = build(state([done, working, readyToReview, failed, needsInput]))
        #expect(model.count == 3)
        #expect(model.icon == .needsInput)
        #expect(model.sections.map(\.bucket) == [.needsInput, .failed, .readyToReview, .working, .done])
    }

    @Test("asks for attention exactly when a counted bucket has a thread")
    func needsAttention() {
        for row in [needsInput, failed, readyToReview] {
            #expect(build(state([row])).needsAttention, "\(row.id) should need attention")
        }
        for row in [working, done] {
            #expect(!build(state([row])).needsAttention, "\(row.id) should not need attention")
        }
        #expect(!build(state([])).needsAttention)
    }

    @Test("keeps the counted buckets at the head of the section order, which is what makes the icon rule true")
    func countedBucketsLead() {
        let order = TrayViewModelBuilder.sectionOrder
        #expect(order == ThreadBucket.allCases)
        #expect(Set(order.prefix(TrayViewModelBuilder.countedBuckets.count)) == TrayViewModelBuilder.countedBuckets)
    }

    @Test("labels and icon names every bucket")
    func labelsAndIcons() {
        #expect(TrayViewModelBuilder.sectionOrder.map { TrayViewModelBuilder.sectionLabels[$0] } == [
            "Needs input", "Failed", "Ready to review", "Working", "Done",
        ])
        #expect(TrayViewModelBuilder.sectionOrder.map { TrayViewModelBuilder.iconNames[$0] } == [
            "needsInput", "failed", "readyToReview", "working", "done",
        ])
    }

    @Test("leaves archived, deleted, and hidden threads out of rows and counts")
    func excludedThreadsNeverCount() {
        let model = build(state([
            thread("thr_arch", pending: true, archivedAt: 1),
            thread("thr_del", status: .error, lastReadAt: nil, deletedAt: 1),
            thread("thr_hid", lastReadAt: nil, visibility: "hidden"),
            thread("thr_ok"),
        ]))
        #expect(model.count == 0)
        #expect(model.icon == .done)
        #expect(model.sections.flatMap(\.rows).map(\.threadId) == ["thr_ok"])
    }

    @Test("orders rows the way bb's own list does, not the way the API sent them")
    func rowsUseBBListOrder() throws {
        let model = build(state([
            thread("thr_1", lastReadAt: nil, latestAttentionAt: 1, title: "1"),
            thread("thr_3", lastReadAt: nil, latestAttentionAt: 3, title: "3"),
            thread("thr_2", lastReadAt: nil, latestAttentionAt: 2, title: "2"),
        ]))
        let section = try #require(model.sections.first)
        #expect(section.bucket == .readyToReview)
        #expect(section.rows.map(\.label) == ["3", "2", "1"])
    }

    @Test("caps a section at 15 rows and names the rest")
    func capsAt15WithOverflow() throws {
        let many = (0..<17).map { thread(String(format: "thr_%02d", $0), pending: true) }
        let model = build(state(many))
        let section = try #require(model.sections.first)
        #expect(section.rows.count == TrayViewModelBuilder.sectionRowCap)
        #expect(section.rows.count == 15)
        #expect(section.overflow == 2)
        // The count is the whole bucket, not the visible slice.
        #expect(model.count == 17)
    }

    @Test("sorts before it caps, so the fifteen shown are the fifteen most recent")
    func sortsBeforeCap() throws {
        // Handed over oldest first: capping before sorting would keep the
        // fifteen oldest.
        let many = (0..<17).map { thread(String(format: "thr_%02d", $0), latestAttentionAt: Double($0), pending: true) }
        let section = try #require(build(state(many)).sections.first)
        #expect(section.rows.first?.threadId == "thr_16")
        #expect(section.rows.last?.threadId == "thr_02")
        #expect(!section.rows.contains { $0.threadId == "thr_00" || $0.threadId == "thr_01" })
    }

    @Test("excluded threads take no place under the cap")
    func excludedDoNotFillCap() throws {
        let hidden = (0..<5).map { thread("thr_h\($0)", latestAttentionAt: 100, pending: true, visibility: "hidden") }
        let shown = (0..<15).map { thread(String(format: "thr_%02d", $0), pending: true) }
        let section = try #require(build(state(hidden + shown)).sections.first)
        #expect(section.rows.count == 15)
        #expect(section.overflow == 0)
    }

    @Test("carries the thread's id, its title, and its project's name")
    func rowContents() throws {
        let row = try #require(build(state([thread("thr_x", title: "Fix login")])).sections.first?.rows.first)
        #expect(row == TrayThreadRow(threadId: "thr_x", label: "Fix login", projectName: "web-app"))
        #expect(row.id == "thr_x")
    }

    /// (title, titleFallback, expected). bb stores `""` as well as null for an
    /// unnamed thread, and whitespace is as blank as nothing.
    private static let titleCases: [(String?, String?, String)] = [
        ("Fix login", "fb", "Fix login"),
        ("  Fix login\n", nil, "Fix login"),
        ("  ", "fb", "fb"),
        ("", "fb", "fb"),
        (nil, " fb\t", "fb"),
        (nil, nil, "thr_a"),
        ("", "", "thr_a"),
        (" \n", "\t ", "thr_a"),
    ]

    @Test(
        "falls through a blank title to the fallback, then to the id, never an empty row",
        arguments: titleCases
    )
    func blankTitleFallsThrough(_ title: String?, _ titleFallback: String?, _ expected: String) {
        #expect(TrayViewModelBuilder.displayTitle(thread(title: title, titleFallback: titleFallback)) == expected)
    }

    @Test("the row label uses the display title")
    func rowUsesDisplayTitle() {
        let model = build(state([thread(title: "  ", titleFallback: "fb")]))
        #expect(model.sections.first?.rows.first?.label == "fb")
    }

    @Test("names a project bb did not list by its id, rather than leaving it blank")
    func unknownProjectShowsItsId() {
        let model = build(state([thread(projectId: "proj_a")], projectNames: [:]))
        #expect(model.sections.first?.rows.first?.projectName == "proj_a")
        let blank = build(state([thread(projectId: "proj_a")], projectNames: ["proj_a": "  "]))
        #expect(blank.sections.first?.rows.first?.projectName == "proj_a")
    }

    @Test("carries truncation only while connected")
    func truncation() {
        #expect(build(state([], truncated: true)).truncated)
        #expect(!build(state([], truncated: false)).truncated)
    }

    @Test("the empty model is the not-running one")
    func emptyModel() {
        #expect(TrayViewModel.empty == build(.initial))
    }
}
