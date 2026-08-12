# Changelog

All notable, user-facing changes. Dates are YYYY-MM-DD.

## [0.12.0] - 2026-08-12

### Windows
- **Downloads now work out of the box** — the Windows package bundles
  `aria2c.exe` (the download engine). Previously every clean Windows install
  had downloads silently dead unless aria2 happened to be on PATH.
- The launch pipeline, sandbox integration and settings flows are now covered
  by an automated GUI test suite that runs natively on Windows — including
  real process launches with and without Sandboxie. Several Windows-specific
  bugs-in-waiting were fixed along the way (mis-picked launchers surface an
  actionable message; a missing download engine fails cleanly with a hint).
- Settings files and recipes are read via a more robust path on Windows,
  sidestepping rare cases where a just-written file could stall the app.

### Linux
- **Fixed a crash on launch on Fedora** (and potentially other distros) when
  started from a terminal or the applications menu — an SDL/Wayland
  startup-notification interaction; launching now works from every route.

### General
- Recipe index scanning is bounded and reports partial results instead of
  walking unbounded directory trees.

## [0.11.1] - 2026-07-29

A Windows-focused fix release.

### Windows
- **Fixed importing from F95Checker or xLibrary on Windows silently skipping
  every game's install folder** — games showed up in your library but marked
  "not installed," with no explanation. The importer only understood Unix-style
  paths; it now reads Windows-style paths correctly too.
- **F95Checker/xLibrary import no longer dead-ends on a nonstandard setup.** If
  the app can't auto-detect the source database (moved config folder, portable
  install, unusual environment), you're now offered a file picker to point at
  it directly instead of just failing.
- Fixed the bundled `aria2c.exe` download-helper detection and the underlying
  exe-folder resolution it depends on, which never worked on a native Windows
  launch.
- Settings → Browser auto-detect now actually finds installed browsers on
  Windows (it silently found nothing there before).

### Reliability
- **Crashes are now logged** to a file (`%LOCALAPPDATA%\f69\crashes` on
  Windows, `~/.cache/f69/crashes` on Linux/macOS) you can attach to a bug
  report — this never worked on any platform before.

## [0.11.0] - 2026-07-28

A big release focused on getting **everyone logged in**, protecting your data,
and making the app readable and reliable across distros.

### Sign-in & accounts
- **You can now log in even with 2FA or a passkey.** New **"Sign in with browser
  cookie"** option on the login card: log in to F95Zone in your browser (there's
  an *Open F95 login page* button), then paste your `xf_user` / `xf_session`
  cookies. f69 verifies them before accepting. This is the only way passkey
  accounts can sign in, and it works for any 2FA setup.
- **Native 2FA code prompt** for authenticator-app (TOTP) logins — enter your
  6-digit code right in the app.
- Sign-in errors are clearer and point you to the method that will work.

### Library & organization
- **Per-tag colors**, including your own custom colors, on tag chips.
- **"My rating" filter** — filter by *your* rating, separately from the community
  score.
- **Edit game info** for orphaned / non-F95 games (name, developer, version,
  engine).
- The library list **refreshes live** when you edit a game — no manual reload.
- **ADRIFT, RAGS, TADS and WebGL** are now recognized as first-class engines.

### Saves, backups & mods
- **Import saves** into a game's sandboxed home — any existing saves are backed
  up first.
- **Automatic timestamped database backups** on startup, so your library is
  always recoverable (kept and pruned automatically).
- **Universal mods now actually install** across every matching game, and tell
  you exactly what was skipped and *why*.

### Updates
- Optional **RSS latest-updates** source for the update check.

### Reliability & your data
- Fixed a **crash during "Sync All"** triggered by concurrent cover-image
  downloads.
- Sync **no longer "forgets" installed versions** of your games.
- Clicking a game in the **list view always opens the right game** now (it could
  open the wrong one when filters were active).
- Fixed a **phantom "UPDATE" badge** that appeared after some syncs.
- Failed syncs and tag edits now **show an error** instead of failing silently.
- Hardened against data loss: safer database migrations, saves backed up before
  they can be overwritten, and "delete install" refuses to touch your saves.
- **GPU / Vulkan startup problems** now print a clear, actionable message
  (which driver to install) instead of a raw crash.

### Readability
- Fixed **invisible text** in several spots — settings section titles, the
  sync-recap popup, toasts, and the downloads / recipe screens — most visible on
  the light **Paper** theme.

### Windows
- "Open folder" actions and temporary-file handling now work correctly on
  Windows.

### Packaging & install
- **Arch package** now declares its runtime libraries (libavif, dav1d, …) —
  fixes a *"cannot open shared object file"* failure right at launch.
- **Portable bundle** chooses the system vs. its bundled glibc at launch, fixing
  startup on newer distros.
- `--version` now always matches the package version (single-sourced).
- **Find your logs:** the Diagnostics screen shows the log folder with an
  *Open log folder* button, and the README documents where logs live — attach
  the newest log when reporting a bug.

### Under the hood
- Automated per-package smoke tests (deb, rpm, Arch, portable, slim, Windows,
  Nix), fuzz targets, and headless UI integration tests. CI actions moved off
  the deprecated Node 20 runtime.

[0.11.1]: https://github.com/Moordp/F69/releases/tag/v0.11.1
[0.11.0]: https://github.com/Moordp/F69/releases/tag/v0.11.0
