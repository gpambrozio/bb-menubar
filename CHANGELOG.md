# Changelog

Notable changes to bb Icon. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries describe what changed for someone running the app. Refactors, tests, and
documentation are left to the git history.

## [0.1.0] — Unreleased

The first version. bb Icon puts a small icon in your Mac's menu bar that tells you,
at a glance, whether any of your bb threads needs you.

**Requires macOS 14 (Sonoma) or later, an Apple Silicon Mac, and the bb desktop
app.**

### Added

- A menu bar icon that changes to show the most urgent thing across your bb
  threads — something waiting for your answer, something that failed, something
  finished and waiting for you to look at it, or work still running — with a
  count of the threads that need you.
- A menu listing your threads under **Needs input**, **Failed**, **Ready to
  review**, **Working**, and **Done**, each with its title and project.
- Click a thread in the menu to jump straight to it in bb.
- The icon updates within about a second when anything changes in bb — no
  refreshing.
- When bb is closed, the icon stays but dims, and the menu says **bb is not
  running** with a button to open it. It picks back up by itself when bb comes
  back.
- A **Start at login** option, so the icon is there whenever you log in.
- Nothing to set up for the bb on your Mac: bb Icon finds it on its own.
- Watch a bb running on another Mac. If your bb app connects to a bb on another
  Mac through bb Connect, choose **Connect to a remote bb…** and paste a machine
  code from that bb (Settings → Remote access → Add mobile device). The menu then
  shows that bb's threads, and names it in the status line. The bb on your own
  Mac always comes first when it is running.
- **Forget** a remote bb to stop watching it. bb Icon asks bb Connect to remove
  it from your devices, and tells you where to remove it by hand if that does
  not work.
- When a remote bb cannot be reached, the menu says why — the pairing was
  revoked, the other Mac is asleep or bb is closed there, or bb Connect is
  unreachable — and bb Icon keeps trying on its own.
- When something goes wrong — bb changed in a way this version cannot read, or a
  thread could not be opened — the menu says what happened instead of quietly
  showing nothing.

### Known limitations

- There is no published download yet; you build the app yourself. A build
  that is not signed and notarized is blocked the first time it is opened on
  another Mac, until you allow it in System Settings → Privacy & Security.
- Clicking a thread from a remote bb opens it in every bb app connected to that
  bb, on every Mac and phone, not only on this Mac.
- Only one remote bb can be watched at a time.
- The menu cannot be navigated with the keyboard.
