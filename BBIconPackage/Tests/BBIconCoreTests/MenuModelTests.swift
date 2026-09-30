import Testing
@testable import BBIconCore

struct MenuModelTests {
    private func row(_ threadId: String = "thr_a", label: String = "Fix login", projectName: String = "web-app") -> TrayThreadRow {
        TrayThreadRow(threadId: threadId, label: label, projectName: projectName)
    }

    private func model(
        sections: [TrayMenuSection] = [],
        status: ConnectionStatus = .connected,
        truncated: Bool = false,
        errors: [String] = []
    ) -> TrayViewModel {
        TrayViewModel(
            icon: sections.first?.bucket ?? .done,
            count: 0,
            sections: sections,
            status: status,
            truncated: truncated,
            errors: errors
        )
    }

    private func build(_ model: TrayViewModel, loginItemEnabled: Bool = false) -> [MenuItem] {
        MenuModel.build(model, loginItemEnabled: loginItemEnabled)
    }

    private func notes(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .note(_, let text) = $0 { text } else { nil } }
    }

    private func headings(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .sectionHeading(_, let label) = $0 { label } else { nil } }
    }

    @Test("lays out one connected thread, then status, then the footer")
    func connectedLayout() {
        let threadRow = row()
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [threadRow], overflow: 0)]), loginItemEnabled: true)
        #expect(items == [
            .sectionHeading(bucket: .needsInput, label: "Needs input"),
            .thread(row: threadRow, label: "Fix login  ·  web-app"),
            .separator(index: 0),
            .status(label: "bb · connected"),
            .separator(index: 1),
            .openApp,
            .loginItem(enabled: true),
            .separator(index: 2),
            .quit,
        ])
    }

    @Test("says there are no threads when connected with none, before the status block")
    func connectedEmptySaysNoThreads() {
        let items = build(model())
        #expect(items == [
            .note(index: 0, text: "No threads"),
            .separator(index: 0),
            .status(label: "bb · connected"),
            .separator(index: 1),
            .openApp,
            .loginItem(enabled: false),
            .separator(index: 2),
            .quit,
        ])
    }

    @Test("holds only the status line and the footer when bb is not running")
    func notRunningLayout() {
        let items = build(model(status: .notRunning))
        #expect(items == [
            .status(label: "bb is not running"),
            .separator(index: 0),
            .openApp,
            .loginItem(enabled: false),
            .separator(index: 1),
            .quit,
        ])
    }

    @Test(
        "claims nothing about threads while connecting or reconnecting",
        arguments: [(ConnectionStatus.connecting, "bb · connecting"), (.reconnecting, "bb · reconnecting")]
    )
    func notConnectedClaimsNoThreads(_ status: ConnectionStatus, _ label: String) {
        // Rows are dropped while not connected, so "No threads" would be a
        // claim this app cannot vouch for, and a section drawn from a stale
        // model would be worse.
        let items = build(model(
            sections: [TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0)],
            status: status,
            truncated: true
        ))
        #expect(items.first == .status(label: label))
        #expect(notes(items).isEmpty)
        #expect(headings(items).isEmpty)
    }

    @Test("has status text for every connection state")
    func statusTextIsComplete() {
        // Over `allCases`, so a status added later cannot ship without text.
        for status in ConnectionStatus.allCases {
            #expect(MenuModel.statusText[status] != nil, "\(status) has no status text")
        }
        #expect(MenuModel.statusText[.notRunning] == "bb is not running")
    }

    @Test("leads with the error rows, in order, then a rule")
    func errorsLeadTheMenu() {
        let items = build(model(errors: ["first", "second"]))
        #expect(Array(items.prefix(3)) == [
            .error(index: 0, detail: "first"),
            .error(index: 1, detail: "second"),
            .separator(index: 0),
        ])
    }

    @Test("leads with the error rows even when bb is not running")
    func errorsLeadWhenNotRunning() {
        let items = build(model(status: .notRunning, errors: ["bb's runtime file could not be read: pid"]))
        #expect(Array(items.prefix(3)) == [
            .error(index: 0, detail: "bb's runtime file could not be read: pid"),
            .separator(index: 0),
            .status(label: "bb is not running"),
        ])
    }

    @Test("labels sections with Paseo Icon's words, in section order")
    func sectionLabels() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row("t1")], overflow: 0),
            TrayMenuSection(bucket: .failed, rows: [row("t2")], overflow: 0),
            TrayMenuSection(bucket: .readyToReview, rows: [row("t3")], overflow: 0),
            TrayMenuSection(bucket: .working, rows: [row("t4")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row("t5")], overflow: 0),
        ]))
        #expect(headings(items) == ["Needs input", "Failed", "Ready to review", "Working", "Done"])
    }

    @Test("rules between sections, but never above the first one")
    func separatorsBetweenSections() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row("t1")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row("t2")], overflow: 0),
        ]))
        let shape = items.prefix(5).map { item -> String in
            switch item {
            case .separator: "---"
            case .sectionHeading(_, let label): label
            case .thread(let row, _): row.threadId
            default: "?"
            }
        }
        #expect(shape == ["Needs input", "t1", "---", "Done", "t2"])
    }

    @Test("renders the overflow row rather than dropping rows silently")
    func overflow() {
        let items = build(model(sections: [TrayMenuSection(bucket: .working, rows: [row()], overflow: 3)]))
        let overflow = items.compactMap { item -> String? in
            if case .overflow(_, let label) = item { return label }
            return nil
        }
        #expect(overflow == ["…and 3 more"])
    }

    @Test("says so when not every thread is shown, after the sections")
    func truncationIsANote() throws {
        let items = build(model(sections: [TrayMenuSection(bucket: .done, rows: [row()], overflow: 0)], truncated: true))
        #expect(notes(items) == ["Not all threads shown"])
        let noteIndex = try #require(items.firstIndex(of: .note(index: 0, text: "Not all threads shown")))
        let rowIndex = try #require(items.firstIndex { if case .thread = $0 { true } else { false } })
        let statusIndex = try #require(items.firstIndex(of: .status(label: "bb · connected")))
        #expect(rowIndex < noteIndex)
        #expect(noteIndex < statusIndex)
    }

    @Test("joins a row's title and project with the separator")
    func rowLabel() {
        #expect(MenuModel.rowLabel(row(label: "Migrate schema", projectName: "api")) == "Migrate schema  ·  api")
    }

    @Test("always ends with the footer, and the login item reflects the state it was given")
    func footer() {
        let items = build(model(), loginItemEnabled: true)
        #expect(items.last == .quit)
        #expect(items.contains(.openApp))
        #expect(items.contains(.loginItem(enabled: true)))
        #expect(!build(model(), loginItemEnabled: false).contains(.loginItem(enabled: true)))
    }

    @Test("gives every item a distinct identity, so SwiftUI does not collapse two rows")
    func idsAreUnique() {
        let items = build(model(
            sections: [
                // Both sections overflow by the same number on purpose: the
                // two rows then carry the same label, and only the bucket
                // tells them apart.
                TrayMenuSection(bucket: .needsInput, rows: [row("t1"), row("t2")], overflow: 2),
                TrayMenuSection(bucket: .failed, rows: [row("t3")], overflow: 2),
                TrayMenuSection(bucket: .done, rows: [row("t4")], overflow: 0),
            ],
            truncated: true,
            // Identical text on purpose: an id built from the text would
            // collapse them.
            errors: ["boom", "boom"]
        ))
        let overflowRows = items.filter { if case .overflow = $0 { true } else { false } }
        let errorRows = items.filter { if case .error = $0 { true } else { false } }
        #expect(overflowRows.count == 2)
        #expect(errorRows.count == 2)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("keys a thread row by its thread id")
    func threadRowId() {
        #expect(MenuItem.thread(row: row("thr_x"), label: "x").id == "row:thr_x")
        #expect(MenuItem.error(index: 1, detail: "d").id == "error:1")
        #expect(MenuItem.status(label: "s").id == "status")
    }
}
