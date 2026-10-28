# Changelog

All notable, user-facing changes. Dates are YYYY-MM-DD.

## [0.15.7] - 2026-10-28

### Changed
- **Removed the hover preview from grid (and kanban) cards.** Hovering a card
  cover no longer pops up the large image. The list view keeps its preview.

## [0.15.6] - 2026-10-28

### Changed
- **Grid covers are cropped less.** Every card has the same fixed cover size.
  A cover is cropped toward that shape by at most a quarter; the rest is shown
  with dark bars. On a typical F95 library this keeps at least 75% of the image
  for about 9 in 10 covers (it used to keep about 67% on average, and wide
  banners lost far more). Very wide banners are still cropped at the sides,
  centered.
- **New setting: grid cover shape** (Settings → Library → *Grid view covers*):
  2 : 1, 2.5 : 1 or 3 : 1 (default). A narrower shape makes taller cards that
  show more of each cover.
- **Hover a cover in the grid** to see it whole at a larger size.

### Fixed
- **Grid columns had different widths.** The last column could be narrower than
  the rest, because the column sizes were worked out from a guessed sidebar
  width. They now use the real width of the grid area, so all cards in a row
  are the same size.

## [0.15.5] - 2026-10-28

### Changed
- **List view covers use a wider slot (144×48, about 3:1)** so wide banners —
  most F95 covers — fill it. Settings → Library → *List view covers* picks the
  shape: **Fit** (whole cover, empty space at the sides — the default) or
  **Fill** (crop to the slot).
- **Hover a cover in the list** to see it whole at a larger size.

### Fixed
- **The "Check-for-updates source" setting was missing from Settings** (it was
  hidden in code), so the RSS and new-versions-feed sources from 0.15.2 could
  not be picked. It is back in Settings → Updates.

## [0.15.4] - 2026-10-27

### Changed
- **List view covers are shown whole.** Each cover is scaled to fit a fixed
  96×54 slot with its own proportions — no more squeezed or stretched images.
  Narrow (portrait) covers get empty space on the sides. Names stay lined up.

### Fixed
- **Cover floated in the middle of the Name column** (and could cover the game
  name in a narrow window) since 0.15.3. It now sits at the left, before the name.
- Engine, Updated and Played columns are wider, so "RPGM MV" and the headers
  are no longer cut off.

## [0.15.3] - 2026-10-27

### Fixed
- **Every game showed a STATUS badge** after a bookmark import and sync. The
  first sync of a new game (status unknown → known) counted as a status change.
  Only real changes, such as Ongoing → Completed, get the badge now. Badges
  already set stay for up to 14 days.
- **List view layout**: the Name column now takes the spare width instead of
  leaving an empty gap on the right, and the Version column is wider so
  versions are cut off less.

## [0.15.2] - 2026-10-27

### New
- **New-versions feed for "Check for updates"** (Settings → Check-for-updates
  source → *F95 new-versions feed (login)*). Reads your F95 watched-threads
  "new versions" page, newest first, back to your last check — a few requests
  instead of checking every game. Games in your library get their new version
  right away, then sync as usual. It only covers threads you watch, needs you
  logged in, and falls back to a full check if the feed doesn't reach back to
  your last check.

## [0.15.1] - 2026-10-27

### Fixes
- **Pull bookmarks now gets all your bookmarked games.** 0.15.0 only found a
  few hundred, because F95 splits the bookmarks page into a short Games preview
  and a Posts list. f69 now reads the full games list (sorted by date added, so
  paging doesn't shift) and takes each game's name, version and developer from
  its title, so versions show right after the pull.

## [0.15.0] - 2026-10-27

### Fixes
- **Pull bookmarks works again.** F95 moved bookmarks to its new watched-threads
  page, so the pull found only a handful of unrelated links and stopped. f69 now
  reads your bookmarks from the new pages (both the classic and the new layout)
  and walks every page.

### Under the hood
- Built with **Zig 0.17** (was 0.16), with updated GUI (dvui), SQLite and
  websocket libraries. The library list uses the new grid widget.
- The Windows build works on Zig 0.17: the bundled `websocket` copy carries a
  small fix for the removed Windows socket read call (see
  `third_party/websocket/F69_PATCHES.md`).
- Packaging (`zig build portable|aur|deb|rpm`) now runs from `tools/dist.zig`,
  because Zig 0.17 no longer allows custom build steps.

## [0.14.1] - 2026-09-01

Combined notes for 0.13.0 – 0.14.1. **0.14.1 is the release to install.**

### Set-your-own folders (new)
Four things f69 normally places for you can now be pointed wherever you want —
automatic by default, manual when you need it:
- **Downloads folder** (Settings → Downloads) — put downloads on a bigger disk.
- **Download engine** (Settings → Downloads) — browse to an `aria2c` binary when
  the bundled one / your PATH can't be found, so downloads work anyway.
- **Covers folder** (Settings → Library) — move the cover/screenshot image cache
  to another volume.
- **Saves folder** (a game's ⋯ menu → *"Set saves folder…"*) — tell f69 where a
  game actually keeps its saves, so *Open / Backup / Import saves* target the
  right place; *"Use default saves folder"* reverts it.

The three Settings folders apply on restart.

### Games & installs
- **Point f69 at a game you already have installed** (⋯ → *"Set install
  folder…"*) — pick the folder the game already lives in, so a game added
  without a download path (imported from F95Checker, or a folder whose name
  didn't match on import) becomes launchable — no re-downloading, no renaming.
- **Fix or change a game's F95 thread** (⋯ → *"Set F95 thread URL…"*) — takes a
  thread link or id and re-syncs from it. A *different* thread moves the game —
  and everything attached to it (installs, mods, saves) — to the correct one.
  It refuses if that thread is already a separate game in your library.
- **A game's F95Zone thread number now shows on its detail page and links
  straight to the thread** — click it to open that game on F95Zone.

### Windows
- **Sandboxed games launch again.** With sandboxing on (the default), Play did
  nothing except pop up a Sandboxie *"Invalid box name parameter: f69"* error —
  and f69 wrongly treated it as a successful launch. f69 now sets up its
  sandbox the first time you launch a game. If it can't, you get a clear
  message instead of the game quietly running **without** the sandbox.

### Downloads (fixes)
- **The portable Linux build can download again** — its bundled download engine
  was missing a library it needed and failed to start. (The Windows and
  deb / rpm / Arch builds were never affected.)
- **Fixed a crash when the download engine fails to start.**

### Fixed
- The Downloads settings page laid its sections out sideways / off-screen —
  they now stack correctly.

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

[0.14.1]: https://github.com/Moordp/F69/releases/tag/v0.14.1
[0.12.1]: https://github.com/Moordp/F69/releases/tag/v0.12.1
[0.11.1]: https://github.com/Moordp/F69/releases/tag/v0.11.1
[0.11.0]: https://github.com/Moordp/F69/releases/tag/v0.11.0
