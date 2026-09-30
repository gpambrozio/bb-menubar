# bb Icon — a macOS menu-bar indicator for bb

Date: 2026-09-29. Status: **approved design, pending spec review.**

bb Icon is a macOS menu-bar indicator for [bb](https://getbb.app) threads. It shows
whether any thread needs you, and opens a thread in the bb desktop app on click. It is a
status indicator and launcher — it never runs agents itself.

It is the bb counterpart of Paseo Icon (`gpambrozio/paseo-menubar`, checked out at
`~/repositories/paseo-menubar`). Behaviour is copied from that app's binding design docs
wherever bb allows; this document records only what differs and why. Where this
document is silent, Paseo Icon's `2026-08-16-standalone-menubar-app-design.md` (as
amended by its native-app design) is the reference for behaviour.

## Goal

One glance at the menu bar answers "does any bb thread need me?", and one click takes
you to the thread that does.

## Why not a bb plugin

The first attempt was a bb plugin, and it was dropped on purpose:

- The bb Plugin SDK (0.5.29, bb 0.44.0) has no tray, status-item, or dock-badge API.
  Server, app, and host entries are all JavaScript; none can draw an `NSStatusItem`.
- A plugin would still need a native helper, launched per Mac through a `bb.host`
  entry, compiled on each host or shipped as a binary — and the plugin's app side has
  no public way to learn which host it runs on, so routing a click back to the right
  bb window needed a focus heuristic.
- A standalone app that reads bb's own API is simpler, and is exactly how Paseo Icon
  works against Paseo.

## Say what Paseo Icon says

bb's sidebar has no status buckets of its own, so bb Icon keeps Paseo Icon's five
buckets, labels, order, and glyph rules. Section order, which is also icon priority:

| Bucket | Label | Glyph |
| --- | --- | --- |
| `needsInput` | Needs input | lucide `megaphone` |
| `failed` | Failed | lucide `circle-x` |
| `readyToReview` | Ready to review | lucide `triangle-alert` |
| `working` | Working | lucide `loader-pinwheel` |
| `done` | Done | the bb mark |

The bb mark is `bb-logo.svg` from the bb desktop app's bundled web assets
(`/Applications/bb.app/Contents/Resources/app.asar.unpacked/node_modules/bb-app/app/dist/assets/bb-logo-*.svg`),
vendored into `assets/bb-logo.svg` and rasterized by the same generator Paseo Icon uses.

## Which threads, in which bucket

A thread is **excluded everywhere, counts included**, when `archivedAt != null`,
`deletedAt != null`, or `visibility == "hidden"`.

A thread is **unread** when `(lastReadAt ?? 0) < latestAttentionAt`. This is the
negation of bb's own read test, copied from the bb 0.44.0 web app bundle:
`function x_(e){return(e.lastReadAt??0)>=e.latestAttentionAt}`.

Each remaining thread lands in exactly one bucket, first match wins:

1. `hasPendingInteraction == true` → **Needs input**
2. `status == "error"` and unread → **Failed**
3. `status == "idle"` and unread → **Ready to review**
4. `status ∈ {starting, active, stopping, pending}`, or any `activity.*Count > 0`
   → **Working**
5. otherwise → **Done** (includes idle-and-read and error-and-read)

An unknown `status` value is treated as `idle`, as the bb SDK instructs its own
consumers. This mapping is the one place bb Icon derives state; bb exposes its own
resolved per-thread indicator only to plugin UI, never over its HTTP API. The mapping
is a single pure function with its own test table.

**Icon:** the glyph of the highest-priority non-empty bucket; with no threads, `done`.
**Count:** threads in Needs input + Failed + Ready to review, shown beside the glyph and
hidden when zero. Working and Done are never counted — same reasoning as Paseo Icon.

## Talking to bb

### Discovery

bb.app writes `~/.bb/bb-app-runtime.json` while it runs:

```json
{ "entryPath": "…/bb-app-bridge.mjs", "pid": 16746,
  "serverUrl": "http://127.0.0.1:38886", "startedAt": "…",
  "surface": "desktop", "version": "0.44.0" }
```

bb Icon reads it, watches it with FSEvents (the same watch-and-debounce machinery as
Paseo Icon's registry session), and treats bb as **running** when the file parses, its
`pid` is alive, and an app with bundle id `dev.bb.desktop` is running
(`NSWorkspace` launch/terminate notifications drive re-checks). The server URL comes
only from this file — there is no configuration, no `BB_SERVER_URL`, no pairing.

Only the bb server that this Mac's bb.app uses is watched. A bb.app pointed at a remote
server is out of scope for v1 (see Deferred).

### Snapshot

- `GET {serverUrl}/api/v1/threads?archived=false&limit=200&offset=N` → array of
  thread rows (the same shape `bb thread list --json` prints, including
  `hasPendingInteraction`, `lastReadAt`, `latestAttentionAt`, `queuedWork`, `runtime`,
  `activity`). Without `archived=false` the route returns archived threads too; hidden
  threads are excluded unless `includeHidden=true` is passed. bb's route pages, and its
  default page size is not documented, so bb Icon pages explicitly: 200 per request,
  `offset` advancing until a short page, at most 25 pages. Reaching that ceiling adds a
  `Not all threads shown` note — the menu never presents a subset as the whole.
- `GET {serverUrl}/api/v1/projects` → array with `id` and `name`, for row labels.

Both answer on loopback without credentials in bb 0.44.0. Decoding is lenient: unknown
fields are ignored, unknown enum values map to a documented default, and one thread
that fails to decode is dropped and named in the error row — it never costs the rest.

### Live updates

bb's web client subscribes over a WebSocket at `{serverUrl}/ws` (the path replaces the
URL's path; `http→ws`, `https→wss`). bb Icon does the same:

- On open, send `{"type":"subscribe","target":{"kind":"thread-list"}}` and
  `{"type":"subscribe","target":{"kind":"project-list"}}`.
- Every `{"type":"changed","entity":"thread"|"project",…}` message schedules a
  re-fetch of the snapshot, debounced ~250 ms so a burst of `events-appended`
  messages costs one fetch. Other message types (`plugin-signal`, …) are ignored.
- Re-fetches start at most once per second. A running thread sends
  `events-appended` for as long as it runs, so the debounce alone would fetch
  back to back; a re-fetch owed sooner than a second after the previous one
  started waits out the rest of that second. Only one fetch runs at a time, and
  invalidations that arrive while one runs or waits cost exactly one more.
- On every (re)connect, re-fetch unconditionally and at once, whatever the
  once-per-second cap — invalidations sent while disconnected are lost.
- Reconnect with bb's own `BbRealtimeClient` backoff: 1 s initial delay, ×1.5 per
  attempt, capped at 30 s, reset on a successful open. An open counts as successful
  once its first fetch succeeds: a bb that accepts the socket and then fails every
  fetch (authentication, a shape this build cannot read) is retried at a growing
  interval, not every second.
  Backoff, debounce, and the fetch cap run on an injected clock so they are
  tested without sleeps.
- A socket that fails before it opens names the reason in the error row
  (`bb live updates: …`), so a moved or refused `/ws` is not a silent
  `reconnecting`; the next successful fetch clears it. A socket lost after it opened
  is a bb restart and reads only as `reconnecting`.

This protocol is an **unsupported surface**: `/api/v1` and `/ws` are bb internals, not
the Plugin SDK. The app is pinned to what bb 0.44.0 does, in the same way Paseo Icon is
pinned to the Paseo wire and registry. When bb changes them, the failure must name
itself: HTTP 401/403 → "bb now requires authentication", a decode failure names the
field, a WebSocket close is a reconnecting state, not silence.

## Menu

The window-style `MenuBarExtra` panel from Paseo Icon, unchanged in structure:

```
Needs input
  Fix login redirect  ·  web-app
Failed
  Migrate schema  ·  api
Ready to review
  Add rate limiting  ·  bb-plugins
Working
  Refactor terminal input  ·  web-app
Done
  Bump deps  ·  web-app
─────────────────────────
bb · connected
─────────────────────────
Open bb
Start at login  ✓
Quit bb Icon            ⌘Q
```

- Rows show the thread's `title`, else `titleFallback`, else its id, then the
  project name. Nothing else.
- Rows within a section use bb's own chronological list order, copied from the same
  bundle: `latestAttentionAt` descending, then `createdAt` descending, then `id`
  ascending. (bb's list additionally floats `active` threads to the top; within a
  section every thread shares a status class, so that step is moot here.) The API's
  own response order is not relied on.
- Empty sections are omitted. Each section caps at 15 rows with a visible
  `…and N more` row that opens bb. No silent caps; every row keyed by thread id.
- The status line reads `connected`, `connecting`, `reconnecting`, or
  `bb is not running`, plus a named error row when there is one.

### When bb is not running

The icon stays. It shows the `done` glyph dimmed, no count, and the panel holds only
the `bb is not running` line, **Open bb**, Start at login, and Quit. The rows from the
last connection are dropped, not kept — the icon never shows data it cannot vouch for.
The glyph is dimmed the same way while connecting or reconnecting, because the rows are
gone then too: dimmed means "not connected", whatever the reason.

## Click-through

bb.app registers no URL scheme, so there is no deep link. bb itself can navigate its
connected apps: `bb thread open <id>` is a thin wrapper over
`POST {serverUrl}/api/v1/threads/<id>/open` with body `{"file":null}`, which answers
`{"delivered": N}` — the number of connected clients the request reached. bb
Icon calls that endpoint directly rather than spawning the CLI, so there is no Node
subprocess, no CLI path inside the bundle to track, and no inherited `BB_THREAD_ID`
(the CLI refuses to open a different thread when that is set).

A row click:

1. Activates bb.app (`dev.bb.desktop`) through `NSWorkspace`.
2. POSTs the open request.

A failed request, a non-2xx status, or `delivered == 0` is named in the error row
("bb had no open window to show the thread in"). The request reaches every connected
bb client, not only this Mac's window — the same behaviour as `bb thread open`.
bb 0.44.0 counts every connected `/ws` socket in `delivered`, bb Icon's own realtime
socket included, so the count overstates the windows that navigated. `delivered == 0`
still means no window saw the click, but it only happens when nothing at all is
connected.

`…and N more` and **Open bb** only activate bb.app (launching it when not running).

## Where logic goes

Paseo Icon's rule holds: **if it does not touch AppKit or SwiftUI, it does not belong
in the app target.**

| Path under `BBIconPackage/Sources/` | Owns |
| --- | --- |
| `BBIconCore/ErrorText.swift` | Ported unchanged. |
| `BBIconCore/ClockTimer.swift` | The one timer the debounce, reconnect, and poll share, on an injected clock. |
| `BBIconCore/Runtime/RuntimeFile.swift` | Parse `bb-app-runtime.json`. No I/O. |
| `BBIconCore/Runtime/RuntimeSession.swift` | Watch, debounce, liveness, the "not running" state. |
| `BBIconCore/Runtime/DirectoryWatcher.swift` | Keeping the `~/.bb` watch attached. Ported from Paseo Icon's `RegistryWatcher`. |
| `BBIconCore/Runtime/FSEventsWatch.swift` | Ported from Paseo Icon, with the path filter injected. |
| `BBIconCore/Server/APIModels.swift` | Lenient `Decodable` thread and project rows. |
| `BBIconCore/Server/HTTPClient.swift` | One HTTP round trip, injected; the `URLSession` one ships. |
| `BBIconCore/Server/BBAPI.swift` | The two GETs, the open-thread request, and their failure text. |
| `BBIconCore/Server/WebSocketTransport.swift`, `URLSessionWebSocketTransport.swift` | The socket, injected. Ported from Paseo Icon. |
| `BBIconCore/Server/RealtimeSession.swift` | `/ws`: subscribe, invalidate, debounce, cap re-fetches, reconnect. |
| `BBIconCore/Store/ThreadStore.swift` | The latest snapshot and connection state. |
| `BBIconCore/Store/ServerConnection.swift` | Server changes: stop the old session, start the new one, drop stale answers. |
| `BBIconCore/Tray/Bucket.swift` | The bucket mapping above. Pure. |
| `BBIconCore/Tray/TrayViewModel.swift` | Ported: store → icon, count, sections. |
| `BBIconCore/Tray/MenuModel.swift` | Ported: the menu as data. |
| `BBIcon/TrayIcons.swift`, `MenuBarLabel.swift`, `MenuContent.swift` | Ported with renames. |
| `BBIcon/AppCoordinator.swift`, `BBIconApp.swift` | Object graph, login item, `NSWorkspace`. |

Swift 6 strict concurrency, `@MainActor` where the code says so, collaborators
injected, and Paseo Icon's "never crash the tray" rules (no force unwraps, no `try!`,
no unchecked arithmetic on untrusted numbers) all carry over.

Nothing from Paseo Icon's `Registry/` (LevelDB, snappy, SSTable, WAL), `Daemon/`
(Paseo wire, E2EE, relay), or the `swift-sodium` dependency is needed. `swift-clocks`
stays for deterministic timer tests.

## Testing

- **Swift Testing** on `BBIconCore`, with fakes for the file system, HTTP, WebSocket
  transport, process liveness, and clock. The bucket mapping gets a table test covering
  every row of the rule list, including unknown status and background activity.
- **Fixtures** recorded from a real bb 0.44.0: a `/api/v1/threads` and
  `/api/v1/projects` response and a stream of `/ws` messages, anonymised.
- **vitest** for `scripts/` (icon generator, bundler), as in Paseo Icon.
- An opt-in live test against the developer's running bb (loopback), skipped by
  default.
- The menu bar itself — glyph rendering at Retina scale, click-through, the login item
  — is verifiable only by a human running the app. Reports say so rather than
  narrating a check that was not performed.

## Repository

`~/repositories/bb-menubar` (to be pushed as `gpambrozio/bb-menubar`), licensed like
Paseo Icon (AGPL-3.0-or-later). Layout mirrors Paseo Icon: `BBIconPackage/` (Swift
package, `swift-tools-version: 6.1`, `platforms: [.macOS(.v14)]`), `scripts/` (plain
`.mjs`, tested), `assets/`, `docs/superpowers/`, `AGENTS.md`, `README.md`,
`CHANGELOG.md`. The tray glyphs are generated by `npm run icons` and not committed,
with the load-bearing `.gitkeep` Paseo Icon documents.

Names: display name **bb Icon**, bundle `BBIcon.app`, bundle id
`br.eng.gustavo.bb-menubar`, `LSUIElement` true, single instance.

## Deferred

- Signing, notarization, dmg, and the Homebrew cask (copy Paseo Icon's pipeline once
  the app works).
- A bb.app connected to a **remote** bb server (bb Connect): needs the auth handshake
  and a server URL the runtime file may not carry.
- Several bb servers at once.
- Resolving `@project:`/`@thread:` mention tokens in titles the way bb's sidebar does.
- Keyboard navigation in the panel (a known gap inherited from Paseo Icon).
- Post-open liveness on `/ws`: a bb that hangs while alive keeps the socket open, and
  the tray keeps showing its last snapshot as `connected`. A periodic ping (or a
  bounded silence timer) would detect it.
