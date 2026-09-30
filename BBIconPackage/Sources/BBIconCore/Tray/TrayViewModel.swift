import Foundation

/// The tray icon is always one bucket's icon: the highest-priority non-empty
/// one, or `done` (the bb mark) when there are no threads at all.
public typealias TrayIconState = ThreadBucket

public struct TrayThreadRow: Equatable, Sendable, Identifiable {
    public let threadId: String
    /// The thread's display title: see `TrayViewModelBuilder.displayTitle`.
    public let label: String
    /// The project's name, or its id when bb did not list it.
    public let projectName: String

    // One bb server, so the thread id alone is unique. Paseo Icon needed a
    // composite host-and-workspace id here; bb Icon has no hosts to collide.
    public var id: String { threadId }
}

public struct TrayMenuSection: Equatable, Sendable, Identifiable {
    public let bucket: ThreadBucket
    public let rows: [TrayThreadRow]
    /// Rows dropped by the cap. Always rendered, never silent.
    public let overflow: Int

    public var id: String { bucket.rawValue }
}

public struct TrayViewModel: Equatable, Sendable {
    public let icon: TrayIconState
    public let count: Int
    public let sections: [TrayMenuSection]
    public let status: ConnectionStatus
    /// bb had more threads than the page ceiling. The rows are a subset, and
    /// the menu says so.
    public let truncated: Bool
    /// Error rows, in `ErrorSource` order. Carried whatever the connection
    /// state, because the reason bb cannot be reached is most useful exactly
    /// when it cannot.
    public let errors: [String]

    /// True when at least one thread sits in a bucket that needs the user:
    /// the same three buckets `count` is drawn from. The menu bar item draws
    /// itself red on this, so the rule lives here rather than in the label,
    /// where no test could reach it. `icon` is the first non-empty bucket in
    /// section order and the three counted buckets lead that order, so this
    /// says the same thing `count > 0` does, in the icon's own terms.
    public var needsAttention: Bool { TrayViewModelBuilder.countedBuckets.contains(icon) }

    /// Dimmed means "not connected", whatever the reason: the rows are gone
    /// while connecting and reconnecting too, so the glyph is dimmed the same
    /// way it is when bb is not running.
    public var isDimmed: Bool { status != .connected }

    init(
        icon: TrayIconState,
        count: Int,
        sections: [TrayMenuSection],
        status: ConnectionStatus,
        truncated: Bool,
        errors: [String]
    ) {
        self.icon = icon
        self.count = count
        self.sections = sections
        self.status = status
        self.truncated = truncated
        self.errors = errors
    }

    public static let empty = TrayViewModel(icon: .done, count: 0, sections: [], status: .notRunning, truncated: false, errors: [])
}

public enum TrayViewModelBuilder {
    /// Section order, which is also icon priority. bb has no status buckets
    /// of its own, so these are Paseo Icon's, which it copied verbatim from
    /// `STATUS_BUCKET_ORDER` in the Paseo app's `sidebar-status-view-model.ts`.
    public static let sectionOrder: [ThreadBucket] = ThreadBucket.allCases

    /// Paseo Icon's labels, from `STATUS_BUCKET_LABELS`, kept word for word:
    /// the two tray apps say the same thing about the same kind of state.
    public static let sectionLabels: [ThreadBucket: String] = [
        .needsInput: "Needs input",
        .failed: "Failed",
        .readyToReview: "Ready to review",
        .working: "Working",
        .done: "Done",
    ]

    /// The asset name for each bucket's icon.
    public static let iconNames: [ThreadBucket: String] = [
        .needsInput: "needsInput",
        .failed: "failed",
        .readyToReview: "readyToReview",
        .working: "working",
        .done: "done",
    ]

    /// The buckets the icon's count is drawn from. `done` is excluded: it is
    /// the resting state, so counting it would badge every quiet thread. So is
    /// `working`: a thread that is busy does not need the user yet.
    static let countedBuckets: Set<ThreadBucket> = [.needsInput, .failed, .readyToReview]

    /// Rows in a section cap here; the rest become an explicit overflow row.
    static let sectionRowCap = 15

    public static func build(_ state: BBState) -> TrayViewModel {
        // Rows from anything but a live connection are data we cannot vouch
        // for, so they never reach the icon, the count, or the menu. The store
        // drops them on the way out of `connected`; this holds even for a
        // state that still carries some.
        guard state.status == .connected else {
            return TrayViewModel(icon: .done, count: 0, sections: [], status: state.status, truncated: false, errors: state.errors)
        }

        var threadsByBucket: [ThreadBucket: [ThreadRow]] = [:]
        var counted = 0
        for thread in state.threads where BucketRule.isIncluded(thread) {
            let bucket = BucketRule.bucket(for: thread)
            threadsByBucket[bucket, default: []].append(thread)
            if countedBuckets.contains(bucket) { counted += 1 }
        }

        let sections = sectionOrder.compactMap { bucket -> TrayMenuSection? in
            guard let threads = threadsByBucket[bucket], !threads.isEmpty else { return nil }
            // Sorted before the cap, so the fifteen shown are the fifteen bb's
            // own list would put first, not whichever the API sent first.
            let rows = threads.sorted(by: BucketRule.listOrder).map { row($0, projectNames: state.projectNames) }
            if rows.count <= sectionRowCap { return TrayMenuSection(bucket: bucket, rows: rows, overflow: 0) }
            return TrayMenuSection(bucket: bucket, rows: Array(rows.prefix(sectionRowCap)), overflow: rows.count - sectionRowCap)
        }

        return TrayViewModel(
            // `sections` is already in sectionOrder and holds only non-empty
            // buckets, so its first entry is the highest-priority one. No
            // threads at all falls back to `done`, the resting state.
            icon: sections.first?.bucket ?? .done,
            count: counted,
            sections: sections,
            status: state.status,
            truncated: state.truncated,
            errors: state.errors
        )
    }

    /// The thread's `title`, else its `titleFallback`, else its id. bb stores
    /// `""` as well as null for an unnamed thread, and a title of spaces is as
    /// blank as none, so each tier is trimmed before it is tested: a row is
    /// never drawn empty.
    public static func displayTitle(_ t: ThreadRow) -> String {
        nonBlank(t.title) ?? nonBlank(t.titleFallback) ?? t.id
    }

    private static func row(_ t: ThreadRow, projectNames: [String: String]) -> TrayThreadRow {
        TrayThreadRow(
            threadId: t.id,
            label: displayTitle(t),
            // A project bb did not list, or listed without a name, shows its
            // id rather than an empty half of the row.
            projectName: nonBlank(projectNames[t.projectId]) ?? t.projectId
        )
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
