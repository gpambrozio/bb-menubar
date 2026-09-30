# bb Icon remote support — implementation plan

> **For agentic workers:** execute task by task (subagent per task, review after each). Steps use checkbox (`- [ ]`) syntax.

**Goal:** bb Icon watches a remote bb over bb Connect when this Mac has no local bb server, using its own paired machine credential.

**Spec:** `docs/superpowers/specs/2026-09-30-bb-menubar-remote-design.md` (approved), amending `2026-09-29-bb-menubar-design.md`. Read both, and `AGENTS.md`, first. The design binds; this plan is the route.

## Global constraints

Everything in `AGENTS.md` still holds (never crash the tray, no silent caps, every failure named, collaborators injected, logic in `BBIconCore`). In addition:

- **The credential is a password.** It lives only in the Keychain item and in memory. It never appears in a file, `UserDefaults`, a log line, `errorText`, a `description`/`debugDescription`/`dump` of any value (the pairing type's `CustomStringConvertible`/`CustomDebugStringConvertible`/`CustomReflectable` must redact it), a test failure message, or a commit. Tests use obviously fake values like `"cred-test"`.
- **Apex is fixed** to `https://getbb.app`; a redeemed `serverUrl` must be `https://<label>.getbb.app` with a non-empty single DNS label.
- **No `Origin` header** is set by bb Icon on any request.
- Build and test through the `xcode_build` MCP tool (scheme `BBIconPackage-Package` for tests, `BBIcon` for the app), verifying every run with `xcrun xcresulttool`; zero warnings. `swift build`/`swift test` cannot run in the sandbox. Mutate before claiming coverage.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; `git add` only your own files; never `--no-verify`.

## Review focus

1. The credential leaking into any string a user, log, or test output can see.
2. A local bb starting or stopping on a paired Mac: exactly one session, no rows from the other server.
3. The health probe: runs at most once per failure, never while connected, and its answer can never outlive the target it was about (stale probe after a server change).
4. A pasted JSON payload with a foreign `apex`, or a redeem answer with a foreign `serverUrl`, is refused before any credential is stored or sent.
5. Forget deletes the Keychain item, and the menu returns to "not running / Connect to a remote bb…". (Amended after the live test: Forget no longer revokes — getbb.app refuses a device's own revoke — and points to getbb.app/dashboard instead.)

---

### Task 1: Server targets carry headers

**Files:** `Server/BBAPI.swift`, `Server/RealtimeSession.swift`, their tests.

- [ ] `BBAPI.init(serverURL:headers:http:)` with `headers: [String: String] = [:]`; every request (projects, thread pages, open) carries them. Keep the old init source-compatible via the default.
- [ ] `RealtimeSession` gains `headers: [String: String] = [:]`, passed into the `TransportRequest` it builds.
- [ ] Tests: headers present on every BBAPI request kind and on the transport request; no `Origin` header on any of them; existing tests unchanged.
- [ ] Commit `feat(core): server targets carry request headers`.

### Task 2: Pairing — parse, redeem, store

**Files:** create `Connect/ConnectCredential.swift`, `Connect/ConnectPairing.swift`, `Connect/KeychainPairingStore.swift`, tests `ConnectPairingTests.swift`, `KeychainPairingStoreTests.swift`, `Support/FakePairingStore.swift`.

- [ ] `public struct Pairing: Codable, Equatable, Sendable { serverURL: URL; handle: String; machineId: String; credential: String }` with redacting description/debug/reflection. `public protocol PairingStore: Sendable { func load() throws -> Pairing?; func save(_:) throws; func delete() throws }`.
- [ ] `ConnectPairing.parseInput(_ text: String) throws -> String` (the code): trims; bare code, or JSON `{code, apex?, …}` whose `apex`, if present, must equal `https://getbb.app` (trailing slash tolerated). Empty → named error.
- [ ] `ConnectPairing.redeem(code:http:) async throws -> Pairing`: `POST https://getbb.app/api/connect/redeem-machine`, `content-type: application/json`, body `{"code":…}`; success `{credential, machineId, serverUrl}`; validate `serverUrl` per Global constraints; handle = the label. Errors: a `MessageError` enum whose messages are exactly the spec's pairing table (`machine-limit`; `already-used`/409; `expired`/410; ≥500 or transport failure; other refusal; unreadable body). Response body is `{error: string}` on failure.
- [ ] `KeychainPairingStore(service: String = "br.eng.gustavo.bb-menubar.connect")`: one generic-password item, JSON-encoded `Pairing` as data, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; save replaces; delete of a missing item is not an error; Keychain failures are `MessageError`s naming the `OSStatus` (via `SecCopyErrorMessageString`), never the data.
- [ ] Tests: parse table (bare, JSON, foreign apex, http apex, empty, JSON without code); redeem table for every row of the spec's table plus foreign/null/`http:` `serverUrl`, multi-label host, empty label; the request is exactly as above; a redacted `String(describing:)`, `String(reflecting:)` and `dump` of a `Pairing` never contain the credential. Keychain round-trip against a unique per-test service name, cleaned up after — if the test host cannot use the Keychain without a prompt, gate it behind `BB_ICON_KEYCHAIN_TESTS=1` and say so.
- [ ] Commit `feat(core): pair with a remote bb through a machine code`.

### Task 3: Health probe and revoke

**Files:** create `Connect/ConnectHealth.swift`, `Connect/ConnectRevoke.swift`, tests.

- [ ] `ConnectHealth.probe(pairing:http:) async -> ConnectHealthFinding` over `GET {serverURL}/api/connect/servers` with the header: `.revoked` (401/403), `.offline` (2xx and the entry whose `handle` equals the pairing's has `live == false`; also when no entry matches), `.unreachable(String)` (transport error or ≥500), `.live` (2xx and `live == true`), `.unreadable` (bad body). `message(handle:)` gives the spec's error-row texts; `.live` has none.
- [ ] `ConnectRevoke.revoke(pairing:http:) async -> String?` — `POST https://getbb.app/api/connect/revoke-machine`, header, body `{"machineId":…}`; `nil` on `{ok: true}` 2xx, otherwise a sentence naming the failure. Never throws.
- [ ] Tests: every classification row; exact requests; the credential never in any returned text.
- [ ] Commit `feat(core): name remote failures and revoke a pairing`.

### Task 4: Local first, then the pairing

**Files:** `Store/ServerConnection.swift`, `Store/ThreadStore.swift`, `Tray/TrayViewModel.swift`, `Tray/MenuModel.swift`, tests.

- [ ] `ServerConnection` takes a `pairing: Pairing?` input (`setPairing(_:)`) alongside `apply(_ resolution:)`. Target = local runtime URL (no headers) when running, else the pairing's URL + `x-bb-connect-machine` header, else none. A target change goes through the existing stop-then-start path; same target is a no-op. `.runtime` error keeps today's meaning.
- [ ] Remote only: when the realtime session reports a fetch error or `.reconnecting`, run one `ConnectHealth.probe` for the current target (none while one is in flight; result dropped if the target changed or the session reconnected meanwhile). A finding other than `.live` replaces the `.fetch` row text with the finding's message; `.live` leaves the original error. A new `ErrorSource` is not needed unless it reads better — decide and document.
- [ ] `BBState` gains `serverName: String?` (nil = local) and `paired: String?` (the handle, whether or not it's the active target); `TrayViewModel` carries both.
- [ ] `MenuModel`: status line `"<handle> · connected|connecting|reconnecting"` for a remote target (local unchanged); footer row `.connectRemote` (label `Connect to a remote bb…`) when not paired, `.forgetRemote(handle:)` (label `Forget <handle>…`) when paired, placed before Start at login. Unique ids.
- [ ] Tests: local wins over pairing; local stops → pairing takes over with no old rows; pairing removed while remote → not running; headers on remote requests only; probe table drives the error row; stale probe dropped; probe not run for local targets or while connected; menu tables for all three states of the spec's menu table.
- [ ] Commit `feat(core): watch the paired remote bb when there is no local one`.

### Task 5: Pairing window, Forget, and wiring

**Files:** create `BBIcon/PairingWindow.swift`; modify `BBIcon/AppCoordinator.swift`, `BBIcon/MenuContent.swift`, `BBIcon/BBIconApp.swift`; create `Tests/…/LiveRemoteTests.swift`.

- [ ] Coordinator loads the pairing from `KeychainPairingStore` at start (a load failure is an error row, not a crash) and feeds `ServerConnection`.
- [ ] `.connectRemote` opens a small window (SwiftUI `Window` scene or an `NSWindow` hosting a SwiftUI view; the app is `.accessory`, so bring it forward explicitly) with the spec's instructions, a code field, Connect/Cancel, a progress state, and the named error. On success: save, feed `ServerConnection`, close.
- [ ] `.forgetRemote` → confirmation alert (deferred to the next main-actor turn, as `report` does) → `ConnectRevoke` → delete from the store whatever revoke said → feed `nil` → if revoke failed, a follow-up alert naming it and pointing to getbb.app/dashboard.
- [ ] Opt-in `LiveRemoteTests` (`BB_ICON_LIVE_REMOTE=1`): load the stored pairing, fetch one snapshot through the relay, assert no decode failures. Never opens a thread, never prints the pairing.
- [ ] App build 0 warnings; full suite green.
- [ ] Commit `feat(app): pair with and forget a remote bb`.

### Task 6: Docs

- [ ] `AGENTS.md`: server source rule becomes "the runtime file, then the pairing — nothing else"; the credential rule; new files in the table; remote in Known issues (open fans out to every client).
- [ ] Original spec: move the remote item out of Deferred with a pointer to the remote design.
- [ ] `README.md`: "Watching bb on another Mac" (how to get a code, how to forget). `CHANGELOG.md`: add under 0.1.0 (still unreleased), in plain language.
- [ ] `npx vitest run`, `npm run typecheck` green.
- [ ] Commit `docs: remote bb over bb Connect`.

### Task 7: Human verification (the user, not an agent)

On a client Mac with the signed build (amended after the first live test, 2026-09-30):

- [ ] Pair with a fresh code; the pairing window opens in front of other apps' windows and takes typing.
- [ ] Rows and `example-mini · connected` appear, and stay: the `/ws` socket opens with the minted desktop session (no `bb live updates: the server refused the connection (HTTP 401)` row), and a change in bb on the mini shows within about a second.
- [ ] A click opens the thread.
- [ ] Closing bb on the mini (or sleeping it) shows the offline row. Report the relay's actual answers here: the offline case is the one not yet seen live.
- [ ] Forget: the confirmation says the device stays listed at getbb.app/dashboard; **Forget and Open getbb.app/dashboard** returns the menu to "not running / Connect to a remote bb…" and opens the dashboard, where the device is still listed and can be removed by hand. Every alert opens in front.
- [ ] Removing the device at the dashboard while still paired shows the revoked row (`bb Connect no longer accepts bb Icon's pairing with example-mini. Pair again, or forget it.`), and bb Icon keeps retrying.

Established live on 2026-09-30, no longer to check: the machine header works on HTTP and is refused on `/ws`; the desktop-session cookie opens `/ws`; a device cannot revoke itself; the relay's answers for a revoked pairing (see the design's "Naming what goes wrong").
