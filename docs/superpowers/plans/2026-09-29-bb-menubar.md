# bb Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar app, bb Icon, that shows the most urgent state across the bb threads of this Mac's bb desktop app and opens a thread in bb on click.

**Architecture:** A Swift package with the same split as Paseo Icon: `BBIconCore` (all logic, tested with injected fakes) and `BBIcon` (a window-style `MenuBarExtra` shell). Core discovers the bb server from `~/.bb/bb-app-runtime.json`, subscribes to bb's `/ws` invalidations, re-fetches `/api/v1/threads` and `/api/v1/projects`, buckets threads, and builds the menu as data. Tray UI files are ported from `~/repositories/paseo-menubar` with renames.

**Tech Stack:** Swift 6.1 (strict concurrency), SwiftUI `MenuBarExtra`, Swift Testing, `pointfreeco/swift-clocks` (tests only), Node + vitest + sharp + lucide-static for `scripts/`.

**Spec:** `docs/superpowers/specs/2026-09-29-bb-menubar-design.md` — read it first; this plan argues from it. The reference implementation for every ported file is `~/repositories/paseo-menubar` (read its `AGENTS.md`).

## Global Constraints

- Swift package at `BBIconPackage/`, `swift-tools-version: 6.1`, `platforms: [.macOS(.v14)]`, arm64 only.
- Targets: `BBIconCore` (library), `BBIcon` (executable), `BBIconCoreTests` (tests, `resources: [.copy("Fixtures")]`). `BBIcon` declares `resources: [.copy("Resources/TrayIcons")]`.
- Only dependency: `.package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4")`, used by the test target only. No `swift-sodium`.
- Display name `bb Icon`, bundle `BBIcon.app`, bundle id `br.eng.gustavo.bb-menubar`, `LSUIElement` true, minimum macOS `14.0`.
- bb desktop bundle id: `dev.bb.desktop`. Runtime file: `~/.bb/bb-app-runtime.json`.
- License AGPL-3.0-or-later (copy `LICENSE` from paseo-menubar).
- **If it does not touch AppKit or SwiftUI, it does not belong in the `BBIcon` target.**
- Never crash the tray: no force unwraps, no `try!`, no `fatalError`, no unchecked arithmetic on server-supplied numbers.
- No silent caps: every truncation renders a visible row; every `MenuItem` has a unique `id`.
- Every failure the user can hit is named in the menu's error rows (`MessageError.message`), never swallowed.
- Section order, labels, and glyphs exactly as in the spec's "Say what Paseo Icon says" table.
- `npm install` on this machine needs `--cache "$TMPDIR/npm-cache"` (root-owned `~/.npm`).
- Do not launch the built app to check work; a human verifies the menu bar (Task 10).

## Review Focus

1. **A fetch that finishes after a reconnect or a server change** — its result must be discarded, not applied over newer state. Test in Task 6 (`staleFetchIsDiscarded`).
2. **bb quits and relaunches on a new port** — the runtime file changes `serverUrl`; the old realtime session must stop and a new one start against the new URL, with no rows from the old one. Test in Task 7 (`serverURLChangeIsReported`) and wiring in Task 9.
3. **A burst of `/ws` invalidations while a fetch is in flight** — exactly one follow-up fetch, not zero and not one per message. Test in Task 6 (`invalidationDuringFetchRefetchesOnce`).
4. **A runtime file whose `pid` is dead** (bb crashed without cleaning up) — must read as not running, not as a server to dial forever. Test in Task 7 (`deadPidIsNotRunning`).
5. **Titles that are empty strings or whitespace** (bb stores `""` for some unnamed threads) — fall through to `titleFallback`, then the id, never render an empty row. Test in Task 4 (`blankTitleFallsThrough`).

---

## File Structure

```
bb-menubar/
  LICENSE  README.md  AGENTS.md  CHANGELOG.md  .gitignore
  package.json  package-lock.json  vitest.config.ts  tsconfig.typecheck.json
  assets/bb-logo.svg                      vendored bb mark
  scripts/make-icons.mjs (+ .test.mjs)    tray glyphs + app icon
  scripts/native-bundle.mjs (+ .test.mjs) unsigned .app bundle
  BBIconPackage/Package.swift
  BBIconPackage/Sources/BBIconCore/
    ErrorText.swift
    Server/APIModels.swift       ThreadRow, ProjectRow, LenientList
    Server/HTTPClient.swift      HTTPClient protocol + URLSession impl
    Server/BBAPI.swift           paging snapshot fetch, open-thread POST, BBAPIError
    Server/WebSocketTransport.swift          protocol (ported DaemonTransport)
    Server/URLSessionWebSocketTransport.swift ported
    Server/RealtimeSession.swift
    Runtime/RuntimeFile.swift
    Runtime/FSEventsWatch.swift  ported, path filter injected
    Runtime/DirectoryWatcher.swift ported RegistryWatcher, generic
    Runtime/RuntimeSession.swift
    Store/ThreadStore.swift      BBState, ConnectionStatus, ErrorSource, ThreadStore
    Tray/Bucket.swift            ThreadBucket, BucketRule
    Tray/TrayViewModel.swift
    Tray/MenuModel.swift
  BBIconPackage/Sources/BBIcon/
    BBIconApp.swift  AppCoordinator.swift  MenuContent.swift  MenuBarLabel.swift  TrayIcons.swift
    Resources/TrayIcons/.gitkeep
  BBIconPackage/Tests/BBIconCoreTests/
    Fixtures/threads-page.json  Fixtures/projects.json  Fixtures/ws-messages.jsonl
    Support/FakeTransport.swift  Support/FakeHTTPClient.swift  Support/ThreadFixtures.swift
    one *Tests.swift per source file above
```

---

### Task 1: Repository scaffold

**Files:**
- Create: `BBIconPackage/Package.swift`, `BBIconPackage/Sources/BBIconCore/ErrorText.swift`, `BBIconPackage/Sources/BBIcon/BBIconApp.swift` (placeholder `@main` that exits — replaced in Task 9), `BBIconPackage/Sources/BBIcon/Resources/TrayIcons/.gitkeep`, `BBIconPackage/Tests/BBIconCoreTests/ErrorTextTests.swift`, `BBIconPackage/Tests/BBIconCoreTests/Fixtures/.gitkeep`
- Create: `LICENSE`, `.gitignore`, `package.json`, `vitest.config.ts`, `tsconfig.typecheck.json`

**Interfaces:**
- Produces: `public protocol MessageError: Error { var message: String { get } }`, `public func errorText(_ error: any Error) -> String` — copied verbatim from paseo-menubar `ErrorText.swift`.

- [ ] **Step 1:** Copy `LICENSE`, `ErrorText.swift`, `vitest.config.ts`, `tsconfig.typecheck.json` from paseo-menubar. `.gitignore`: `node_modules/`, `release/`, `assets/generated/`, `BBIconPackage/.build/`, `BBIconPackage/Sources/BBIcon/Resources/TrayIcons/*.png`.
- [ ] **Step 2:** `package.json`: name `bb-menubar`, `productName` `bb Icon`, version `0.1.0`, `type: module`, license `AGPL-3.0-or-later`; scripts `typecheck`, `test` (`vitest run && swift test --package-path BBIconPackage`), `test:swift`, `icons` (`node scripts/make-icons.mjs`), `dist` (`npm run icons && node scripts/native-bundle.mjs`); devDependencies `@types/node`, `lucide-static` `1.42.0`, `sharp`, `typescript`, `vitest` at paseo-menubar's versions. Run `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install --cache "$TMPDIR/npm-cache"`.
- [ ] **Step 3:** `Package.swift` per Global Constraints. `ErrorTextTests.swift` has one test, `messageErrorUsesItsMessage`, asserting `errorText(E()) == "boom"` for a local `struct E: MessageError { var message: String { "boom" } }`.
- [ ] **Step 4:** Run `swift build --package-path BBIconPackage && swift test --package-path BBIconPackage`. Expected: build succeeds, tests pass.
- [ ] **Step 5:** Commit `chore: scaffold the bb Icon package and tooling`.

---

### Task 2: API models and recorded fixtures

**Files:**
- Create: `Sources/BBIconCore/Server/APIModels.swift`, `Tests/BBIconCoreTests/APIModelsTests.swift`, `Tests/BBIconCoreTests/Fixtures/threads-page.json`, `Fixtures/projects.json`, `Fixtures/ws-messages.jsonl`, `Tests/BBIconCoreTests/Support/ThreadFixtures.swift`

**Interfaces:**
- Produces:
  - `public enum ThreadStatus: String, Sendable { case starting, active, stopping, pending, idle, error }` — `Decodable`; an unknown string decodes to `.idle`.
  - `public struct ThreadActivity: Decodable, Equatable, Sendable` with `Int` fields `activeBackgroundAgentCount`, `activeBackgroundCommandCount`, `activeGoalCount`, `activePlanModeCount`, `activeWorkflowCount` (each missing key → 0), `public static let zero`, `public var isBusy: Bool` (any count > 0).
  - `public struct ThreadRow: Decodable, Equatable, Sendable`: `id: String`, `projectId: String`, `title: String?`, `titleFallback: String?`, `status: ThreadStatus`, `visibility: String` (missing → `"visible"`), `archivedAt: Double?`, `deletedAt: Double?`, `lastReadAt: Double?`, `latestAttentionAt: Double`, `createdAt: Double`, `hasPendingInteraction: Bool` (missing → false), `activity: ThreadActivity` (missing → `.zero`). Plus a memberwise `public init` with those defaults, for tests.
  - `public struct ProjectRow: Decodable, Equatable, Sendable { public let id: String; public let name: String }`
  - `public struct LenientList<Element: Decodable>: Decodable { public let elements: [Element]; public let failures: [String] }` — decodes a JSON array element by element; an element that fails is skipped and recorded as `"item \(index)\(idSuffix): \(errorText)"`, where `idSuffix` is `" (\(id))"` when the element has a string `id`.
- `ThreadFixtures.swift` produces `func thread(_ id: String = "thr_a", status: ThreadStatus = .idle, lastReadAt: Double? = 2, latestAttentionAt: Double = 1, createdAt: Double = 1, pending: Bool = false, activity: ThreadActivity = .zero, title: String? = "T", titleFallback: String? = nil, projectId: String = "proj_a", visibility: String = "visible", archivedAt: Double? = nil, deletedAt: Double? = nil) -> ThreadRow` for later tasks.

- [ ] **Step 1: Record fixtures from the running bb.** Read `serverUrl` from `~/.bb/bb-app-runtime.json`, then:
  `curl -s "$URL/api/v1/threads?archived=false&limit=200&offset=0"`, `curl -s "$URL/api/v1/projects"`, and capture ~20 `/ws` messages after sending `{"type":"subscribe","target":{"kind":"thread-list"}}` (a 15-line Node script with the global `WebSocket` is enough; do not commit it). Anonymise: replace every `title`, `titleFallback`, `name`, `environmentPath`, `environmentBranchName`, `gitRemoteUrl` with fictional values; keep every key and every non-text value. Keep at least one row each with `lastReadAt: null`, `status: "active"`, and non-zero activity — hand-edit one in if the capture has none.
- [ ] **Step 2: Write failing tests** in `APIModelsTests.swift`:
  - `decodesRecordedThreadsPage`: `LenientList<ThreadRow>` over `threads-page.json` → `failures.isEmpty`, `elements.count` equals the fixture's array count.
  - `unknownStatusDecodesAsIdle`: `{"status":"hibernating",…}` → `.idle`.
  - `missingOptionalKeysUseDefaults`: a row without `hasPendingInteraction`, `activity`, `visibility` → `false`, `.zero`, `"visible"`.
  - `badElementIsNamedNotFatal`: array of one good row and one `{"id":"thr_bad","status":5}` → `elements.count == 1`, `failures == ["item 1 (thr_bad): …"]` (assert prefix `"item 1 (thr_bad): "`).
  - `decodesRecordedProjects`: `LenientList<ProjectRow>` over `projects.json` → no failures.
- [ ] **Step 3:** Run `swift test --package-path BBIconPackage --filter APIModelsTests`. Expected: FAIL (types missing).
- [ ] **Step 4:** Implement `APIModels.swift`. `LenientList` decodes with `unkeyedContainer`. `JSONDecoder` does not advance an unkeyed container past an element that failed, so each slot is first decoded as a private `struct Slot: Decodable` whose `init(from:)` stores the `Decoder` and always succeeds. Then decode `Element(from: slot.decoder)`; on failure, decode `IDProbe(from: slot.decoder)` (`struct IDProbe: Decodable { let id: String? }`, where `try?` failure means no id) to name it. The loop always advances, so it cannot spin.
- [ ] **Step 5:** Run the filter again. Expected: PASS.
- [ ] **Step 6:** Commit `feat(core): lenient bb API models with recorded fixtures`.

---

### Task 3: Buckets, unread, and list order

**Files:**
- Create: `Sources/BBIconCore/Tray/Bucket.swift`, `Tests/BBIconCoreTests/BucketTests.swift`

**Interfaces:**
- Consumes: `ThreadRow`, `ThreadStatus`, `ThreadActivity` (Task 2).
- Produces:
  - `public enum ThreadBucket: String, CaseIterable, Sendable { case needsInput, failed, readyToReview, working, done }`
  - `public enum BucketRule` with `public static func isIncluded(_ t: ThreadRow) -> Bool`, `isUnread(_:) -> Bool`, `bucket(for:) -> ThreadBucket`, `listOrder(_ a: ThreadRow, _ b: ThreadRow) -> Bool` (true when `a` sorts before `b`).

- [ ] **Step 1: Write failing tests** (a parameterised `@Test(arguments:)` table where natural):
  - `isIncluded`: false for `archivedAt: 1`, `deletedAt: 1`, `visibility: "hidden"`; true otherwise.
  - `isUnread`: `(lastReadAt: nil, latestAttentionAt: 1) → true`; `(2, 1) → false`; `(1, 1) → false` (equal is read — bb's `>=`); `(1, 2) → true`.
  - `bucket(for:)`, first match wins:
    - `pending: true, status: .error, unread` → `.needsInput`
    - `.error`, unread → `.failed`; `.error`, read → `.done`
    - `.idle`, unread → `.readyToReview`; `.idle`, read → `.done`
    - each of `.starting .active .stopping .pending`, read → `.working`
    - `.idle`, read, `activity.activeBackgroundCommandCount: 1` → `.working`
    - `.idle`, unread, busy activity → `.readyToReview` (rule 3 precedes rule 4)
  - `listOrder`: higher `latestAttentionAt` first; tie → higher `createdAt` first; tie → smaller `id` first.
- [ ] **Step 2:** Run `--filter BucketTests`. Expected: FAIL.
- [ ] **Step 3:** Implement per the spec's numbered rule list. `isUnread` is `(t.lastReadAt ?? 0) < t.latestAttentionAt`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): bucket rule, unread test, and bb's list order`.

---

### Task 4: Store, view model, and menu model

**Files:**
- Create: `Sources/BBIconCore/Store/ThreadStore.swift`, `Sources/BBIconCore/Tray/TrayViewModel.swift`, `Sources/BBIconCore/Tray/MenuModel.swift`
- Test: `Tests/BBIconCoreTests/ThreadStoreTests.swift`, `TrayViewModelTests.swift`, `MenuModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
  - `public struct BBSnapshot: Equatable, Sendable { public let threads: [ThreadRow]; public let projects: [ProjectRow]; public let truncated: Bool; public let decodeFailures: [String] }` (+ public init).
  - `public enum ConnectionStatus: String, Sendable { case notRunning, connecting, connected, reconnecting }`
  - `public enum ErrorSource: Int, CaseIterable, Sendable { case runtime, fetch, decode, open }` — display order is case order.
  - `public struct BBState: Equatable, Sendable { status, threads: [ThreadRow], projectNames: [String: String], truncated: Bool, errors: [String] }` with `public static let initial` (`.notRunning`, empty).
  - `@MainActor public final class ThreadStore`: `public init()`, `public private(set) var state: BBState`, `public func setStatus(_:)` (any status other than `.connected` clears `threads`, `projectNames`, `truncated`), `public func apply(_ snapshot: BBSnapshot)` (sets threads/projects/truncated; sets or clears `.decode` from `decodeFailures`, joined as `"Some threads could not be read: " + failures.joined(separator: "; ")`), `public func setError(_ source: ErrorSource, _ message: String?)`, `public func subscribe(_ listener: @escaping () -> Void) -> () -> Void`. Listeners fire only when `state` actually changes.
  - `public struct TrayThreadRow: Equatable, Sendable, Identifiable { threadId, label, projectName; id = threadId }`
  - `public struct TrayMenuSection: Equatable, Sendable, Identifiable { bucket: ThreadBucket, rows: [TrayThreadRow], overflow: Int; id = bucket.rawValue }`
  - `public struct TrayViewModel: Equatable, Sendable { icon: ThreadBucket, count: Int, sections: [TrayMenuSection], status: ConnectionStatus, truncated: Bool, errors: [String]; var needsAttention: Bool; var isDimmed: Bool { status != .connected }; static let empty }`
  - `public enum TrayViewModelBuilder`: `sectionOrder: [ThreadBucket]` (= `ThreadBucket.allCases` order), `sectionLabels` (`Needs input`, `Failed`, `Ready to review`, `Working`, `Done`), `iconNames` (`needsInput`, `failed`, `readyToReview`, `working`, `done`), `countedBuckets: Set` = needsInput, failed, readyToReview, `sectionRowCap = 15`, `public static func build(_ state: BBState) -> TrayViewModel`, `public static func displayTitle(_ t: ThreadRow) -> String`.
  - `public enum MenuItem: Equatable, Sendable, Identifiable`: `sectionHeading(bucket:label:)`, `thread(row:label:)`, `overflow(bucket:label:)`, `separator(index:)`, `note(index:text:)`, `error(index:detail:)`, `status(label:)`, `openApp`, `loginItem(enabled:)`, `quit`. Ids follow paseo-menubar's `MenuItem.id` scheme (`"row:\(threadId)"`, `"error:\(index)"`, `"status"`, …).
  - `public enum MenuModel`: `statusText: [ConnectionStatus: String]` = `connected: "bb · connected"`, `connecting: "bb · connecting"`, `reconnecting: "bb · reconnecting"`, `notRunning: "bb is not running"`; `public static func rowLabel(_ row: TrayThreadRow) -> String` (`label + "  ·  " + projectName`); `public static func build(_ model: TrayViewModel, loginItemEnabled: Bool) -> [MenuItem]`.

- [ ] **Step 1: Write failing tests.**
  - `ThreadStoreTests`: `leavingConnectedClearsRows` (apply snapshot, `setStatus(.reconnecting)` → `threads.isEmpty`, `projectNames.isEmpty`); `listenersFireOnlyOnChange` (same status twice → one notification); `errorsOrderedBySource` (`setError(.open, "b")`, `setError(.runtime, "a")` → `errors == ["a", "b"]`); `decodeFailuresBecomeOneError`.
  - `TrayViewModelTests`:
    - `notConnectedHasNoRowsAndIsDimmed`: state `.notRunning` with threads → `sections.isEmpty`, `count == 0`, `icon == .done`, `isDimmed`.
    - `iconIsFirstNonEmptySection` and `countIsThreeUrgentBuckets` (one of each bucket → `count == 3`, `icon == .needsInput`).
    - `excludedThreadsNeverCount` (archived/hidden/deleted in state → absent).
    - `rowsUseBBListOrder` (three idle-unread threads with attention 1, 3, 2 → labels ordered 3, 2, 1).
    - `capsAt15WithOverflow` (17 → 15 rows, `overflow == 2`).
    - `blankTitleFallsThrough`: `title: "  "`, `titleFallback: "fb"` → `"fb"`; both nil/blank → the thread id.
    - `unknownProjectShowsItsId`: `projectNames` empty → `projectName == "proj_a"`.
  - `MenuModelTests`:
    - `connectedLayout`: one Needs-input thread → `[.sectionHeading, .thread, .separator(0), .status("bb · connected"), .separator(1), .openApp, .loginItem, .separator(2), .quit]`.
    - `connectedEmptySaysNoThreads`: note `"No threads"` precedes the status block.
    - `notRunningLayout`: `[.status("bb is not running"), .separator, .openApp, .loginItem, .separator, .quit]` — no "No threads" note.
    - `errorsLeadTheMenu`: two errors → `.error(0,…)`, `.error(1,…)`, then `.separator`.
    - `truncationIsANote`: `truncated` → note `"Not all threads shown"` after the sections.
    - `idsAreUnique`: build a menu with two overflowing sections and two errors → `Set(items.map(\.id)).count == items.count`.
- [ ] **Step 2:** Run `--filter "ThreadStoreTests|TrayViewModelTests|MenuModelTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement. Port the structure and comments of paseo-menubar's `TrayViewModel.swift`/`MenuModel.swift`, dropping hosts, agents, `unknownStates`, and host naming. `displayTitle` trims whitespace before testing emptiness. Rows sorted with `BucketRule.listOrder` before the cap.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): thread store, tray view model, and menu model`.

---

### Task 5: HTTP API client

**Files:**
- Create: `Sources/BBIconCore/Server/HTTPClient.swift`, `Sources/BBIconCore/Server/BBAPI.swift`, `Tests/BBIconCoreTests/Support/FakeHTTPClient.swift`, `Tests/BBIconCoreTests/BBAPITests.swift`

**Interfaces:**
- Consumes: `LenientList`, `ThreadRow`, `ProjectRow`, `BBSnapshot`, `MessageError`.
- Produces:
  - `public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`; `public struct URLSessionHTTPClient: HTTPClient` (ephemeral `URLSession`, 10 s request timeout).
  - `public enum BBAPIError: MessageError, Equatable`: `authenticationRequired` → `"bb now requires authentication (HTTP 401/403); bb Icon cannot read it"`, `status(Int, path: String)` → `"bb answered HTTP \(code) for \(path)"`, `undecodable(path: String, detail: String)` → `"bb sent something bb Icon cannot read at \(path): \(detail)"`, `noWindow` → `"bb had no open window to show the thread in"`.
  - `public struct BBAPI: Sendable`: `public init(serverURL: URL, http: any HTTPClient)`, `public static let pageSize = 200`, `public static let maxPages = 25`, `public func fetchSnapshot() async throws -> BBSnapshot`, `public func openThread(_ threadId: String) async throws` (throws `.noWindow` when `delivered == 0`).

- [ ] **Step 1: Write failing tests** with `FakeHTTPClient` (an actor-backed fake that records requests and answers from a `[String: (Int, Data)]` keyed by path+query):
  - `fetchesProjectsAndPagesThreads`: page 1 returns 200 rows, page 2 returns 3 → requests hit `/api/v1/threads?archived=false&limit=200&offset=0` then `offset=200`, `threads.count == 203`, `truncated == false`, plus one `/api/v1/projects`.
  - `stopsAtMaxPagesAndReportsTruncation`: every page full → exactly 25 thread requests, `truncated == true`.
  - `http401IsAuthenticationRequired` (and 403).
  - `http500IsNamedWithPath`.
  - `nonArrayBodyIsUndecodable`.
  - `elementFailuresSurfaceAsDecodeFailures`.
  - `openThreadPostsFileNull`: request method `POST`, path `/api/v1/threads/thr_a/open`, `Content-Type: application/json`, body decodes to `{"file": null}`; response `{"delivered":1}` → no throw.
  - `openThreadWithNoWindowThrows`: `{"delivered":0}` → `BBAPIError.noWindow`.
  - `serverURLWithTrailingSlashBuildsSamePaths`.
- [ ] **Step 2:** Run `--filter BBAPITests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Build URLs with `URLComponents`, appending `api/v1/...` to the server URL's path. Projects and the thread pages are fetched sequentially (loopback; simplicity over speed). `offset` arithmetic is `page * pageSize` with `page < maxPages`, so it cannot overflow.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Opt-in live test.** Add `LiveBBTests.swift` with `@Test(.enabled(if: ProcessInfo.processInfo.environment["BB_ICON_LIVE"] == "1")) func liveSnapshotDecodes()`. It reads `~/.bb/bb-app-runtime.json` with `RuntimeFile.parse` (Task 7 — if Task 7 is not done yet, parse `serverUrl` with `JSONSerialization` and switch this test to `RuntimeFile.parse` in Task 7), calls `BBAPI(serverURL:http: URLSessionHTTPClient()).fetchSnapshot()`, and asserts `decodeFailures.isEmpty` and `!truncated`. It never calls `openThread`: that would navigate the user's bb window. Run `BB_ICON_LIVE=1 swift test --package-path BBIconPackage --filter LiveBBTests`. Expected: PASS against the running bb. Without the variable it is skipped.
- [ ] **Step 6:** Commit `feat(core): bb HTTP client with explicit paging and open-thread`.

---

### Task 6: Realtime session

**Files:**
- Create: `Sources/BBIconCore/Server/WebSocketTransport.swift`, `Sources/BBIconCore/Server/URLSessionWebSocketTransport.swift`, `Sources/BBIconCore/Server/RealtimeSession.swift`, `Tests/BBIconCoreTests/Support/FakeTransport.swift`, `Tests/BBIconCoreTests/RealtimeSessionTests.swift`

**Interfaces:**
- Consumes: `BBSnapshot`, `ConnectionStatus`, `errorText`.
- Produces:
  - `WebSocketTransport.swift`: paseo-menubar's `DaemonTransport.swift` renamed — `TransportFrame`, `TransportClose`, `TransportRequest`, `@MainActor public protocol WebSocketTransport`, `public typealias TransportFactory = @MainActor (TransportRequest) -> any WebSocketTransport`.
  - `URLSessionWebSocketTransport.swift`: copied, conforming to `WebSocketTransport`.
  - `@MainActor public final class RealtimeSession`:
    `public init(serverURL: URL, makeTransport: @escaping TransportFactory, fetch: @escaping @Sendable () async throws -> BBSnapshot, onStatus: @escaping (ConnectionStatus) -> Void, onSnapshot: @escaping (BBSnapshot) -> Void, onError: @escaping (String?) -> Void, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(250))`,
    `public func start()`, `public func stop()`,
    `public static func websocketURL(for serverURL: URL) -> URL` (`http→ws`, `https→wss`, path replaced by `/ws`, query and fragment dropped),
    `public static let initialBackoff: Duration = .seconds(1)`, `maxBackoff: Duration = .seconds(30)`, `public static func nextBackoff(after current: Duration) -> Duration` (×1.5, capped).
  - `FakeTransport`: paseo-menubar's, conforming to `WebSocketTransport`, plus `simulateClose(code:)`.

Behaviour (the tests pin it):
- `start()` → `onStatus(.connecting)`, create transport for `websocketURL`, `connect()`.
- open → send exactly `{"type":"subscribe","target":{"kind":"thread-list"}}` and `{"type":"subscribe","target":{"kind":"project-list"}}`, reset backoff, fetch immediately (no debounce).
- fetch success → `onError(nil)`, `onSnapshot`, and `onStatus(.connected)` the first time after each open.
- fetch failure → `onError(errorText(error))`, then close the transport, which takes the reconnect path.
- text frame `{"type":"changed","entity":"thread"|"project",…}` → debounced fetch; every other frame, and malformed JSON, is ignored.
- close/error → `onStatus(.reconnecting)`, reconnect after the current backoff, then advance backoff.
- `stop()` cancels timers and pending fetch results, closes the transport, and emits nothing further.
- Every fetch is tagged with a generation that open, close, and stop increment; a result from an older generation is dropped.

- [ ] **Step 1: Write failing tests** (use `TestClock` from `Clocks`):
  - `websocketURLMapping`: `http://127.0.0.1:38886` → `ws://127.0.0.1:38886/ws`; `https://h.example/base?x=1` → `wss://h.example/ws`.
  - `backoffSequence`: 1, 1.5, 2.25 s … capped at 30 s.
  - `subscribesOnOpenAndFetches`: after `simulateOpen`, `sentText` equals the two subscribe messages, fetch called once, statuses `[.connecting, .connected]`.
  - `changedMessagesAreDebouncedIntoOneFetch`: five `changed` thread frames within 100 ms → after advancing 250 ms, exactly one extra fetch.
  - `ignoresOtherMessages`: `plugin-signal`, `{"type":"changed","entity":"host"}`, `"not json"` → no fetch.
  - `invalidationDuringFetchRefetchesOnce`: a fetch that suspends on a continuation; send three `changed` frames and let the debounce elapse; release the fetch → exactly one follow-up fetch.
  - `closeReconnectsWithBackoff`: `simulateClose` → `.reconnecting`; after 1 s a second transport is created; close again → the next one arrives after 1.5 s.
  - `staleFetchIsDiscarded`: start a suspended fetch, close the transport, reopen the new one, release the old fetch → its snapshot is never delivered.
  - `fetchFailureNamesErrorAndReconnects`: fetch throws `BBAPIError.authenticationRequired` → `onError` got its message and the transport was closed.
  - `stopIsSilent`: after `stop()`, advancing the clock and firing frames produce no callbacks.
- [ ] **Step 2:** Run `--filter RealtimeSessionTests`. Expected: FAIL.
- [ ] **Step 3:** Implement per the behaviour list. At most one fetch runs at a time, with a `dirty` flag for invalidations that arrive during it.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): realtime session over bb's /ws invalidations`.

---

### Task 7: Runtime discovery

**Files:**
- Create: `Sources/BBIconCore/Runtime/RuntimeFile.swift`, `Sources/BBIconCore/Runtime/FSEventsWatch.swift`, `Sources/BBIconCore/Runtime/DirectoryWatcher.swift`, `Sources/BBIconCore/Runtime/RuntimeSession.swift`
- Test: `Tests/BBIconCoreTests/RuntimeFileTests.swift`, `DirectoryWatcherTests.swift`, `RuntimeSessionTests.swift`

**Interfaces:**
- Produces:
  - `public struct RuntimeInfo: Equatable, Sendable { public let pid: Int32; public let serverURL: URL; public let version: String? }`
  - `public enum RuntimeFileError: MessageError { case malformed(String) }` → `"bb's runtime file could not be read: \(detail)"`.
  - `public enum RuntimeFile`: `public static let fileName = "bb-app-runtime.json"`, `public static func directory(home: String) -> String` (`home + "/.bb"`), `public static func parse(_ data: Data) throws -> RuntimeInfo` (requires `pid` as an integer in `1...Int32.max` and `serverUrl` with an `http` or `https` scheme and a host; anything else is `.malformed` naming the field), `public static func isRuntimeFileEvent(_ path: String) -> Bool` (last path component starts with `"bb-app-runtime"`, which also catches an atomic-write temp file).
  - `FSEventsWatch.open(directory:include:onChange:onError:)` — paseo-menubar's, with `include: @escaping @Sendable (String) -> Bool` replacing the hard-coded `RegistryWatcher.isRegistryFileEvent`.
  - `DirectoryWatcher` — paseo-menubar's `RegistryWatcher`, renamed, minus `isRegistryFileEvent`; same `Open` typealias, `watch(_:)`, and `ensureAttached()`.
  - `public enum RuntimeResolution: Equatable, Sendable { case running(RuntimeInfo); case notRunning(error: String?) }`
  - `@MainActor public final class RuntimeSession`: `public init(readFile: @escaping @Sendable () throws -> Data?, isProcessAlive: @escaping (Int32) -> Bool, isAppRunning: @escaping () -> Bool, watch: @escaping (@escaping () -> Void) -> () -> Void, afterRead: (() -> Void)? = nil, onChange: @escaping (RuntimeResolution) -> Void, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(300), pollInterval: Duration = .seconds(30))`, `public func start()`, `public func refresh()` (debounced re-read; the coordinator calls it on `NSWorkspace` launch/terminate), `public func stop()`. `readFile` returns nil when the file does not exist.

Resolution rule: file missing → `.notRunning(error: nil)`; parse throws → `.notRunning(error: message)`; pid not alive or `isAppRunning()` false → `.notRunning(error: nil)`; otherwise `.running(info)`. `onChange` fires only when the resolution differs from the last one delivered, and always once after `start()`.

- [ ] **Step 1: Write failing tests.**
  - `RuntimeFileTests`: `parsesRecordedShape` (the spec's example JSON), `rejectsMissingPid`, `rejectsNonHTTPServerURL` (`"ftp://x"`), `rejectsPidOutOfRange` (`0`, `-1`, `9999999999`), `runtimeFileEventFilter` (`/Users/x/.bb/bb-app-runtime.json` → true, `/Users/x/.bb/bb-app-runtime.json.tmp-123` → true, `/Users/x/.bb/bb.db-wal` → false).
  - `DirectoryWatcherTests`: port paseo-menubar's `RegistryWatcherTests` cases that do not involve the removed file filter.
  - `RuntimeSessionTests` (`TestClock`, closures over mutable test state):
    - `missingFileIsNotRunning` → first delivery `.notRunning(error: nil)`.
    - `malformedFileNamesError`.
    - `deadPidIsNotRunning`: valid file, `isProcessAlive` false → `.notRunning(error: nil)`.
    - `appNotRunningIsNotRunning`: valid file, pid alive, `isAppRunning` false.
    - `runningDeliversInfoOnce`: two refreshes with the same file → one `.running` delivery.
    - `serverURLChangeIsReported`: file changes port → a second `.running` with the new URL.
    - `refreshIsDebounced`: five `refresh()` calls within 100 ms → one read after 300 ms.
    - `pollRereadsWithoutEvents`: advance 30 s → a read happened.
    - `watchEventTriggersRead`: invoke the callback captured by the injected `watch` → a read after the debounce.
    - `stopIsSilent`.
- [ ] **Step 2:** Run `--filter "RuntimeFileTests|DirectoryWatcherTests|RuntimeSessionTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement. Port `FSEventsWatch` with its comments intact (the retain/release and `UseCFTypes` notes are load-bearing). `readFile` runs detached (`Task.detached`), as paseo-menubar's `AppCoordinator` does for the registry read.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): discover bb from its runtime file`.

---

### Task 8: Tray glyphs and app icon

**Files:**
- Create: `assets/bb-logo.svg`, `scripts/make-icons.mjs`, `scripts/make-icons.test.mjs`

**Interfaces:**
- Produces: `assets/generated/{needsInput,failed,readyToReview,working,done}Template{,@2x}.png`, the same ten files in `BBIconPackage/Sources/BBIcon/Resources/TrayIcons/`, and `assets/generated/icon.png` (1024 px app icon). File stems must equal `TrayViewModelBuilder.iconNames` values.

- [ ] **Step 1:** Copy the newest `bb-logo-*.svg` from `/Applications/bb.app/Contents/Resources/app.asar.unpacked/node_modules/bb-app/app/dist/assets/` to `assets/bb-logo.svg` unmodified. Record the source path and bb version (0.44.0) in a comment in `make-icons.mjs`.
- [ ] **Step 2: Write failing test** `make-icons.test.mjs`: after running the generator into a temp root, the ten tray PNGs exist in both output directories; each 1x is 16×16 and each @2x is 32×32 (`sharp(...).metadata()`); the `GLYPHS` export maps exactly `needsInput→megaphone`, `failed→circle-x`, `readyToReview→triangle-alert`, `working→loader-pinwheel`, `done→bb-logo`.
- [ ] **Step 3:** Run `npx vitest run scripts/make-icons.test.mjs`. Expected: FAIL.
- [ ] **Step 4:** Port paseo-menubar's `scripts/make-icons.mjs`: paths → `BBIconPackage/Sources/BBIcon/...`, `PASEO_LOGO_PATH` → `assets/bb-logo.svg`, bucket names per `GLYPHS`, and a `root` parameter for the test. The app icon is the bb mark on the same tile, with the same notification-badge treatment. Retune `PASEO_MARK_SCALE`/`PASEO_MARK_STROKE` (renamed `BB_MARK_*`) by rendering at 16 and 32 px and comparing ink coverage to the Lucide glyphs, as paseo-menubar's comment describes; record the chosen values and why.
- [ ] **Step 5:** Run the test, then `npm run icons`. Expected: PASS, and the files exist.
- [ ] **Step 6:** Commit `feat: tray glyphs and app icon with the bb mark`.

---

### Task 9: The menu bar app

**Files:**
- Create: `Sources/BBIcon/TrayIcons.swift`, `MenuBarLabel.swift`, `MenuContent.swift`, `AppCoordinator.swift`; replace `BBIconApp.swift`

**Interfaces:**
- Consumes: everything in `BBIconCore`.
- `AppCoordinator` (`@MainActor @Observable`) exposes `model: TrayViewModel`, `loginItemEnabled: Bool`, `start()`, `stop()`, `openThread(_ row: TrayThreadRow)`, `openApp()`, `showError(_ detail: String)`, `setLoginItem(_:)`, `quit()`.

- [ ] **Step 1:** Port `TrayIcons.swift` (keyed by `ThreadBucket`, error text `"Missing tray icon: \(file).png. Run \`npm run icons\`."`) and `MenuBarLabel.swift`. The label takes `isDimmed`; when dimmed it renders the glyph at 40 % opacity through the same `ImageRenderer` path and stays a template image.
- [ ] **Step 2:** Port `MenuContent.swift`, mapping the new `MenuItem` cases: `.thread` → `coordinator.openThread(row)`; `.overflow` and `.openApp` → `coordinator.openApp()`; `.error` → a row that calls `showError(detail)`; `.status` → a non-interactive row. Remove the host summary/expansion code.
- [ ] **Step 3:** Write `AppCoordinator.swift`, following paseo-menubar's structure (debounced rebuild, login item via `SMAppService`, alerts):
  - `RuntimeSession` wired with `readFile` reading `RuntimeFile.directory(home: NSHomeDirectory()) + "/" + RuntimeFile.fileName` (a missing file returns nil), `isProcessAlive` = `kill(pid, 0) == 0 || errno == EPERM`, `isAppRunning` = `!NSRunningApplication.runningApplications(withBundleIdentifier: "dev.bb.desktop").isEmpty`, `watch` via a `DirectoryWatcher` over `FSEventsWatch.open(directory:include: RuntimeFile.isRuntimeFileEvent, …)`, and `afterRead` → `watcher.ensureAttached()`.
  - Observe `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`; when the app's bundle id is `dev.bb.desktop`, call `runtimeSession.refresh()`.
  - On `.running(info)`: if `info.serverURL` differs from the current session's, stop the old `RealtimeSession`, `store.setStatus(.connecting)`, and start a new one with `BBAPI(serverURL:http: URLSessionHTTPClient())`, `makeTransport: { URLSessionWebSocketTransport(request: $0) }`, and callbacks into `store` (`onError` → `.fetch`). Clear `.runtime`.
  - On `.notRunning(error)`: stop and drop the realtime session, `store.setStatus(.notRunning)`, `store.setError(.runtime, error)`.
  - `openThread`: activate bb.app (`NSWorkspace.shared.openApplication(at:configuration:)` using `urlForApplication(withBundleIdentifier: "dev.bb.desktop")`), then `try await api.openThread(row.threadId)`; set `.open` to the error text or nil. With no current `BBAPI`, only activate.
  - `openApp`: activate or launch bb.app; if bb.app cannot be found, `report` `"bb is not installed"`.
- [ ] **Step 4:** Replace `BBIconApp.swift` with paseo-menubar's `PaseoIconApp.swift` shape (`MenuBarExtra` `.window` style, `AppDelegate` with the single-instance guard, `.accessory` policy, `TrayIcons.preflight()` alert), minus `hostsExpanded`. Alert titles say `bb Icon — …`.
- [ ] **Step 5:** Run `swift build --package-path BBIconPackage && swift test --package-path BBIconPackage`. Expected: build clean with no warnings from strict concurrency; all tests pass.
- [ ] **Step 6:** Commit `feat(app): the bb Icon menu bar shell`.

---

### Task 10: Bundle, docs, and human verification

**Files:**
- Create: `scripts/native-bundle.mjs`, `scripts/native-bundle.test.mjs`, `README.md`, `AGENTS.md`, `CHANGELOG.md`

- [ ] **Step 1: Write failing test** `native-bundle.test.mjs`: `BUNDLE_NAME === "BBIcon"`, `DISPLAY_NAME === "bb Icon"`, `BUNDLE_ID === "br.eng.gustavo.bb-menubar"`, `MIN_MACOS === "14.0"`; `infoPlist({version: "0.1.0"})` contains `LSUIElement` `<true/>` and `LSMinimumSystemVersion` `14.0`; the README states "macOS 14 or later".
- [ ] **Step 2:** Run `npx vitest run scripts/native-bundle.test.mjs`. Expected: FAIL.
- [ ] **Step 3:** Port `native-bundle.mjs` with signing and notarization made optional: with no `--identity`, build an unsigned `release/native/BBIcon.app` and stop (the spec defers signing, notarization, dmg, and cask). Keep the build-then-assemble order and the `.icns` step.
- [ ] **Step 4:** Write `README.md` (what it shows, requirements: bb desktop app, macOS 14+, Apple Silicon; install from `npm run dist`; development commands), `AGENTS.md` (port paseo-menubar's still-relevant rules: where logic goes, never crash the tray, no silent caps, generated glyphs and the `.gitkeep`, no agent can see a menu bar; plus the bb-specific invariants: `/api/v1` and `/ws` are unsupported surfaces pinned to bb 0.44.0, the unread rule and list order are copied from bb's bundle, and the runtime file is the only server source), and `CHANGELOG.md` (0.1.0, written for non-technical readers).
- [ ] **Step 5:** Run `npm test` and `npm run typecheck`. Expected: all green.
- [ ] **Step 6:** Commit `feat: unsigned app bundle, README, AGENTS, changelog`.
- [ ] **Step 7: Human verification (ask the user; do not do it for them).** Ask the user to run `npm run dist && open release/native/BBIcon.app` and confirm:
  1. the glyph and count at Retina scale in both a light and a dark menu bar;
  2. marking a thread unread in bb (`bb thread unread <id>`) moves it into Ready to review within about a second;
  3. clicking a row brings bb forward on that thread;
  4. quitting bb.app dims the icon and shows "bb is not running", and relaunching bb recovers it;
  5. the "Start at login" checkmark.
  Report what they saw verbatim. Do not claim any of these yourself.
