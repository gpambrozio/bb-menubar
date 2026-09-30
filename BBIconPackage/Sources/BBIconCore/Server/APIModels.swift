import Foundation

// The slice of bb 0.44.0's `/api/v1/threads` and `/api/v1/projects` rows this
// app reads. These routes are bb internals, not the Plugin SDK, so decoding is
// lenient by design: unknown fields are ignored, an unknown status reads as
// idle, and a key bb may omit falls back to a documented default. A row that
// still fails is dropped and named by `LenientList`, never fatal to the rest.

/// A thread's run state. bb's SDK tells its own consumers to treat a value
/// they do not know as `idle`, and so does this app.
public enum ThreadStatus: String, Sendable {
    case starting
    case active
    case stopping
    case pending
    case idle
    case error
}

extension ThreadStatus: Decodable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadStatus(rawValue: raw) ?? .idle
    }
}

/// Work a thread is doing in the background, which keeps it "working" even
/// while its status is idle. A count bb omits reads as zero.
public struct ThreadActivity: Decodable, Equatable, Sendable {
    public let activeBackgroundAgentCount: Int
    public let activeBackgroundCommandCount: Int
    public let activeGoalCount: Int
    public let activePlanModeCount: Int
    public let activeWorkflowCount: Int

    public static let zero = ThreadActivity()

    public var isBusy: Bool {
        activeBackgroundAgentCount > 0 || activeBackgroundCommandCount > 0 || activeGoalCount > 0
            || activePlanModeCount > 0 || activeWorkflowCount > 0
    }

    public init(
        activeBackgroundAgentCount: Int = 0,
        activeBackgroundCommandCount: Int = 0,
        activeGoalCount: Int = 0,
        activePlanModeCount: Int = 0,
        activeWorkflowCount: Int = 0
    ) {
        self.activeBackgroundAgentCount = activeBackgroundAgentCount
        self.activeBackgroundCommandCount = activeBackgroundCommandCount
        self.activeGoalCount = activeGoalCount
        self.activePlanModeCount = activePlanModeCount
        self.activeWorkflowCount = activeWorkflowCount
    }

    private enum CodingKeys: String, CodingKey {
        case activeBackgroundAgentCount, activeBackgroundCommandCount, activeGoalCount
        case activePlanModeCount, activeWorkflowCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeBackgroundAgentCount = try c.decodeIfPresent(Int.self, forKey: .activeBackgroundAgentCount) ?? 0
        activeBackgroundCommandCount = try c.decodeIfPresent(Int.self, forKey: .activeBackgroundCommandCount) ?? 0
        activeGoalCount = try c.decodeIfPresent(Int.self, forKey: .activeGoalCount) ?? 0
        activePlanModeCount = try c.decodeIfPresent(Int.self, forKey: .activePlanModeCount) ?? 0
        activeWorkflowCount = try c.decodeIfPresent(Int.self, forKey: .activeWorkflowCount) ?? 0
    }
}

/// One row of `GET /api/v1/threads`: the fields the bucket rule, the list
/// order, and the row label need. Timestamps are bb's epoch milliseconds.
public struct ThreadRow: Decodable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    /// bb stores `""` as well as null for an unnamed thread.
    public let title: String?
    public let titleFallback: String?
    public let status: ThreadStatus
    public let visibility: String
    public let archivedAt: Double?
    public let deletedAt: Double?
    /// Null for a thread that was never opened.
    public let lastReadAt: Double?
    public let latestAttentionAt: Double
    public let createdAt: Double
    public let hasPendingInteraction: Bool
    public let activity: ThreadActivity

    public init(
        id: String,
        projectId: String,
        title: String? = nil,
        titleFallback: String? = nil,
        status: ThreadStatus,
        visibility: String = "visible",
        archivedAt: Double? = nil,
        deletedAt: Double? = nil,
        lastReadAt: Double? = nil,
        latestAttentionAt: Double,
        createdAt: Double,
        hasPendingInteraction: Bool = false,
        activity: ThreadActivity = .zero
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.titleFallback = titleFallback
        self.status = status
        self.visibility = visibility
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.lastReadAt = lastReadAt
        self.latestAttentionAt = latestAttentionAt
        self.createdAt = createdAt
        self.hasPendingInteraction = hasPendingInteraction
        self.activity = activity
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, titleFallback, status, visibility, archivedAt, deletedAt
        case lastReadAt, latestAttentionAt, createdAt, hasPendingInteraction, activity
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decode(String.self, forKey: .projectId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        titleFallback = try c.decodeIfPresent(String.self, forKey: .titleFallback)
        status = try c.decode(ThreadStatus.self, forKey: .status)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "visible"
        archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt)
        deletedAt = try c.decodeIfPresent(Double.self, forKey: .deletedAt)
        lastReadAt = try c.decodeIfPresent(Double.self, forKey: .lastReadAt)
        latestAttentionAt = try c.decode(Double.self, forKey: .latestAttentionAt)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        hasPendingInteraction = try c.decodeIfPresent(Bool.self, forKey: .hasPendingInteraction) ?? false
        activity = try c.decodeIfPresent(ThreadActivity.self, forKey: .activity) ?? .zero
    }
}

/// One row of `GET /api/v1/projects`, for the project name beside a thread.
public struct ProjectRow: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
}

/// A JSON array decoded element by element. An element that fails is skipped
/// and named in `failures` as `item <index> (<id>): <reason>`, so one row bb
/// changed the shape of costs that row, not the whole snapshot.
public struct LenientList<Element: Decodable>: Decodable {
    public let elements: [Element]
    public let failures: [String]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var failures: [String] = []
        while !container.isAtEnd {
            let index = container.currentIndex
            // `JSONDecoder` does not advance an unkeyed container past an
            // element that failed to decode, so decoding `Element` directly
            // would spin on a bad row. `Slot` never throws, so the loop always
            // advances.
            switch try container.decode(Slot.self) {
            case .decoded(let element):
                elements.append(element)
            case .failed(let id, let reason):
                let idSuffix = id.map { " (\($0))" } ?? ""
                failures.append("item \(index)\(idSuffix): \(reason)")
            }
        }
        self.elements = elements
        self.failures = failures
    }

    /// One array slot, decoded while its decoder is current. Keeping the
    /// `Decoder` to decode from later does not work: `JSONDecoder` shares one
    /// decoder object and pops the slot's value once `init(from:)` returns, so
    /// a kept decoder reads the enclosing array instead.
    private enum Slot: Decodable {
        case decoded(Element)
        case failed(id: String?, reason: String)

        init(from decoder: any Decoder) {
            do {
                self = .decoded(try Element(from: decoder))
            } catch {
                self = .failed(
                    id: (try? IDProbe(from: decoder))?.id,
                    reason: failureText(error, below: decoder.codingPath.count)
                )
            }
        }
    }

    /// Just enough of an element to name it. Absent, or not a string, is nil.
    private struct IDProbe: Decodable {
        let id: String?
    }
}

extension LenientList: Sendable where Element: Sendable {}

/// A decoding failure as a sentence naming the field, relative to the element
/// (the first `depth` coding keys are the array index; `BBAPI` passes 0 for a
/// whole body). Anything else goes through `errorText`.
func failureText(_ error: any Error, below depth: Int) -> String {
    guard let error = error as? DecodingError else { return errorText(error) }
    switch error {
    case .keyNotFound(let key, let context):
        return "missing \(fieldPath(context.codingPath.dropFirst(depth) + [key]))"
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        let path = context.codingPath.dropFirst(depth)
        return path.isEmpty ? context.debugDescription : "\(fieldPath(path)): \(context.debugDescription)"
    @unknown default:
        return errorText(error)
    }
}

private func fieldPath(_ keys: some Collection<any CodingKey>) -> String {
    keys.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".")
}
