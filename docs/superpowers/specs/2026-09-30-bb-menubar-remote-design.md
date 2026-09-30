# bb Icon — watching a remote bb over bb Connect

Date: 2026-09-30. Status: **approved by the user, 2026-09-30.**

This amends `2026-09-29-bb-menubar-design.md` and lifts one item from its Deferred list:
"a bb.app connected to a **remote** bb server (bb Connect)". Where this document is silent,
the original design binds.

## Why

On a Mac whose bb.app is a client of another Mac's bb server — two of the user's laptops
both reach the server Mac at `https://example-mini.getbb.app` — bb Icon says
**bb is not running** while bb is plainly open. bb writes `~/.bb/bb-app-runtime.json` only
when bb.app starts its own local server (`claimBbAppRuntimeFile`, bb 0.44.0
`src/launcher.ts:3971`), so a client Mac has no runtime file and nothing to dial.

## What bb does (0.44.0, from its shipped sources)

- **The bb server authenticates nothing on `/api/v1` or `/ws`.** It binds to loopback and
  warns that its public API is unauthenticated (`src/start-server.ts:327-332`). Remote
  access is gated entirely by the **getbb.app relay** in front of it.
- **The relay accepts a per-device machine credential**, sent raw in the header
  `x-bb-connect-machine: <credential>` on HTTP requests and on the WebSocket upgrade. This
  is how bb's own host daemon and CLI proxy reach `/api/v1` and `/ws` from a client Mac
  (host-daemon `src/server-client.ts:418-424`, `src/machine-auth-proxy.ts:109-211`).
  Without it every path, `/health` included, answers HTTP 401 with an HTML page.
- **A device gets its own credential from a one-time machine code** — the flow bb's
  mobile app uses. The code is minted on the server (`bb connect machine-code`, or
  Settings → Remote access → Add mobile device in any bb window), lasts 10 minutes, and
  works once. Redeeming it at `POST https://getbb.app/api/connect/redeem-machine` with
  `{"code": "…"}` returns `{credential, machineId, serverUrl}`. The device then appears in
  the getbb.app dashboard's machine list, where it can be revoked.
- **The open endpoint reaches every client of the server**, on every Mac and phone. There
  is no per-client target and no URL scheme.

bb Icon does **not** reuse bb.app's `connect-credential.bin` (encrypted with bb.app's own
Keychain key) or the host daemon's credential in `~/.bb-machines/*/config.json` (another
program's identity in an internal file). It pairs as its own device.

## Which bb, in which order

bb Icon watches exactly one server:

1. **This Mac's own bb**, found through the runtime file exactly as today. It always wins:
   when it is running, a pairing is kept but unused.
2. **The paired remote bb**, when there is a pairing and no local bb is running.
3. Otherwise nothing: the menu says **bb is not running** and offers to pair.

Moving between these reuses the existing server-change path (`ServerConnection`): the old
session stops, the rows drop, and the new one connects. The rule "the runtime file is the
only server source" becomes "the runtime file, then the pairing — and nothing else": still
no configuration file, environment variable, or port scan.

## Pairing

A new footer row, **Connect to a remote bb…**, appears while there is no pairing. It opens
a small window:

> Enter a machine code from the bb you want to watch. In any bb window, open
> Settings → Remote access → Add mobile device; or, on the Mac running bb, run
> `bb settings experiment mobileApp true` and then `bb connect machine-code`.
> Codes last 10 minutes and work once.
>
> [ code field ] [Connect]

- The field accepts the bare code, or the JSON the QR code and `--json` carry
  (`{code, serverUrl, apex, expiresAt}`), from which only `code` and `apex` are read.
- The apex must be `https://getbb.app`. It is bb Connect's only production apex, and
  refusing others means a pasted payload can never send the code elsewhere.
- The redeemed `serverUrl` must be `https://<label>.getbb.app`; the label is the server's
  **handle** and names it in the menu. A null or foreign `serverUrl` is refused, as bb.app
  refuses it (`connect-client/src/redeem-machine.ts:105-119`).
- Every failure is named in the window, using bb's own error mapping
  (`redeem-machine.ts:30-39`):

  | Answer | Message |
  | --- | --- |
  | `machine-limit` | Your bb Connect account has no free machine slots. Revoke a device you no longer use at getbb.app/dashboard, then try again. |
  | `already-used` or 409 | That code was already used. Make a new one. |
  | `expired` or 410 | That code has expired — codes last 10 minutes. Make a new one. |
  | ≥ 500, or no answer | getbb.app could not be reached: … |
  | any other refusal | getbb.app did not accept that code. |
  | a body that is not the expected JSON | getbb.app answered in a way bb Icon cannot read. |

- On success the pairing `{serverUrl, handle, machineId, credential}` is stored as one
  Keychain generic-password item (service `br.eng.gustavo.bb-menubar.connect`,
  accessible after first unlock, this device only). It is never written to a file,
  `UserDefaults`, a log, or any error text: the credential reaches the server's
  command-executing API, so it is handled like a password. The item lives in the
  file-based login keychain (the data protection keychain needs an entitlement an
  unsigned build lacks), which ignores the accessibility attribute: it is requested for
  forward compatibility but not enforced, so the item is never synced yet does migrate
  to a new Mac with Migration Assistant.
- A Keychain failure — the item cannot be read at launch, or cannot be written or
  removed — is its own error row, `ErrorSource.pairing`, naming the `OSStatus` and never
  the item's data. It stays until the next Keychain operation succeeds. An item that is
  there but does not decode as a valid pairing (including one naming a server outside
  getbb.app) reads as unreadable, and the tray carries on as if unpaired, offering
  **Connect to a remote bb…**, whose save replaces it.
- A code is spent once getbb.app answers, so a pairing that cannot be stored is revoked
  at once rather than kept only in memory, and the window says the code has been used.
- Pairing while this Mac's own bb is running changes nothing in the tray but the footer
  row, so the window does not just close: it says **Paired with `<handle>`. bb Icon will
  watch it whenever this Mac's own bb is not running.** and the user closes it.

One pairing per Mac. Several remote servers remain deferred.

## Talking to a remote bb

The same `BBAPI` and `RealtimeSession` serve both cases. A server target is a base URL plus
extra headers: none for the local server, `x-bb-connect-machine` for a remote one, on every
HTTP request and on the `/ws` upgrade. bb Icon sends no `Origin` header; the server's guard
passes a request without one (`browser-request-guard.ts:146-152`). No request, and not
the `/ws` upgrade, follows a redirect: `URLSession` would carry the header to whatever
host `Location` names, so a 3xx is answered as a refusal.

bb.app need not run on this Mac for bb Icon to watch a remote bb; only a row click needs it.

### Naming what goes wrong

A remote connection can fail in ways a loopback one cannot, and the rows are dropped in
each case, as today. When a fetch or the socket fails, bb Icon asks
`GET {serverUrl}/api/connect/servers` (same header) what is wrong, and names it:

| Finding | Error row |
| --- | --- |
| 401/403 from the relay | bb Connect no longer accepts bb Icon's pairing with `<handle>`. Pair again, or forget it. |
| 2xx, and this server's `live` is false | `<handle>` is offline — the Mac running it may be asleep or bb may be closed there. |
| no answer, or any other non-2xx | getbb.app could not be reached: … (the failure, or `HTTP <n>` for a 5xx, or `getbb.app answered HTTP <n>`) |
| 2xx and `live` true | the original fetch or socket error, as today |
| 2xx whose body, or this server's `live`, cannot be read | getbb.app sent something bb Icon cannot read at /api/connect/servers: … (the field) |

The probe runs only for a remote target, and only on a failure the session reports: a
lost connection, or a fetch or dial that fails while not connected. At most one runs at
a time, so there is at most one per failed reconnect attempt and none while connected;
until it answers, the last finding for the same trouble stands. An answer is dropped if
the target changed (a local bb started, the pairing was forgotten or replaced) or a fetch
succeeded since it was asked — not merely because the session re-dialled, which is the
same trouble. The finding replaces the `.fetch` row's text rather than adding a row, so a
server change clears it with the error it names.

Reconnecting continues with the existing backoff (1 s ×1.5, capped at 30 s) in every
case, so a Mac that wakes or a relay that recovers is picked up without a click. A
revoked pairing is **not** deleted automatically; the user chooses **Forget**.

## The menu

The layout is unchanged except for the status line and one footer row:

| State | Status line | Extra footer row |
| --- | --- | --- |
| local bb (paired or not) | `bb · connected` (as today) | **Forget `<handle>`…** if paired, else **Connect to a remote bb…** |
| remote bb | `<handle> · connected` / `connecting` / `reconnecting` | **Forget `<handle>`…** |
| neither | `bb is not running` | **Connect to a remote bb…** |

**Forget `<handle>`…** asks for confirmation, then makes a best-effort
`POST https://getbb.app/api/connect/revoke-machine` with `{"machineId": …}` and its own
header, and deletes the Keychain item whatever the answer. If the revoke is refused or
unreachable, the confirmation says so and points to getbb.app/dashboard to remove the
device by hand. (Whether the relay lets a device revoke itself is not visible in bb's
code; the design does not depend on it.)

## Click-through, remote

Unchanged in shape: activate (or launch) this Mac's bb.app, then
`POST {serverUrl}/api/v1/threads/<id>/open` through the relay with the header. The request
reaches **every** client of that server — bb windows on other Macs and the phone switch to
the thread too. This is what `bb thread open` does, and the user accepted it for v1.
bb.app not installed on this Mac is named as today.

## Where logic goes

| Path under `BBIconPackage/Sources/` | Owns |
| --- | --- |
| `BBIconCore/Connect/ConnectPairing.swift` | Parse pasted input, redeem, validate the answer, name each refusal. Over `HTTPClient`. |
| `BBIconCore/Connect/ConnectCredential.swift` | The pairing value and the `PairingStore` protocol. |
| `BBIconCore/Connect/KeychainPairingStore.swift` | The Keychain implementation. `Security` only, no AppKit, so it is core. |
| `BBIconCore/Connect/ConnectHealth.swift` | The `/api/connect/servers` probe and its classification. |
| `BBIconCore/Connect/ConnectRevoke.swift` | The best-effort revoke. |
| `BBIconCore/Store/ServerConnection.swift` | Chooses local, then remote; a target is URL plus headers. |
| `BBIconCore/Server/BBAPI.swift`, `RealtimeSession.swift` | Take the target's headers. |
| `BBIconCore/Tray/MenuModel.swift` | The status line and the two footer rows. |
| `BBIcon/PairingWindow.swift` | The code field and its messages. Decides nothing. |
| `BBIcon/AppCoordinator.swift` | Wiring, the Forget confirmation. |

## Testing

- Swift Testing with fakes for HTTP, the transport, and the pairing store; every table
  above is a test table. Response shapes are written from bb's sources and marked as such,
  since recording them means minting a real code.
- An opt-in live test, `BB_ICON_LIVE_REMOTE=1`, reads the stored pairing and fetches a
  snapshot through the relay. It never opens a thread.
- **Needs the user, because it spends a machine slot or needs another Mac:** pairing with a
  real code on a client Mac; the relay's actual answers for a revoked pairing and an
  offline server (the design names each case but cannot see the relay's wording);
  whether `URLSessionWebSocketTask` adds an `Origin` header; whether self-revoke is
  accepted; the click-through from a client Mac.

## Deferred

- Several remote servers, and choosing between them.
- Scanning the QR code instead of pasting.
- Finding the remote server from bb.app's own `server-target.json`, and bb.app's `custom`
  (unauthenticated URL) target.
- Opening a thread in only this Mac's window — bb has no way to target one client.
