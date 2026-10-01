import Foundation

/// The five sections of the menu, in section order, which is also icon
/// priority: the first non-empty one draws the tray glyph. bb has no status
/// buckets of its own, so these are Paseo Icon's, kept name for name.
public enum ThreadBucket: String, CaseIterable, Sendable {
    case needsInput
    case failed
    case readyToReview
    case working
    case done
}

/// The one place this app derives state from bb's rows. bb resolves its own
/// per-thread indicator only for plugin UI, never over the HTTP API, so the
/// rule is copied from the spec's table and tested row by row.
public enum BucketRule {
    /// Archived, deleted, and hidden threads are left out everywhere,
    /// counts included.
    public static func isIncluded(_ t: ThreadRow) -> Bool {
        t.archivedAt == nil && t.deletedAt == nil && t.visibility != "hidden"
    }

    /// The negation of bb 0.44.0's read test,
    /// `(e.lastReadAt??0)>=e.latestAttentionAt`. A thread never opened has no
    /// `lastReadAt` and reads as unread; equal timestamps read as read.
    public static func isUnread(_ t: ThreadRow) -> Bool {
        (t.lastReadAt ?? 0) < t.latestAttentionAt
    }

    /// First match wins, in the spec's order. Rule 3 precedes rule 4, so an
    /// unread idle thread is ready to review even while background work runs.
    public static func bucket(for t: ThreadRow) -> ThreadBucket {
        if t.hasPendingInteraction { return .needsInput }
        if t.status == .error && isUnread(t) { return .failed }
        if t.status == .idle && isUnread(t) { return .readyToReview }
        if isRunning(t.status) || t.activity.isBusy { return .working }
        // Idle-and-read and error-and-read both land here.
        return .done
    }

    /// bb's chronological list order: `latestAttentionAt` descending, then
    /// `createdAt` descending, then `id` ascending, so every pair of distinct
    /// rows has one order. bb also floats `active` threads to the top, but
    /// within a section every thread shares a status class, so that step is
    /// left out. A strict order, usable directly with `sorted(by:)`.
    public static func listOrder(_ a: ThreadRow, _ b: ThreadRow) -> Bool {
        if a.latestAttentionAt != b.latestAttentionAt { return a.latestAttentionAt > b.latestAttentionAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }

    private static func isRunning(_ status: ThreadStatus) -> Bool {
        switch status {
        case .starting, .active, .stopping, .pending: true
        case .idle, .error: false
        }
    }
}
