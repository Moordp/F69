# f69

A native F95 game manager for Linux and Windows. You can also add custom games.

<p align="center"><img src=".github/images/f69-library.png" alt="f69 library view — 1509 games in a sidebar-filtered grid"></p>

Status: alpha (0.10.x).

## Inspiration:

f69 stands on the shoulders of two great projects:

- **[F95Checker](https://github.com/WillyJL/F95Checker)** — The first app I found, was nice to easily import my library and check for updates. I took inspiration from how it worked and bits from it's UI.
- **xLibrary** — Later I found Xlibrary, also a great app, I took most inspiration from it's UI.



## Features:

- **F95Zone scraping** — sync thread metadata (rating, votes, version, dev status, last-updated, cover image), pull your bookmark list, watch for updates. Backed by an in-tree F95Indexer client (toggleable, default on) for faster bulk metadata.
- **Multi-protocol downloads** — For automatic download and install you can use rpdl and donor ddls. Or you can manually download something through the downloads links. Seeding controls (seed ratio, seed-time cap) can be changed live without a restart, and a per-host rate limiter keeps f69 polite to servers.
- **Recipe-based mod installs** — Through mod recipes, modding has never been easier. There are several default recipes for renpy and rpgm games. And for more involved mods you can make a custom recipe that you can save and reuse later, or share.(would be great if modders added this themselves)
- **Built-in mod tools** — one-click actions on a game's detail page: **RPG Maker MV/MZ** asset decryption, **Ren'Py** `.rpa` archive extraction, and Ren'Py developer-console enable. No external scripts.
- **Universal mods** — set a mod up once and apply it across every compatible game, with a per-game opt-out when you don't want it on a particular title. If a mod set can't be applied, f69 tells you *why*.
- **Sandboxed game launches** via `bwrap` — Optional sandbox. Safer, and keeps your saves in a single place.
- **Custom launch commands** — override how any install starts (point it at a specific runtime, add flags) right from the detail page.
- **Engine fix-ups** — Not all games are released with linux support, but it's possible to add it most of the time, I've included several fix-ups that add native linux support to Ren'Py and RPGM games that don't include it. RPG Maker XP/VX/VX Ace games run natively via a vendored mkxp-z runtime — no Wine, no win32.
- **Library views, your way** — browse as a grid, a sortable/resizable **list table** (whole-row click, star ratings, status dots), or a **Kanban board** grouped by how far you've gotten. Tag games with your own **labels** and filter on them, and spot **NEW** / **UPDATE** badges at a glance (with filters to show only those).
- **Themes** — light and dark modes, ready-made presets (Midnight, Paper, …) and custom accent colors, picked from a live preview in Settings → Appearance. Your choice persists across runs.
- **Always-on activity bar** — a left icon rail for navigation and a bottom status bar showing live downloads, installs, and syncs.
- **Update notifications** — desktop notification when a sync finds new releases, plus **version pinning** to hold a game on a version and suppress auto-update.
- **Portable data layout** — for the portable bundle, DB, library, covers, recipes and downloads all live in `<dir-of-binary>/data/` — drop the folder on a USB stick and the state travels with it. For system installs (`/usr/bin/f69` from a `.deb` / `.rpm` / AUR / Nix package), data falls back to `$XDG_DATA_HOME/f69` (default `~/.local/share/f69/`).
- **F95Checker / xLibrary importer** — fold an existing library into f69 without re-downloading. F95Checker imports go through a review screen showing every game from the upstream DB (opened read-only) with a Move / Copy / **Link in place** picker — link is the default and never mutates source files.
- **F95Checker DB export** — write your f69 library back to a F95Checker-shaped `db.sqlite3` (backup-rename never overwrites).
- **Per-version playtime journal** — every launch records a play session against the installed version; a per-game **Journal tab** shows your session history broken down by version, and the library row flags an unplayed update when you install a newer release than you've played past the threshold.

## Install:

Grab the matching file from the **[latest release](https://github.com/Moordp/F69/releases/latest)**.

### Linux — native package (recommended)

Native packages pull their dependencies in automatically:

```sh
# Arch / CachyOS / Manjaro
sudo pacman -U f69-*-arch-x86_64.pkg.tar.zst

# Fedora / Nobara / Bazzite / RHEL
sudo dnf install ./f69-*-fedora-x86_64.rpm

# Debian / Ubuntu / PikaOS
sudo apt install ./f69-*-debian-x86_64.deb
```

> Native packages are built against a current Arch / Fedora / Debian base. If one refuses to install on your version (glibc/soname mismatch), use a portable bundle below instead.

### Linux — portable (any distro)

**Which download?**

| Your distro | Pick |
|---|---|
| Arch / CachyOS / EndeavourOS (rolling) | AUR package (`packaging/aur/`) or the **slim** bundle |
| Debian / Ubuntu / Mint (stable, older libs) | **Full** bundle |
| Fedora and other current distros | native package, else **full** bundle |
| NixOS | full bundle, or build from source |

- **Full bundle** (`f69-*-linux-portable-x86_64.tar.gz`) — carries its own libraries **including a fallback glibc**. The launcher compares glibc versions at startup: on hosts with a same-or-newer glibc it runs against the *system* runtime (bundled one stays quarantined in `lib/glibc/`), on older hosts it falls back to the bundled one — so it no longer conflicts with the system graphics stack on rolling distros. `F69_FORCE_BUNDLED_LIBC=1` forces the fallback. Only needs your GPU's Vulkan driver + `aria2` for downloads.
- **Slim bundle** (`f69-*-linux-slim-x86_64.tar.gz`) — smaller; uses your system's libraries (install the deps below first).

```sh
tar xf f69-*-linux-portable-x86_64.tar.gz   # or the slim tarball
./bin/run.sh                                # slim extracts to ./portable-slim/run.sh
```

### Libraries the portable/slim bundle needs

On a normal **desktop / gaming distro** you almost certainly have everything already — the only thing usually missing is **aria2** (for in-app downloads):

```sh
sudo pacman -S aria2          # Arch
sudo apt install aria2        # Debian / Ubuntu
sudo dnf install aria2        # Fedora
```

On a **minimal / server** install, also add the graphical runtime libs:

```sh
# Arch
sudo pacman -S vulkan-icd-loader wayland libxkbcommon libdecor \
    libx11 libxext libxcursor libxi libxrandr dbus libarchive aria2

# Debian / Ubuntu
sudo apt install libvulkan1 libwayland-client0 libxkbcommon0 libdecor-0-0 \
    libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 libdbus-1-3 libarchive13 aria2

# Fedora / RHEL / openSUSE
sudo dnf install vulkan-loader libwayland-client libxkbcommon libdecor \
    libX11 libXext libXcursor libXi libXrandr dbus-libs libarchive aria2
```

You also need a working **Vulkan driver** for your GPU (Mesa for AMD/Intel, the proprietary driver for NVIDIA) — f69 never bundles GPU drivers. The same list lives in `DEPS.md` inside the slim tarball.

> Slim-bundle smoke-tested out-of-the-box on **CachyOS** (Arch), **PikaOS 4** (Debian), **Bazzite** (Fedora atomic), and **Nobara 43** — all launched and rendered with only `aria2` added.

### NixOS

```sh
nix run github:Moordp/F69#f69
```

### Windows

Download `f69-*-windows-x86_64.zip`, extract it anywhere, and run `f69.exe` — the zip carries its DLLs.

### From source

See [Building from source](#building-from-source) below — `zig build portable` gives you a self-contained `zig-out/bin/` folder.

## Running:

The launcher (`run.sh`) execs the bundled glibc loader and primes `LD_LIBRARY_PATH` with the host's standard GPU driver paths (`/run/opengl-driver/lib`, `/usr/lib*`). GPU vendor libs (libGL, libGLX_nvidia, libvulkan) **always come from the host driver** — never from the bundle. A Vulkan driver from one machine generally won't work on another.

The slim bundle (`zig build portable-slim` → ~57 MB, no bundled libs) is the alternative if you trust your users to install runtime deps via their distro package manager. See `zig-out/portable-slim/DEPS.md` for the per-distro install commands.

To ship a portable bundle as a tarball:

```sh
tar --exclude=data -C zig-out -czf f69-portable.tar.gz bin
```

## Roadmap:

**Shipped in 0.10.0** (these were the big roadmap items): **Windows support** — the app, the cross-compiled builds, and native game launching all work; the themeable Design-B UI; playtime tracking; the recipe-based mod system + universal mods; the multi-view library (grid / list / Kanban); a rebuilt download engine; and faster game-info retrieval via the in-tree F95Indexer client. See the [release notes](RELEASE_NOTES_0.10.0.md) for the full list.

Still on the list — not a strict plan, just what I'd like to add next:

- **Stable release** — squash the bugs people report and graduate from alpha
- **More engine fix-up recipes** — Godot, Ren'Py 6, Unity edge cases (uses fix-up library for missing libGLU.so.1 / libcurl-gnutls)
- **Mod recipe server** — for mod recipe submissions / sharing and browsing
- **Self-hosted cache server** — so fast metadata doesn't depend on F95Checker's indexer being up
- **Browser extension** — F95Checker's pattern of "right-click thread → add to library" is hard to beat
- **macOS support** — not sure... I don't have a mac, so perhaps someone can make a PR for it if they want it.


## Building from source:

`zig build` lists every target. The headline ones:

| Step            | Output                   | What it is                                                                 |
| -----------------| --------------------------| ----------------------------------------------------------------------------|
| `install`       | `zig-out/bin/f69`        | Dev binary; respects `-Doptimize=` and `-Dgui=true`                        |
| `portable`      | `zig-out/bin/`           | ReleaseSafe binary + bundled libs + `run.sh` — drop on any glibc distro    |
| `portable-slim` | `zig-out/portable-slim/` | ReleaseSafe binary + `run.sh` + `DEPS.md` — host supplies the libs         |
| `aur`           | `zig-out/aur/PKGBUILD`   | Arch PKGBUILD; add `-Dcontainer-build=true` to also produce `.pkg.tar.zst` |
| `deb`           | `zig-out/debian/`        | Debian source pkg; container build is experimental (see below)             |
| `rpm`           | `zig-out/rpm/f69.spec`   | Fedora / RHEL / openSUSE spec; container build is experimental             |
| `flake`         | —                        | Sanity-checks `flake.nix` (consumer uses `nix build .#f69`)                |
| `packages`      | all of the above         | Aggregate                                                                  |
| `test`          | —                        | Every module's `test {}` blocks                                            |

**Build flags:**

```sh
-Doptimize=Debug          # default, fast compile, assertions on
-Doptimize=ReleaseSafe    # asserts + opt — "release with debug info"
-Doptimize=ReleaseFast    # max speed, no safety, panics give no info
-Dgui=true                # link dvui + SDL3-GPU (default)
-Dgui=false               # headless build, for CI smoke tests
-Dcontainer-build=true    # invoke podman/docker for aur/deb/rpm (opt-in, see below)
```

**Windows builds** (since 0.10.0) aren't a `zig build` step — they're a cross-compile:

```sh
bash scripts/build-windows.sh      # cross-compiles f69.exe (mingw prefix via Nix)
bash scripts/package-windows.sh    # resolves the DLL closure → zig-out/f69-windows.zip
```

The CI `windows` job runs both on every tag and uploads `f69-<ver>-windows-x86_64.zip`.

## Distribution targets:

The `aur` / `deb` / `rpm` steps produce **source manifests** that downstream packagers feed to their distro's native packaging tool (`makepkg`, `dpkg-buildpackage`, `rpmbuild`). They're the durable handoff contract.

Pass `-Dcontainer-build=true` to also invoke podman or docker against the target distro's image and produce the actual binary package alongside the manifest:

- **AUR** (`archlinux:latest`): working end-to-end. Produces `f69-<ver>-1-x86_64.pkg.tar.zst`.
- **Debian** (`debian:bookworm-slim`): incomplete. Cross-distro static-libarchive symbol mismatch (xml2). Needs a Debian-host packager to wire the right `linkSystemLibrary` call.
- **RPM** (`fedora:latest`): working as of v0.9.1. Data trees install under `%{_datadir}/f69/` (FHS-correct) when invoked with `-Dfhs-layout=true`, which the spec template sets automatically.

The deeper constraint: each distro builds its static libraries with different feature flags, so "one build script, every distro" hits a long tail of per-distro fixes. Run the build on the target distro itself (your dev box or a CI matrix) for the reliable path; the container shortcut from a NixOS dev host is a convenience, not a guarantee.

## CI / releases:

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs `test` on every push to `main` and every PR; the artifact jobs and the release run **only on a `v*` tag** (or a manual dispatch). All artifacts follow `f69-<version>-<target>-x86_64.<ext>`. The matrix:

- `test` — `zig build test` + `zig build test-integration` (headless GUI tests on the dvui testing backend) on Ubuntu
- `portable` — uploads `f69-<ver>-linux-portable-x86_64.tar.gz`
- `portable-slim` — uploads `f69-<ver>-linux-slim-x86_64.tar.gz`
- `arch` — runs `makepkg` inside `archlinux:latest`, uploads `f69-<ver>-arch-x86_64.pkg.tar.zst`
- `debian` / `fedora` — native `dpkg-buildpackage` / `rpmbuild` in their target containers, upload `f69-<ver>-debian-x86_64.deb` / `f69-<ver>-fedora-x86_64.rpm`
- `windows` — cross-compiles `f69-<ver>-windows-x86_64.zip` (exe + resolved DLL closure)
- `nix` — *continue-on-error* (impure-fetch story documented in `flake.nix`)
- `release` — on `v*` tag, collects every successful artifact and posts a GitHub Release

To cut a release: `git tag v0.10.0 && git push origin v0.10.0`.

## FAQ:

<details>
<summary><b>Why a new app instead of contributing to F95Checker?</b></summary>

F95Checker is a Python + ImGui + browser-extension stack. f69 is single-binary native, runs on Linux **and Windows** (since 0.10.0), and is sandbox-first on Linux. Different design point; the codebases share basically zero in implementation while sharing many UX ideas.

If you don't need bwrap sandboxing or native rendering, F95Checker is the more mature option.

</details>

<details>
<summary><b>Why Zig?</b></summary>

Static linking story is straightforward, the language is small enough that contributors can be productive without months of ramp-up, and the cross-compile + build system handle producing the portable bundles without external tooling. Zig 0.16's `std.Io` made the aria2-RPC + concurrent-download story particularly clean.

</details>

<details>
<summary><b>Where does my data live?</b></summary>

Three tiers, first match wins:

1. `$F69_DATA_DIR` env var — explicit override, always wins. The bundled `run.sh` launchers set this to `<bundle>/data/` so data lands next to the launcher (not next to the loader inside `lib/`).
2. **Portable install** (binary anywhere user-writable) — `<dir-of-binary>/data/`.
3. **System install** (binary under `/usr/bin/`, `/nix/store/...`, or `/opt/...`) — `$XDG_DATA_HOME/f69`, defaulting to `~/.local/share/f69/`.

Layout under the resolved root: `f69.db`, `library/`, `covers/`, `recipes/`, `downloads/`, `f95_cookie`.

</details>

<details>
<summary><b>Does f69 store my F95 password?</b></summary>

No. It does an XenForo login dance once and persists the resulting session cookie at `<data_dir>/f95_cookie`. The cookie is what authenticates donor DDL pulls and the bookmark importer.

</details>

<details>
<summary><b>How do I clean up build artifacts?</b></summary>

```sh
rm -rf zig-out/
```

If you've run `-Dcontainer-build=true`, podman/docker may have written root-owned files under `zig-out/<distro>/work/`. The container scripts chown back to host UID at the end, but a crashed container leaves them as root — `sudo rm -rf zig-out/<distro>/work/` clears them.

</details>

<details>
<summary><b>What about Windows / macOS?</b></summary>

**Windows** is supported as of 0.10.0 — the CI cross-compiles `f69-<ver>-windows-x86_64.zip` (exe + DLL closure) and games launch natively. The Linux-only bits (bwrap sandbox, FHS compat layer) simply don't apply there; on Windows games run unsandboxed.

**macOS** isn't done — I don't have a Mac. Zig's cross-compile and the SDL3 / dvui / sqlite / libavif stack all build on Mac, so a PR would be welcome.

</details>

## Contributing:

The codebase lives under `src/`, one bounded context per directory:

```
src/
  main.zig          entry point; resolves data root, spawns aria2, opens DB
  ui/               dvui screens, state, components, actions
  f95/              F95Zone scraper (XenForo login, donor DDL, BBcode → plain)
  library/          SQLite-backed game store (migrations, queries)
  downloads/        aria2 JSON-RPC client + queue manager
  installer/        post-download extract / apply / sandbox launch
  importers/        F95Checker / xLibrary / folder-scan migration
  recipe/           mod recipes (JSON DAG, version constraints)
  resolver/         Kahn-style topological mod ordering
  convert/          Ren'Py SDK + nwjs / Unity / RPGM fix-ups
  compat/           per-engine FHS lib bundles (NixOS workarounds)
  sandbox/          bwrap wrapper for game launches
  util/             atomic_io, http, archive, version, paths, db, …
```

Build deps are in [`flake.nix`](flake.nix); on non-Nix systems install them with your distro's package manager (the slim-bundle `DEPS.md` has per-distro names).

Dev loop:

```sh
zig build install -Dgui=true
./zig-out/bin/f69
```

Inside the dev shell, `direnv` / `nix develop` supplies the runtime libs so the bare binary launches without `run.sh`. Watch stderr for logs.

Tests:

```sh
zig build test
```

Style + workflow notes live in [`CLAUDE.md`](CLAUDE.md). tldr: caveman prose, lead with files-modified lists, no unnecessary abstractions.

## Credits & thanks:

f69 stands on a lot of other people's work.

**Tools it bundles or drives:**

- **[mkxp-z](https://github.com/mkxp-z/mkxp-z)** (LGPL-2.1+, Amaryllis Kulla & contributors) — the runtime that makes RPG Maker XP / VX / VX Ace games run natively on Linux, vendored under `third_party/mkxp-z/`.
- **[aria2](https://aria2.github.io/)** — the download engine f69 drives over JSON-RPC.
- **[NW.js](https://nwjs.io/)** — pulled in for the RPG Maker MV / Ren'Py Windows→Linux conversions.

**Formats & techniques** — f69's built-in Ren'Py / RPG Maker tools are its own implementations of well-known community formats; thanks to the projects that pioneered and documented them:

- **UnRen** (Sam, F95Zone) — the Ren'Py `.rpa` extractor + developer-console enabler that f69's "Extract .rpa" and "Ren'Py console" tools reimplement.
- **[Petschko's RPG Maker MV/MZ Decrypter](https://github.com/Petschko/Java-RPG-Maker-MV-Decrypter)** — the reference for the `System.json` `encryptionKey` decryption behind f69's "Decrypt RPGM assets".
- **[Ren'Py](https://www.renpy.org/)** and **[RPG Maker](https://www.rpgmakerweb.com/)** themselves.

**Libraries:**

- **[Zig](https://ziglang.org/)** — the language + build system.
- **[dvui](https://github.com/david-vanderson/dvui)** (David Vanderson) — the immediate-mode GUI toolkit the whole interface is built on.
- **[SDL3](https://www.libsdl.org/)** — windowing + the GPU rendering backend.
- **[zqlite](https://github.com/karlseguin/zqlite.zig)** + **[websocket.zig](https://github.com/karlseguin/websocket.zig)** (Karl Seguin) — the SQLite wrapper and the aria2 WebSocket transport.
- **[SQLite](https://sqlite.org/)** — the library database.
- **[libavif](https://github.com/AOMediaCodec/libavif)** + **[dav1d](https://code.videolan.org/videolan/dav1d)** — AVIF cover-art decoding.
- **[libarchive](https://www.libarchive.org/)** — archive extraction (zip / 7z / rar / …).
- **[FreeType](https://freetype.org/)** + **[stb_image](https://github.com/nothings/stb)** — font and image rendering (via dvui).
- plus zlib, zstd, lz4, xz, bzip2, nettle, libxml2, and D-Bus.

And of course **[F95Checker](https://github.com/WillyJL/F95Checker)** (WillyJL) and **xLibrary** — see [Inspiration](#inspiration).

## LLM usage:

This has been supervised vibe coded. I as a software engineer told it how I wanted the code structure to be and Claude made it.

## License:

MIT — see [`LICENSE`](LICENSE).

Thanks to **WillyJL** for F95Checker — the workflow and ideas this app builds on. And to whoever maintained xLibrary before this rewrite.
