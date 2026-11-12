import Foundation
import Testing
@testable import BBIconCore

struct APIModelsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func decodeThreads(_ json: String) throws -> LenientList<ThreadRow> {
        try JSONDecoder().decode(LenientList<ThreadRow>.self, from: Data(json.utf8))
    }

    @Test("a page in bb 0.49.0's shape decodes every row")
    func decodesRecordedThreadsPage() throws {
        let data = try fixture("threads-page")
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        let list = try JSONDecoder().decode(LenientList<ThreadRow>.self, from: data)
        #expect(list.failures.isEmpty)
        #expect(list.elements.count == raw.count)
        // The fixture guarantees the shapes later tasks bucket on.
        #expect(list.elements.contains { $0.lastReadAt == nil })
        #expect(list.elements.contains { $0.status == .active })
        #expect(list.elements.contains { $0.activity.isBusy })
        // bb 0.49.0 sends a runtime on every row.
        #expect(list.elements.allSatisfy { $0.runtime.displayStatus != nil })
    }

    @Test("a thread whose machine is offline decodes as waiting for its host")
    func waitingForHostDecodes() throws {
        // The shape bb 0.49.0's `resolveThreadRuntimeStateFromLatestSession`
        // gives an active thread whose host is disconnected.
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"active","latestAttentionAt":1,"createdAt":1,
          "runtime":{"displayStatus":"waiting-for-host"}}]
        """)
        #expect(list.failures.isEmpty)
        let row = try #require(list.elements.first)
        #expect(row.status == .active)
        #expect(row.runtime.isWaitingForHost)
    }

    @Test("a runtime this build does not know, or none, changes nothing")
    func unknownRuntimeChangesNothing() throws {
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"active","latestAttentionAt":1,"createdAt":1,
          "runtime":{"displayStatus":"hibernating","since":3}},
         {"id":"thr_b","projectId":"proj_a","status":"active","latestAttentionAt":1,"createdAt":1,"runtime":{}},
         {"id":"thr_c","projectId":"proj_a","status":"active","latestAttentionAt":1,"createdAt":1}]
        """)
        #expect(list.failures.isEmpty)
        #expect(list.elements.map(\.runtime) == [ThreadRuntime(displayStatus: "hibernating"), .unknown, .unknown])
        #expect(list.elements.allSatisfy { !$0.runtime.isWaitingForHost })
    }

    @Test("a goal count from bb 0.44 is ignored, as bb 0.49 no longer sends one")
    func goalCountIsIgnored() throws {
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1,
          "activity":{"activeGoalCount":1}}]
        """)
        #expect(list.failures.isEmpty)
        #expect(list.elements.first?.activity == .zero)
    }

    @Test("a status this build does not know reads as idle, as the bb SDK instructs")
    func unknownStatusDecodesAsIdle() throws {
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"hibernating","latestAttentionAt":1,"createdAt":1}]
        """)
        #expect(list.failures.isEmpty)
        #expect(list.elements.first?.status == .idle)
    }

    @Test("missing optional keys fall back to their documented defaults")
    func missingOptionalKeysUseDefaults() throws {
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}]
        """)
        let row = try #require(list.elements.first)
        #expect(row.hasPendingInteraction == false)
        #expect(row.activity == .zero)
        #expect(row.visibility == "visible")
        #expect(row.title == nil)
        #expect(row.lastReadAt == nil)
        #expect(row.runtime == .unknown)
    }

    @Test("an activity object missing a count reads that count as zero")
    func missingActivityCountIsZero() throws {
        let list = try decodeThreads("""
        [{"id":"thr_a","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1,
          "activity":{"activeWorkflowCount":2}}]
        """)
        let row = try #require(list.elements.first)
        #expect(row.activity == ThreadActivity(activeWorkflowCount: 2))
        #expect(row.activity.isBusy)
    }

    @Test("one bad row is dropped and named, and the rest still decode")
    func badElementIsNamedNotFatal() throws {
        let list = try decodeThreads("""
        [{"id":"thr_good","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1},
         {"id":"thr_bad","status":5}]
        """)
        #expect(list.elements.map(\.id) == ["thr_good"])
        #expect(list.failures.count == 1)
        #expect(list.failures.first?.hasPrefix("item 1 (thr_bad): ") == true)
    }

    @Test("a failure names the field that broke, relative to the row")
    func badElementNamesTheField() throws {
        let list = try decodeThreads("""
        [{"id":"thr_bad","projectId":"proj_a","status":"idle","latestAttentionAt":"soon","createdAt":1},
         {"id":"thr_gone","status":"idle","latestAttentionAt":1,"createdAt":1}]
        """)
        #expect(list.elements.isEmpty)
        #expect(list.failures.count == 2)
        #expect(list.failures.first?.hasPrefix("item 0 (thr_bad): latestAttentionAt: ") == true)
        #expect(list.failures.last == "item 1 (thr_gone): missing projectId")
    }

    @Test("a bad row without a string id is named by its index alone")
    func badElementWithoutIDIsNamedByIndex() throws {
        let list = try decodeThreads("""
        [7, {"id":"thr_good","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}]
        """)
        #expect(list.elements.map(\.id) == ["thr_good"])
        #expect(list.failures.count == 1)
        #expect(list.failures.first?.hasPrefix("item 0: ") == true)
    }

    @Test("the project list recorded from bb 0.44.0, unchanged in 0.49.0, decodes with no failures")
    func decodesRecordedProjects() throws {
        let list = try JSONDecoder().decode(LenientList<ProjectRow>.self, from: try fixture("projects"))
        #expect(list.failures.isEmpty)
        #expect(!list.elements.isEmpty)
    }
}
