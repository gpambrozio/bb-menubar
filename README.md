# bb Icon

A menu-bar indicator for [bb](https://getbb.app) threads on macOS. It shows
whether any thread on this Mac's bb — or on a bb running on another Mac — needs
you, and opens a thread in the bb desktop app when you click it — no window, no
Dock icon.

It is the bb counterpart of
[Paseo Icon](https://github.com/gpambrozio/paseo-menubar), and works the same
way. It is a status indicator and launcher; it never runs agents itself.

Licensed under AGPL-3.0-or-later. See [LICENSE](LICENSE).

## What it shows

The tray icon is the glyph of the most urgent bucket any thread is in, with a
count beside it. The menu groups threads in this order:

| Section | A thread lands here when |
| --- | --- |
| **Needs input** | an agent is waiting on you |
| **Failed** | it ended in an error you have not looked at |
| **Ready to review** | it finished and you have not looked at it |
| **Working** | an agent is running |
| **Done** | everything else — including finished threads you have already read |

"Looked at" is bb's own unread marker: opening a thread in bb, or marking it
read, moves it out of Failed or Ready to review into Done.

Only **Needs input**, **Failed**, and **Ready to review** are counted, so the
count disappears once everything left is running or done. Each row shows the
thread's title and its project; clicking it brings bb forward on that thread.
A section longer than fifteen rows ends in an `…and N more` row that opens bb.

Below the threads, a status line says whether bb Icon is connected, and to
which bb. When the bb app is not running, the icon stays in the menu bar,
dimmed, and the menu says **bb is not running** with a row to open it. Anything
that goes wrong is named in its own row rather than hidden.

## Requirements

- The [bb desktop app](https://getbb.app), installed on the same Mac. When bb
  runs its own server here, bb Icon finds it through the file bb writes at
  `~/.bb/bb-app-runtime.json`, with nothing to configure. When this Mac's bb is
  a client of a bb on another Mac, pair bb Icon with that one instead (see
  [Watching bb on another Mac](#watching-bb-on-another-mac)).
- macOS 14 or later.
- An Apple Silicon Mac. Builds are `arm64` only.

bb Icon talks to parts of bb that are not a published API. It is built against
bb 0.44.0; a later bb may change them, and when it does bb Icon names the
failure in its menu rather than going quiet.

## Watching bb on another Mac

If this Mac's bb app is a client of a bb server on another Mac, reached through
bb Connect at `https://<name>.getbb.app`, this Mac has no bb server of its own
and bb Icon says **bb is not running**. Pair it with that server instead:

1. Get a machine code from the bb you want to watch. In any bb window, open
   **Settings → Remote access → Add mobile device**. Or, on the Mac running the
   bb server, run:

   ```bash
   bb settings experiment mobileApp true
   bb connect machine-code
   ```

   A code lasts 10 minutes and works once.
2. In bb Icon's menu, choose **Connect to a remote bb…**, paste the code (or
   the JSON that `bb connect machine-code --json` prints), and click
   **Connect**.

bb Icon becomes its own device on your bb Connect account, listed at
getbb.app/dashboard, and the status line names the server:
`<name> · connected`. Its credential is kept in your login keychain and
nowhere else. After bb Icon is rebuilt or updated, macOS may ask whether it may
use that keychain item.

- **This Mac's own bb comes first.** Whenever bb runs its own server on this
  Mac, bb Icon watches that one and keeps the pairing for later.
- **Clicking a thread opens it on every bb client of that server** — bb windows
  on other Macs and the phone switch to it too. bb has no way to open a thread
  in just one window.
- **When the server cannot be reached**, the menu says why: the pairing was
  revoked, the Mac running the server is asleep or bb is closed there, or
  getbb.app itself could not be reached. bb Icon keeps retrying on its own.
- **To stop watching it**, choose **Forget `<name>`…**. bb Icon asks getbb.app
  to revoke its device and deletes the credential either way; if the revoke
  does not go through, it says so, and you can remove the device at
  getbb.app/dashboard.

One remote bb at a time.

## Install

There is no published release yet. Build the app from a clone:

```bash
npm install
npm run dist
```

That generates the icons, builds the Swift package in release mode, and writes
an unsigned `release/native/BBIcon.app`. Drag it into `/Applications` and open
it. A build made on the Mac that runs it opens directly. Copied to another Mac
(downloaded, AirDropped, shared), the unsigned app is blocked on first launch:
allow it with **Open Anyway** in System Settings → Privacy & Security (on
macOS 14, right-click the app and choose **Open** also works).

With a Developer ID certificate, `npm run dist` also signs and notarizes the
app, which then opens on any Mac without that step:

```bash
export APPLE_ID=…                       # the Apple account's email
export APPLE_APP_SPECIFIC_PASSWORD=…    # an app-specific password from appleid.apple.com
export APPLE_TEAM_ID=…                  # the 10-character team id
npm run dist -- --identity "Developer ID Application: …"
```

The identity can also come from `CODESIGN_IDENTITY`. `--skip-notarize` signs
without notarizing, which needs none of the `APPLE_*` variables, but macOS
still blocks that build's first launch on another Mac.

To remove it, quit it from its menu and delete the app. If it was paired with a
remote bb, choose **Forget** first so the device leaves your bb Connect
account.

## Development

The app is a Swift package in `BBIconPackage/`. What is left at the root is
build tooling under `scripts/`.

```bash
npm install
npm run icons                               # tray glyphs and the app icon
swift run --package-path BBIconPackage BBIcon
npm run typecheck
npm test                                    # the scripts suite, then swift test
npx vitest run                              # the scripts suite only
BB_ICON_LIVE=1 swift test --package-path BBIconPackage --filter LiveBBTests
BB_ICON_LIVE_REMOTE=1 swift test --package-path BBIconPackage --filter LiveRemoteTests
npm run dist                                # an unsigned release/native/BBIcon.app
npm run dist -- --identity "Developer ID Application: ..." --skip-notarize
```

The tray glyphs are generated by `npm run icons` and are not committed. The
directory they land in is, empty, because the package declares it as a
resource and will not build without it — a clone that skips the icon step
builds and tests fine, and the app names the missing glyph at launch.

On macOS with Homebrew's `libvips` installed, `npm install` needs
`SHARP_IGNORE_GLOBAL_LIBVIPS=1` set, or `sharp` tries to build against the
Homebrew copy and fails.

## Design

`docs/superpowers/` holds the design this app was built from and the plan that
followed it. The design binds; the plan is kept as a record. [AGENTS.md](AGENTS.md)
covers the conventions.
