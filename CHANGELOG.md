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
- Nothing to set up: bb Icon finds bb on its own.
- When something goes wrong — bb changed in a way this version cannot read, or a
  thread could not be opened — the menu says what happened instead of quietly
  showing nothing.

### Known limitations

- The app is not signed yet, so the first time you open it macOS asks you to
  confirm (right-click the app and choose **Open**).
- It only watches the bb app on the same Mac. A bb app connected to a remote bb
  server is not supported yet.
- The menu cannot be navigated with the keyboard.
