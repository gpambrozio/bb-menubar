@testable import BBIconCore

/// A thread row with every field defaulted, so a test names only what it is
/// about. The defaults read as an idle, read, visible thread: `lastReadAt` 2
/// is after `latestAttentionAt` 1.
func thread(
    _ id: String = "thr_a",
    status: ThreadStatus = .idle,
    lastReadAt: Double? = 2,
    latestAttentionAt: Double = 1,
    createdAt: Double = 1,
    pending: Bool = false,
    activity: ThreadActivity = .zero,
    title: String? = "T",
    titleFallback: String? = nil,
    projectId: String = "proj_a",
    visibility: String = "visible",
    archivedAt: Double? = nil,
    deletedAt: Double? = nil
) -> ThreadRow {
    ThreadRow(
        id: id,
        projectId: projectId,
        title: title,
        titleFallback: titleFallback,
        status: status,
        visibility: visibility,
        archivedAt: archivedAt,
        deletedAt: deletedAt,
        lastReadAt: lastReadAt,
        latestAttentionAt: latestAttentionAt,
        createdAt: createdAt,
        hasPendingInteraction: pending,
        activity: activity
    )
}
