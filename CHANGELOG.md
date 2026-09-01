# Changelog

All notable, user-facing changes. Dates are YYYY-MM-DD.

## [0.13.0] - 2026-09-01

### Windows
- **Sandboxed launch is fixed — games now start with sandboxing on (the
  default).** f69 launched every game into a Sandboxie box named `f69` that it
  never created, so a normal Sandboxie-Plus install popped *"Invalid box name
  parameter: f69"* and the game never ran — while f69 reported the launch as
  successful. f69 now creates (and verifies) its sandbox box on first launch.
  If the box genuinely can't be created it says so with a clear message
  instead of silently running the game **unsandboxed** — sandboxing is a
  safety feature, so it's never dropped behind your back. Verified end-to-end
  on a real Sandboxie-Plus install: the game launches inside the box.

### Downloads
- **Portable Linux bundle: downloads work again.** The bundled `aria2c`
  couldn't find its C++ runtime (`libstdc++.so.6`) — the packaging step
  quarantines the glibc/gcc runtime into `lib/glibc/`, but `aria2c`'s own
  library search path didn't reach there, so a download died with *"error
  while loading shared libraries"*. `aria2c` is now fully self-contained via
  its own runtime path. (Native Windows and distro packages were unaffected.)
- **Fixed a crash when the download engine can't start.** A double-free on the
  aria2 startup-timeout path could abort the whole app; it's fixed and locked
  in with a regression test.

### Library
- **Each game's F95Zone thread ID now shows on its detail page** (in the meta
  bar) and is clickable — it opens that game's F95Zone thread in your browser.

## [0.12.1] - 2026-08-12

Combined notes for 0.12.0 + 0.12.1. 0.12.0 failed to build on every
non-Windows platform, so **0.12.1 is the release to install** — it contains
everything below plus additional Windows freeze fixes.

### Windows
- **Fixed games launching with the wrong file — the #1 reported Windows
  bug.** The launcher auto-pick applied Linux rules on every OS, so a Ren'Py
  game shipping both `Game.sh` and `Game.exe` got the `.sh` — which Windows
  can't run: with Sandboxie enabled the launch died with `InvalidExe`, and
  without it the spawn failed the same way. The picker is now OS-aware
  (`.exe` > `.bat`/`.cmd` on Windows) and skips uninstallers, crash handlers
  and bundled interpreters when choosing. Verified end-to-end on real
  Windows, including through a real Sandboxie install.
- **A Linux-only install now refuses to launch with a clear message**
  ("Only a Linux launcher is in this install — re-download the Windows
  build") instead of attempting a doomed spawn.
- **Launch failures now explain themselves in the app**, not just the log —
  e.g. "X is not a Windows executable (a Linux .sh / .AppImage?). Set the
  launcher explicitly on the install if the auto-pick chose wrong." Every
  install can pin its launcher explicitly as an escape hatch.
- **Downloads now work out of the box** — the Windows package bundles
  `aria2c.exe` (the download engine). Previously every clean Windows install
  had downloads silently dead unless aria2 happened to be on PATH; and when
  the engine is missing, queuing a download now fails promptly with a hint
  instead of hanging.
- **Fixed rare app freezes around just-saved files** *(0.12.1)* — reading a
  recipe or setting immediately after writing it could hang the app forever
  (a Zig 0.16 standard-library defect on Windows). These paths now use plain
  C file I/O on Windows.
- Sandboxie sees fully normalized command paths — mixed `/` and `\`
  separators (`...\library/181313/final`) no longer reach `Start.exe`.
- Sandboxed games get `USERPROFILE` redirected alongside `HOME`, so per-game
  save isolation actually isolates on Windows.
- All of the above is locked in by a new automated GUI test suite that runs
  natively on Windows — including real process launches with and without
  Sandboxie.

### Linux
- **Fixed a crash on launch on Fedora** (and potentially other distros) when
  started from a terminal or the applications menu — an SDL/Wayland
  startup-notification interaction; launching now works from every route.
  (This fix is what broke 0.12.0's build; 0.12.1 ships it correctly.)

### General
- Recipe index scanning is bounded and reports partial results instead of
  walking unbounded directory trees.
- 0.12.1 fixes 0.12.0 failing to compile on all non-Windows targets
  (portable, deb, rpm, AUR).

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

[0.13.0]: https://github.com/Moordp/F69/releases/tag/v0.13.0
[0.12.1]: https://github.com/Moordp/F69/releases/tag/v0.12.1
[0.11.1]: https://github.com/Moordp/F69/releases/tag/v0.11.1
[0.11.0]: https://github.com/Moordp/F69/releases/tag/v0.11.0
