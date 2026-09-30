# AGENTS.md

bb Icon is a macOS menu-bar indicator for [bb](https://getbb.app) threads. It shows
whether any thread on this Mac's bb — or, when this Mac runs none, on the one remote bb it
is paired with over bb Connect — needs you, and opens a thread in the bb desktop app on
click. It is a status indicator and launcher — it never runs agents itself.

It is the bb counterpart of Paseo Icon (`gpambrozio/paseo-menubar`, checked out at
`~/repositories/paseo-menubar`), and its tray UI is ported from there with renames. Where
this repo's design is silent on behaviour, Paseo Icon's is the reference.

**The app is a Swift package.** `BBIconPackage/` holds everything that ships: `BBIconCore`
is the whole program and is tested without a menu bar, `BBIcon` is the `MenuBarExtra` shell
around it. What is left at the repository root is build tooling under `scripts/`, plain
`.mjs` that nothing compiles.

## The spec is the authority

| Document | Standing |
| --- | --- |
| `docs/superpowers/specs/2026-09-29-bb-menubar-design.md` | **Binding** for behaviour: which threads, which bucket, what the menu says, how bb is reached. It has been amended during implementation; the amendments bind too. |
| `docs/superpowers/specs/2026-09-30-bb-menubar-remote-design.md` | **Binding** amendment: watching a remote bb over bb Connect — pairing, the credential, which server wins, naming relay failures, Forget. Where it is silent, the original design binds. |
| `docs/superpowers/plans/2026-09-29-bb-menubar.md`, `2026-09-30-bb-menubar-remote.md` | Historical. Written before the code; review changed both afterwards, and the committed code wins. |

Read both designs before non-trivial work. Do **not** implement from the plan.

## Where logic goes

The rule that shapes this codebase: **if it does not touch AppKit or SwiftUI, it does not
belong in the app target.** Everything else is pure or takes its collaborators by
injection, and is tested without a menu bar — which is the only way a menu bar app that no
agent can see gets tested at all.

| Path under `BBIconPackage/Sources/` | Owns |
| --- | --- |
| `BBIconCore/ErrorText.swift` | `MessageError` and `errorText`, the one narrowing every failure path shares. |
| `BBIconCore/ClockTimer.swift` | The clock-driven timer both sessions use for debounce, backoff, and polling. |
| `BBIconCore/Runtime/RuntimeFile.swift` | Parse `~/.bb/bb-app-runtime.json`. No I/O. |
| `BBIconCore/Runtime/RuntimeSession.swift` | Watch, debounce, poll, liveness, the "not running" state. |
| `BBIconCore/Runtime/DirectoryWatcher.swift` | Keeping the directory watch attached. |
| `BBIconCore/Runtime/FSEventsWatch.swift` | The production watch: FSEvents with file-level events. Ported. |
| `BBIconCore/Server/APIModels.swift` | Lenient thread and project rows. |
| `BBIconCore/Server/HTTPClient.swift` | One HTTP round trip, injected. The production client and `RedirectRefusal`, which never follows a redirect. |
| `BBIconCore/Server/BBAPI.swift` | The paged snapshot fetch, the open-thread POST, and `BBAPIError`. |
| `BBIconCore/Server/WebSocketTransport.swift`, `URLSessionWebSocketTransport.swift` | One WebSocket connection, injected. Ported. Its delegate refuses redirects on the upgrade, it keeps no cookies (so a `Cookie` header goes out as set), and a refused upgrade is named by its HTTP status. |
| `BBIconCore/Server/RealtimeSession.swift` | `/ws`: an optional per-dial preparation (a remote bb's session cookie), subscribe, invalidate, debounce, re-fetch (at most once a second), reconnect, and scrubbing every dial header value out of failure text. |
| `BBIconCore/Connect/ConnectCredential.swift` | `Pairing` (validated, credential redacted from every rendering) and the `PairingStore` protocol. |
| `BBIconCore/Connect/ConnectPairing.swift` | Parse the pasted code or JSON, redeem it at getbb.app, validate the answer, name each refusal. |
| `BBIconCore/Connect/KeychainPairingStore.swift` | The one Keychain item. `Security` only, so it is core. |
| `BBIconCore/Connect/ConnectHealth.swift` | The `/api/connect/servers` probe and what each answer means. |
| `BBIconCore/Connect/ConnectSession.swift` | The relay's desktop session, minted before every remote `/ws` dial: the request, the strict check of the cookie, each failure named. |
| `BBIconCore/Connect/PairingController.swift` | The pairing's life: the launch-time load, pair, Forget — their order, the `.pairing` row, the races between them (a stale load, a Forget during a save), the getbb.app/dashboard pointer for any pairing that is dropped, and whether one is under way. Keychain calls go through an injected executor, off the main thread. |
| `BBIconCore/Store/ThreadStore.swift` | The latest snapshot, connection state, the remote server's name and the paired handle, and the error rows (`ErrorSource`; `.pairing` is a Keychain failure, owned by `PairingController`). |
| `BBIconCore/Store/ServerConnection.swift` | Which server — this Mac's bb, else the pairing — its realtime session and API, the order of a server change, the relay probe for a failing remote, which open-thread answer may land, and scrubbing a remote credential out of every `.fetch` and `.open` row. |
| `BBIconCore/Tray/Bucket.swift` | The bucket rule, the unread test, and bb's list order. Pure. |
| `BBIconCore/Tray/TrayViewModel.swift` | Store state to icon, count, sections. |
| `BBIconCore/Tray/MenuModel.swift` | The menu as data. Every row, label, and rule. |
| `BBIcon/TrayIcons.swift` | The five bucket glyphs as template images. |
| `BBIcon/MenuBarLabel.swift` | The rendered menu bar item: glyph plus count, dimmed when not connected. |
| `BBIcon/MenuContent.swift` | Renders `[MenuItem]` as the panel's rows. Decides nothing. |
| `BBIcon/PairingWindow.swift` | The "Connect to a remote bb…" window: instructions, code field, the named failure. Decides nothing. |
| `BBIcon/AppCoordinator.swift` | Wiring: the object graph, login item, alerts (the Forget confirmation among them), the pairing window, `NSWorkspace`. |
| `BBIcon/Foreground.swift` | Putting the pairing window and every alert in front of other apps' windows, which an accessory app must do by hand. |
| `BBIcon/BBIconApp.swift` | The `MenuBarExtra` scene and the app delegate, which holds a quit until a pair or Forget under way has finished and any failure or notice it produced has been shown. |

If you find yourself adding a decision to `AppCoordinator`, that is the signal to extract it
into `BBIconCore` instead.

## Critical rules

- **`/api/v1` and `/ws` are unsupported surfaces, pinned to bb 0.44.0.** They are bb
  internals, not the Plugin SDK, and bb may change them in any release. Decoding is lenient
  (unknown fields ignored, unknown status reads as idle, one bad row is dropped and named),
  and every other break must name itself in the menu: HTTP 401/403 says bb now requires
  authentication, a decode failure names the path and field, a socket that fails before
  it opens says `bb live updates: …` (a refused upgrade names its HTTP status). For a remote
  bb, a failing fetch or socket is followed by a probe of the relay's `/api/connect/servers`
  (also unsupported, from bb's `connect-client`), whose finding — revoked, offline,
  unreachable — replaces the `.fetch` row's text. The relay's `/api/connect/desktop-session`,
  which mints the cookie a remote `/ws` upgrade needs, is unsupported too and was found by a
  live test, not in bb's sources; a refusal or an answer that is not the expected cookie is
  named, never guessed around. When bb Icon goes quiet after a bb update, that is a bug here, not an
  acceptable failure mode.
- **The unread rule and the list order are copied from bb's bundle, not invented.** Unread
  is `(lastReadAt ?? 0) < latestAttentionAt`, the negation of bb 0.44.0's own read test
  (`(e.lastReadAt??0)>=e.latestAttentionAt`). Rows within a section sort by
  `latestAttentionAt` descending, then `createdAt` descending, then `id` ascending, as bb's
  list does. Both live in `Tray/Bucket.swift`. If bb changes either, copy the new one from
  its bundle and cite it; do not improve on it.
- **The runtime file, then the pairing — nothing else.** `~/.bb/bb-app-runtime.json`,
  written by bb.app (`dev.bb.desktop`) while it runs, names this Mac's bb, and it always
  wins. Only while no local bb is running does bb Icon watch the one remote bb it is paired
  with, whose address is the stored pairing's `https://<handle>.getbb.app`. There is no
  configuration, no environment variable, and no port scan, and bb.app's own
  `server-target.json` is not read. A file whose `pid` is dead reads as not running — bb
  crashed without cleaning up — and is never dialled.
- **The bb Connect credential is a password, and so is the session cookie minted with it.**
  The credential reaches a server whose API runs commands. It lives only in memory and in
  the one Keychain item (`br.eng.gustavo.bb-menubar.connect`) — never in a file,
  `UserDefaults`, a log line, error text, a test failure, or a commit. `Pairing`'s
  `description`, `debugDescription`, and `Mirror` redact it, and any failure text built
  around a request that carried it is scrubbed (`scrubbing(_:from:)`). The relay's
  `__Secure-bb-connect.desktop_session` cookie is minted per `/ws` dial, sent only on that
  upgrade, and kept nowhere: no `URLSession` bb Icon uses has a cookie store,
  `TransportRequest` renders header names without values, `ConnectSession`'s errors never
  quote the answer, and `RealtimeSession` scrubs every dial header value (a cookie's value
  on its own too) out of failure text. Redirects are refused on every HTTP request and on the
  `/ws` upgrade, because `URLSession` would carry the `x-bb-connect-machine` header to
  whatever host `Location` names. A `Pairing` can only point at `https://<handle>.getbb.app`
  with one DNS label, checked at construction and again when the Keychain item is decoded;
  a pasted payload whose `apex` is not `https://getbb.app` is refused before the code is
  sent anywhere. Tests use obviously fake values like `cred-test`.
- **Buckets, labels, and order are Paseo Icon's.** bb has no status buckets, so the five
  sections, their labels, their order (which is also icon priority), and their glyphs are
  exactly the spec's "Say what Paseo Icon says" table. The bucket mapping is the one place
  this app derives state; keep it a single pure function with its table test.
- **`delivered` counts every `/ws` client, bb Icon's own included.** The open endpoint
  answers `{"delivered": N}`, and bb 0.44.0 counts every connected `/ws` socket — the tray's
  realtime socket among them. So `delivered` overstates the windows that navigated;
  `delivered == 0` still means no window saw the click, but only when nothing at all is
  connected. Do not read a positive count as proof a bb window opened the thread.
- **Never crash the tray.** No force unwraps, no `try!`, no `fatalError`, no unchecked
  index arithmetic, and no arithmetic on server-supplied numbers before they are bounded. A
  Swift trap is uncatchable and takes the menu bar item with it, leaving nothing to click
  and nothing to quit.
- **No silent caps.** Any truncated list renders a visible row — `…and N more` per section,
  `Not all threads shown` when paging hits its ceiling — and every `MenuItem` carries a
  unique `id`. SwiftUI's `ForEach` keys on it, so two rows that collide become one, which is
  a silent cap by another route.
- **Every failure the user can hit is named in an error row**, never swallowed.
- **Nothing is shown that cannot be vouched for.** When bb is not running, connecting, or
  reconnecting, the rows from the last connection are dropped and the glyph is dimmed.
- **`@MainActor` where the code says so, and callbacks that cross a thread must hop.**
  FSEvents re-enters through `MainActor.assumeIsolated`; the `NSWorkspace` open completion,
  which arrives on an arbitrary queue, resumes a checked continuation that the main-actor
  caller awaits, and only `Sendable` failure text crosses it. An annotation that silences
  the compiler without making the guarantee is a bug.
- **Collaborators are injected, never reached for** — the file read, process liveness, the
  watch, HTTP, the WebSocket transport, and the clock. That is what makes the chain
  testable without bb, a menu bar, or real sleeps.

## Working here

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npm test                                    # vitest (scripts) then swift test
swift test --package-path BBIconPackage
npx vitest run                              # build tooling only
npm run typecheck
npm run icons                               # tray glyphs and the app icon
BB_ICON_LIVE=1 swift test --package-path BBIconPackage --filter LiveBBTests
BB_ICON_LIVE_REMOTE=1 swift test --package-path BBIconPackage --filter LiveRemoteTests
npm run dist                                # unsigned release/native/BBIcon.app
```

On this development machine `~/.npm` is root-owned, so `npm install` needs
`--cache "$TMPDIR/npm-cache"`.

- **Inside the bb sandbox, `swift build` and `swift test` cannot run.** Use the
  `xcode_build` MCP tool with scheme `BBIconPackage-Package` instead, and then check the
  result yourself with `xcrun xcresulttool` against the `.xcresult` it produced (for
  example `xcrun xcresulttool get test-results summary --path <bundle>.xcresult`). The
  tool's own pass/fail verdict has misreported before; the result bundle is the evidence.
  For the same reason `npm test` only gets through its vitest half there, and
  `npm run dist` cannot run at all.
- **The tray glyphs are generated, not committed.** `npm run icons` writes them into
  `BBIconPackage/Sources/BBIcon/Resources/TrayIcons/`, which is git-ignored except for a
  `.gitkeep`. The keep file is load-bearing: `Package.swift` declares that directory as a
  `.copy` resource, and SwiftPM refuses to build a target whose declared resource path does
  not exist — so ignoring the whole directory makes `swift build` *and* `swift test` fail
  on a fresh clone with an error that never mentions the generator. An empty directory
  builds fine and `TrayIcons.preflight()` names the real problem at launch. The file stems
  must equal `TrayViewModelBuilder.iconNames`; `make-icons.test.mjs` holds them together.
- **The bb mark is vendored, unmodified**, in `assets/bb-logo.svg`. `make-icons.mjs`
  records where it came from and how to re-vendor it.
- **Do not launch the app to check your work.** It can register a real login item, holds a live
  socket to your bb, and shares a bundle id with any installed copy.
- **There is no linter.** Don't assume `npm run lint` exists.
- **`scripts/` is build tooling and never ships**, so it is plain `.mjs`. It is still
  tested: `vitest.config.ts` includes `scripts/**/*.test.mjs`.

## Packaging

`npm run dist` regenerates the icons, then runs `scripts/native-bundle.mjs`, which builds
the Swift package in release for `arm64`, assembles `release/native/BBIcon.app` around it,
and renders the `.icns` from `assets/generated/icon.png`. With no `--identity` (and no
`CODESIGN_IDENTITY`) it stops there, unsigned. With one it signs, and then notarizes unless
`--skip-notarize` is passed. The dmg and Homebrew cask are deferred; copy Paseo Icon's
pipeline when they are wanted.

The display name is `bb Icon`, the bundle is `BBIcon.app`, and the bundle id is
`br.eng.gustavo.bb-menubar`. The macOS floor is 14 and lives in three places that must
agree: `platforms` in `Package.swift`, `MIN_MACOS` in `native-bundle.mjs`, and the sentence
in `README.md`. `native-bundle.test.mjs` holds them together.

## Things carried over from Paseo Icon

**Mutate before you claim coverage.** Before reporting a test as covering something, break
the thing it covers and confirm it goes red.

**Fixing a conversion is not fixing the arithmetic that consumes it.** When you fix a
value, look at every use of it.

**No agent can see a menu bar.** Icon appearance at Retina scale, click-through into bb,
the dimmed not-running state, and the login item's checkmark are verifiable only by a human
running the app. Say so plainly rather than narrating a check you did not perform.

## Known issues

- **The panel has no keyboard navigation**, inherited from Paseo Icon's window-style panel.
  ⌘Q still works.
- **A bb that hangs while alive looks connected.** Nothing pings `/ws` after it opens, so
  the tray keeps its last snapshot. See the spec's Deferred list.
- **Opening a thread on a remote bb opens it on every client of that server.** bb's open
  endpoint has no per-client target, so a click switches bb windows on other Macs and the
  phone too. This is what `bb thread open` does, and it was accepted for v1.
- **The pairing migrates with Migration Assistant.** The item lives in the file-based login
  keychain (the data protection keychain needs an entitlement an unsigned build lacks),
  which ignores `kSecAttrAccessible`: it is never synced, but a new Mac set up from this
  one inherits it.
- **bb Icon cannot remove its own device from bb Connect.** getbb.app refuses a device's
  own `revoke-machine` (401); only the server's credential may revoke. So Forget, a
  replaced pairing, and a pairing whose save failed each leave a device listed at
  getbb.app/dashboard, holding a machine slot, and say so with a pointer to remove it
  there.
- **The relay's answer for an offline server has not been seen live.** The probe classifies
  it from bb's sources. The answers for a revoked pairing were seen on 2026-09-30 and match
  the design's table.
- One pairing per Mac, one server at a time. Several remote servers are deferred.
- No release is published yet. `npm run dist` builds unsigned unless given a signing
  identity; every build is `arm64` only, with no auto-updater.
