// f69 — Zig + dvui rewrite of XLibrary, F95Zone-only.
//
// Layout: bounded contexts under src/<context>/. Each context exposes its
// public API through `<context>/<context>.zig`. Module names registered
// here (`library`, `recipe`, ...) match the public file names so call
// sites do `@import("library")` etc.
//
// dvui is opt-in via `-Dgui=true`. Skeleton compiles without it; once
// `zig fetch --save git+https://github.com/david-vanderson/dvui#main`
// has run, build with `-Dgui=true` to actually link the GUI.
//
// See docs/PLAN.md for the master plan and decisions.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to a portable baseline CPU (x86_64_v1 / equivalent) so
    // CI/release builds run on ANY x86-64 host. Without this, a bare
    // `zig build` resolves to the *build machine's* native CPU model +
    // features — the binary then SIGILLs ("Illegal instruction") on
    // user CPUs lacking those features. Dev can opt back into native
    // codegen with `-Dcpu=native`; `-Dtarget=` also still overrides.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    // ----- root-level modules -----

    const config_mod = mod(b, "config", "src/config.zig", target, optimize);

    // Build-time options surface — version string is currently the only
    // entry. UI's Diagnostics screen and main.zig's `--version` CLI flag
    // import this to show "f69 vX.Y.Z" so bug reports identify the build.
    // Single-sourced from `.version` in build.zig.zon (same value the dist
    // packaging steps read) so the binary and the packages never disagree —
    // a mismatch the package smoke test (scripts/smoke-package.sh) enforces.
    const app_version: []const u8 = readVersion(b) catch "0.0.0";
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", app_version);
    const build_opts_mod = build_opts.createModule();

    // ----- util modules -----

    const util_paths_mod = mod(b, "util_paths", "src/util/paths.zig", target, optimize);
    const util_kahn_mod = mod(b, "util_kahn", "src/util/kahn.zig", target, optimize);
    // zqlite (karlseguin/zqlite.zig) bundles a static sqlite3 — no system
    // sqlite3 dependency needed. Module name in dvui's pkg cache: "zqlite".
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const util_db_mod = mod(b, "util_db", "src/util/db.zig", target, optimize);
    util_db_mod.addImport("zqlite", zqlite_dep.module("zqlite"));
    const util_crash_mod = mod(b, "util_crash", "src/util/crash.zig", target, optimize);
    util_crash_mod.addImport("util_paths", util_paths_mod);
    const util_version_mod = mod(b, "util_version", "src/util/version.zig", target, optimize);
    const util_renpy_mod = mod(b, "util_renpy", "src/util/renpy.zig", target, optimize);
    const util_atomic_io_mod = mod(b, "util_atomic_io", "src/util/atomic_io.zig", target, optimize);
    util_crash_mod.addImport("util_atomic_io", util_atomic_io_mod);
    const util_domain_mod = mod(b, "util_domain", "src/util/domain.zig", target, optimize);
    const util_http_mod = mod(b, "util_http", "src/util/http.zig", target, optimize);
    util_http_mod.addImport("build_options", build_opts_mod);
    const util_proc_mod = mod(b, "util_proc", "src/util/proc.zig", target, optimize);
    const util_setting_mod = mod(b, "util_setting", "src/util/setting.zig", target, optimize);
    const util_test_env_mod = mod(b, "util_test_env", "src/util/test_env.zig", target, optimize);
    // std.c.getenv for the platform temp dir (%TEMP% on Windows, $TMPDIR
    // elsewhere) — the tmpdir root used to be a hardcoded POSIX /tmp, which is
    // meaningless on Windows and hung the suite there.
    util_test_env_mod.link_libc = true;
    // Tests-only fixture. Every module whose test block hand-rolled a
    // tmpdir pre-R11 follow-up now imports `util_test_env` for the
    // shared `TestEnv`. Imports are no-ops at runtime — the type is
    // only referenced inside `test {}` blocks, which the release build
    // drops.
    util_atomic_io_mod.addImport("util_test_env", util_test_env_mod);
    util_crash_mod.addImport("util_test_env", util_test_env_mod);

    // util_archive: thin Zig wrapper around libarchive's read API.
    // Used by downloads/archive.zig for the formats stdlib doesn't
    // cover (.7z, .tar.bz2, .tar.xz, .rar). libarchive itself is the
    // static archive from `pkgs.libarchive-static` in flake.nix —
    // includes bz2 + xz + zlib decompression bundled in.
    const util_archive_mod = b.addModule("util_archive", .{
        .root_source_file = b.path("src/util/archive.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    util_archive_mod.linkSystemLibrary("archive", .{ .preferred_link_mode = .static });
    {
        const tc = cTranslate(b, "archive_c.h", "#include <archive.h>\n#include <archive_entry.h>\n", target, optimize);
        addPkgConfigIncludes(b, tc, "libarchive");
        util_archive_mod.addImport("c", tc.createModule());
    }
    // libarchive.a references undefined symbols from a fan of helper
    // libraries — every feature enabled at libarchive build time
    // (and Debian/Fedora/Nix all enable the full set) adds another
    // unresolved dep here. Dynamic-link them so the f69 binary picks
    // them up from the desktop's standard libs at runtime. A "truly
    // static everything" build would need static overrides for each
    // (similar to dav1d-static); deferred until the Windows port
    // forces the issue.
    util_archive_mod.linkSystemLibrary("z", .{}); // gzip
    // bzip2's SONAME splits across distros — libbz2.so.1.0 on
    // Debian/Ubuntu (and the GH-Actions release builder), libbz2.so.1
    // on Fedora/Bazzite. A dynamic link bakes the build-host soname
    // into DT_NEEDED, so the slim bundle (no bundled libs) fails to
    // load on the *other* family. Static-link it instead — the f69
    // binary then carries no libbz2 dependency at all. Needs libbz2.a:
    // Debian/Fedora -dev packages ship it; nix uses `bzip2-static`.
    util_archive_mod.linkSystemLibrary("bz2", .{ .preferred_link_mode = .static }); // bzip2
    util_archive_mod.linkSystemLibrary("lzma", .{}); // xz
    util_archive_mod.linkSystemLibrary("zstd", .{}); // zstd in .7z/.zip
    util_archive_mod.linkSystemLibrary("lz4", .{}); // lz4 filter
    util_archive_mod.linkSystemLibrary("nettle", .{}); // AES / SHA / HMAC
    util_archive_mod.linkSystemLibrary("xml2", .{}); // .xar metadata
    // POSIX ACL restore — no POSIX ACLs and no mingw libacl on Windows; libarchive
    // built for mingw doesn't reference the acl symbols, so skip the link there.
    if (target.result.os.tag != .windows) util_archive_mod.linkSystemLibrary("acl", .{}); // POSIX ACL restore

    // util_file_picker: Zig binding around vendored NFDe
    // (`zig-pkg/nfde/`). Wayland-correct file picker via XDG portal
    // on Linux; native dialogs on Windows + macOS. Per-platform
    // backend file + system libraries wired below.
    const file_picker_mod = b.addModule("util_file_picker", .{
        .root_source_file = b.path("src/util/file_picker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // C++17 backends (portal.cpp, win.cpp); the Cocoa backend is
        // an Objective-C file but still needs libcpp linked for the
        // shared NFDe helpers when targeting macOS.
        .link_libcpp = true,
    });
    file_picker_mod.addIncludePath(b.path("zig-pkg/nfde/src/include"));
    {
        const tc = cTranslate(b, "nfd_c.h", "#include <nfd.h>\n", target, optimize);
        tc.addIncludePath(b.path("zig-pkg/nfde/src/include"));
        file_picker_mod.addImport("c", tc.createModule());
    }
    switch (target.result.os.tag) {
        .linux => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_portal.cpp"),
                .flags = &.{ "-std=c++17", "-DNFD_PORTAL=1" },
            });
            // libdbus-1 for the portal D-Bus dance. Provided by
            // `pkgs.dbus.dev` in the flake; runtime resolves the
            // .so from the desktop session.
            file_picker_mod.linkSystemLibrary("dbus-1", .{});
        },
        .windows => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_win.cpp"),
                .flags = &.{"-std=c++17"},
            });
            file_picker_mod.linkSystemLibrary("ole32", .{});
            file_picker_mod.linkSystemLibrary("uuid", .{});
            file_picker_mod.linkSystemLibrary("shell32", .{});
        },
        .macos => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_cocoa.m"),
                .flags = &.{"-fobjc-arc"},
            });
            file_picker_mod.linkFramework("AppKit", .{});
            file_picker_mod.linkFramework("UniformTypeIdentifiers", .{});
        },
        else => {},
    }

    // ----- bounded contexts -----

    const library_mod = mod(b, "library", "src/library/library.zig", target, optimize);
    library_mod.addImport("util_db", util_db_mod);
    library_mod.addImport("util_version", util_version_mod);
    library_mod.addImport("util_domain", util_domain_mod);

    const recipe_mod = mod(b, "recipe", "src/recipe/recipe.zig", target, optimize);
    recipe_mod.addImport("util_version", util_version_mod);
    recipe_mod.addImport("util_atomic_io", util_atomic_io_mod);
    recipe_mod.addImport("util_domain", util_domain_mod);

    const resolver_mod = mod(b, "resolver", "src/resolver/resolver.zig", target, optimize);
    resolver_mod.addImport("recipe", recipe_mod);
    resolver_mod.addImport("util_kahn", util_kahn_mod);
    resolver_mod.addImport("util_version", util_version_mod);

    const f95_mod_ = mod(b, "f95", "src/f95/f95.zig", target, optimize);
    f95_mod_.addImport("util_atomic_io", util_atomic_io_mod);
    f95_mod_.addImport("build_options", build_opts_mod);

    // F95Indexer cache API client — peer of f95_mod_. Auth-free, lives
    // outside `f95/` because it doesn't touch the forum session.
    const f95_indexer_mod = mod(b, "f95_indexer", "src/f95_indexer/f95_indexer.zig", target, optimize);
    f95_indexer_mod.addImport("util_http", util_http_mod);
    f95_indexer_mod.addImport("library", library_mod);
    f95_indexer_mod.addImport("build_options", build_opts_mod);

    // Image decoding context. Wraps libavif so the sync worker can
    // transcode F95Zone CDN's AVIF screenshots to RGBA and re-encode
    // them as PNG at write time. libavif and its dav1d backend are
    // statically linked (see flake.nix overlays libavif-static /
    // dav1d-static) — the resulting f69 binary doesn't depend on
    // either .so at run time. PNG/JPEG/GIF stay on dvui's stb_image.
    const image_mod = b.addModule("image", .{
        .root_source_file = b.path("src/image/image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // NOTE: the Windows target must be built with -Doptimize=ReleaseFast (not ReleaseSafe).
    // ReleaseSafe enables _FORTIFY_SOURCE, which turns on MinGW's fortified <wchar.h> inlines
    // (wcscat/wcscpy); zig 0.16 translate-c mis-translates those into an unused `extern_local_*`
    // const that fails compilation in every @cImport (avif, SDL3, dvui). ReleaseFast avoids it.
    image_mod.linkSystemLibrary("avif", .{ .preferred_link_mode = .static });
    {
        const tc = cTranslate(b, "avif_c.h", "#include <avif/avif.h>\n", target, optimize);
        addPkgConfigIncludes(b, tc, "libavif");
        image_mod.addImport("c", tc.createModule());
    }
    image_mod.linkSystemLibrary("dav1d", .{ .preferred_link_mode = .static });

    const downloads_mod = mod(b, "downloads", "src/downloads/downloads.zig", target, optimize);
    downloads_mod.addImport("recipe", recipe_mod);
    downloads_mod.addImport("util_version", util_version_mod);
    downloads_mod.addImport("util_archive", util_archive_mod);
    downloads_mod.addImport("util_atomic_io", util_atomic_io_mod);
    downloads_mod.addImport("util_http", util_http_mod);
    downloads_mod.addImport("util_proc", util_proc_mod);
    downloads_mod.addImport("util_test_env", util_test_env_mod);
    downloads_mod.addImport("build_options", build_opts_mod);

    const installer_mod = mod(b, "installer", "src/installer/installer.zig", target, optimize);
    installer_mod.addImport("library", library_mod);
    installer_mod.addImport("recipe", recipe_mod);
    installer_mod.addImport("resolver", resolver_mod);
    installer_mod.addImport("downloads", downloads_mod);
    installer_mod.addImport("util_archive", util_archive_mod);
    installer_mod.addImport("util_atomic_io", util_atomic_io_mod);
    installer_mod.addImport("util_proc", util_proc_mod);
    installer_mod.addImport("util_test_env", util_test_env_mod);

    // Importers — read F95Checker SQLite + xLibrary JSON config files
    // and translate to library.Game shape. Settings UI invokes these.
    const importers_mod = mod(b, "importers", "src/importers/importers.zig", target, optimize);
    importers_mod.addImport("util_db", util_db_mod);
    importers_mod.addImport("util_domain", util_domain_mod);
    importers_mod.addImport("util_test_env", util_test_env_mod);

    const convert_mod = mod(b, "convert", "src/convert/convert.zig", target, optimize);
    convert_mod.addImport("util_renpy", util_renpy_mod);
    convert_mod.addImport("util_atomic_io", util_atomic_io_mod);
    convert_mod.addImport("util_domain", util_domain_mod);
    convert_mod.addImport("util_http", util_http_mod);
    convert_mod.addImport("util_proc", util_proc_mod);
    convert_mod.addImport("util_test_env", util_test_env_mod);
    convert_mod.addImport("build_options", build_opts_mod);

    const compat_mod = mod(b, "compat", "src/compat/compat.zig", target, optimize);
    compat_mod.addImport("util_version", util_version_mod);
    compat_mod.addImport("util_renpy", util_renpy_mod);
    compat_mod.addImport("util_domain", util_domain_mod);
    compat_mod.addImport("util_test_env", util_test_env_mod);

    const sandbox_mod = mod(b, "sandbox", "src/sandbox/sandbox.zig", target, optimize);
    sandbox_mod.addImport("library", library_mod);
    sandbox_mod.addImport("util_paths", util_paths_mod);
    sandbox_mod.addImport("util_domain", util_domain_mod);
    sandbox_mod.addImport("util_proc", util_proc_mod);
    sandbox_mod.addImport("util_test_env", util_test_env_mod);

    const server_mod = mod(b, "server", "src/server/server.zig", target, optimize);
    server_mod.addImport("library", library_mod);

    const ui_mod = mod(b, "ui", "src/ui/ui.zig", target, optimize);
    ui_mod.addImport("library", library_mod);
    ui_mod.addImport("recipe", recipe_mod);
    ui_mod.addImport("resolver", resolver_mod);
    ui_mod.addImport("f95", f95_mod_);
    ui_mod.addImport("f95_indexer", f95_indexer_mod);
    ui_mod.addImport("downloads", downloads_mod);
    ui_mod.addImport("sandbox", sandbox_mod);
    ui_mod.addImport("convert", convert_mod);
    ui_mod.addImport("compat", compat_mod);
    ui_mod.addImport("installer", installer_mod);
    ui_mod.addImport("importers", importers_mod);
    ui_mod.addImport("image", image_mod);
    ui_mod.addImport("util_version", util_version_mod);
    ui_mod.addImport("util_paths", util_paths_mod);
    ui_mod.addImport("util_file_picker", file_picker_mod);
    ui_mod.addImport("util_atomic_io", util_atomic_io_mod);
    ui_mod.addImport("build_options", build_opts_mod);

    // ----- executable -----
    //
    // Note: an `app` orchestrator module was sketched here but had
    // dangling-pointer issues (locals captured into a returned struct).
    // Removed in the round-9 review pass; phase-2+ orchestration will
    // need a heap-allocated `App` instead.

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("config", config_mod);
    exe_mod.addImport("library", library_mod);
    exe_mod.addImport("f95", f95_mod_);
    exe_mod.addImport("f95_indexer", f95_indexer_mod);
    exe_mod.addImport("downloads", downloads_mod);
    exe_mod.addImport("recipe", recipe_mod);
    exe_mod.addImport("sandbox", sandbox_mod);
    exe_mod.addImport("convert", convert_mod);
    exe_mod.addImport("compat", compat_mod);
    exe_mod.addImport("ui", ui_mod);
    exe_mod.addImport("util_crash", util_crash_mod);
    exe_mod.addImport("util_setting", util_setting_mod);
    exe_mod.addImport("build_options", build_opts_mod);

    // dvui — opt-in. After `zig fetch --save git+…/dvui`, build with
    // `-Dgui=true` to link the SDL3 backend.
    // dvui is now integral to the UI; default `-Dgui=true`. Pass
    // `-Dgui=false` for headless / CI builds that only need the non-UI
    // modules to compile.
    const enable_gui = b.option(bool, "gui", "Link dvui (default true)") orelse true;
    // Install data trees (mkxp-z bundle + compat resources) under
    // `<prefix>/share/f69/data/` instead of the default
    // `<prefix>/bin/data/`. Set this when packaging for a Linux distro
    // that follows FHS — putting 50 MB of Ruby stdlib under /usr/bin
    // makes rpm/dpkg's shebang-mangler walk the bundle and rewrite
    // `/usr/bin/env ruby` to `/usr/bin/ruby`, breaking the embedded
    // mkxp-z runtime. Portable builds keep the default.
    const fhs_layout = b.option(bool, "fhs-layout", "Install data under share/f69/data/ (FHS) instead of bin/data/ (portable)") orelse false;
    // Pass `-Dbackend=sdl3gpu` to dvui so it only builds the SDL3 GPU
    // backend; without this it builds all backends and the resulting
    // module names collide ("file exists in modules 'dvui' and 'dvui0'").
    const dvui_dep_opt: ?*std.Build.Dependency = if (enable_gui)
        b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = @as([]const u8, "sdl3gpu"),
        })
    else
        null;
    if (dvui_dep_opt) |dep| {
        ui_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
        // The SDL3-GPU backend lives only in the exe now — `ui` is
        // backend-agnostic so it can be rebuilt against dvui's testing
        // backend for headless integration tests. main owns the window.
        exe_mod.addImport("sdl3gpu-backend", dep.module("sdl3gpu"));
        exe_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
    }

    const exe = b.addExecutable(.{
        .name = "f69",
        .root_module = exe_mod,
    });
    // Emit a GNU build-ID note (`.note.gnu.build-id`). Fedora's
    // rpmbuild + Debian's debian-policy require this for every
    // installed ELF — otherwise `find-debuginfo` aborts the .rpm
    // build with "No build ID note found". `.sha1` is deterministic
    // over the binary content (same input → same id), good for
    // crash-dump symbol matching.
    exe.build_id = .sha1;
    b.installArtifact(exe);

    // Desktop integration — a `.desktop` entry + icon so f69 appears in
    // application menus / launchers. Lands under share/, so the native
    // packages (which run `zig build install --prefix /usr`) pick them up
    // automatically; the portable bundle copies only bin/, ignoring these.
    {
        const wf = b.addWriteFiles();
        const desktop = wf.add("f69.desktop", DESKTOP_ENTRY);
        const icon = wf.add("f69.svg", ICON_SVG);
        const di = b.addInstallFile(desktop, "share/applications/f69.desktop");
        const ii = b.addInstallFile(icon, "share/icons/hicolor/scalable/apps/f69.svg");
        b.getInstallStep().dependOn(&di.step);
        b.getInstallStep().dependOn(&ii.step);
    }

    // Compat resources — directories the compat module's recipes
    // resolve at runtime. Each one is a Nix-built lib bundle landed
    // under `<install>/bin/data/compat-resources/<id>/`. The flake's
    // shellHook exports F69_COMPAT_<NAME> env vars pointing at the
    // built derivations; `zig build run` consumes them. Non-Nix
    // builds will see the env var unset and ship without the
    // bundle — the runtime detector still fires, the apply step
    // then reports `ResourceNotMaterialized` instead of silently
    // doing the wrong thing.
    const data_prefix: []const u8 = if (fhs_layout) "share/f69/data" else "bin/data";
    installCompatResource(b, "renpy7-fhs-libs", "F69_COMPAT_RENPY7_FHS_LIBS", data_prefix);
    installCompatResource(b, "renpy8-fhs-libs", "F69_COMPAT_RENPY8_FHS_LIBS", data_prefix);
    installCompatResource(b, "rpgm-mv-fhs-libs", "F69_COMPAT_RPGM_MV_FHS_LIBS", data_prefix);
    installCompatResource(b, "mkxp-z-fhs-libs", "F69_COMPAT_MKXP_Z_FHS_LIBS", data_prefix);
    installCompatResource(b, "unity-fhs-libs", "F69_COMPAT_UNITY_FHS_LIBS", data_prefix);

    // Vendored mkxp-z (RGSS reimplementation — runs RPGM XP/VX/VX Ace
    // games natively on Linux). Source tree is checked into
    // `third_party/mkxp-z/linux-x86_64/` per its README.md; we copy it
    // verbatim into the install tree. Linux x86_64 only — the convert
    // dispatch in `src/convert/rpgm.zig` no-ops on other targets.
    if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) {
        const mkxp_subdir = std.fmt.allocPrint(b.allocator, "{s}/mkxp-z", .{data_prefix}) catch @panic("OOM");
        const mkxp_install = b.addInstallDirectory(.{
            .source_dir = b.path("third_party/mkxp-z/linux-x86_64"),
            .install_dir = .{ .custom = mkxp_subdir },
            .install_subdir = "",
        });
        b.getInstallStep().dependOn(&mkxp_install.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ----- distribution targets -----
    //
    // Each named step runs `tools/dist.zig` (a plain host executable —
    // Zig 0.17 has no custom make-time steps) with the repo root as cwd.
    // No shell scripts anywhere — manifest text and the ldd parsing +
    // patchelf invocation live in that tool.
    //
    // Outputs (all relative to repo root):
    //   portable      → zig-out/bin/         binary + bundled libs + run.sh
    //   portable-slim → zig-out/portable-slim/  binary + run.sh + DEPS.md
    //   aur           → zig-out/aur/PKGBUILD    Arch source manifest
    //   deb           → zig-out/debian/         Debian source manifest
    //   rpm           → zig-out/rpm/f69.spec    Fedora/RHEL spec
    //   flake         → no fs output — invokes `nix flake check`
    //
    // The portable steps re-invoke `zig build install -Doptimize=ReleaseFast`
    // as a sub-build so they always operate on a ReleaseFast binary
    // regardless of the user's -Doptimize flag for the outer invocation.
    const version = readVersion(b) catch "0.0.0";

    // Container builds (aur/deb/rpm → real .pkg/.deb/.rpm via podman/docker)
    // are OPT-IN. Default is manifest-only — fast, reliable, no container
    // engine required. Pass `-Dcontainer-build=true` to actually invoke
    // the target distro's packaging tool inside a container.
    //
    // Why opt-in: each distro's static-libarchive / glibc / linker setup
    // diverges from the build host's, so the container path needs
    // per-distro polish (currently only AUR is fully working). Treating
    // it as opt-in keeps `zig build packages` quick and reliable, and
    // lets devs iterate on container packaging when they're shipping.
    const enable_container = b.option(bool, "container-build", "Invoke podman/docker for aur/deb/rpm — currently only AUR is fully working") orelse false;

    const dist_exe = b.addExecutable(.{
        .name = "dist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dist.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const packages_step = b.step("packages", "Build every distribution target");

    inline for (.{
        .{ .kind = "aur", .name = "aur", .desc = "Generate Arch PKGBUILD (zig-out/aur/) — add -Dcontainer-build=true to also build .pkg.tar.zst" },
        .{ .kind = "deb", .name = "deb", .desc = "Generate Debian source pkg (zig-out/debian/) — container build incomplete" },
        .{ .kind = "rpm", .name = "rpm", .desc = "Generate RPM spec (zig-out/rpm/) — container build untested" },
        .{ .kind = "flake", .name = "flake", .desc = "Sanity-check flake.nix (nix flake check)" },
    }) |t| {
        const dist = distRun(b, dist_exe, t.kind, version, enable_container);
        const named = b.step(t.name, t.desc);
        named.dependOn(&dist.step);
        packages_step.dependOn(&dist.step);
    }

    // Portable (full + slim) both need a ReleaseFast binary on disk
    // BEFORE the bundling pass runs. Wire each as: sub-build → bundle.
    // has_side_effects suppresses cache for the sub-build because it
    // writes into the same zig-out/bin/ the outer step post-processes.
    inline for (.{
        .{ .kind = "portable_full", .name = "portable", .desc = "Portable bundle with libs (zig-out/bin/)" },
        .{ .kind = "portable_slim", .name = "portable-slim", .desc = "Portable bundle WITHOUT libs (zig-out/portable-slim/)" },
    }) |t| {
        const sub_build = b.addSystemCommand(&.{"zig"});
        sub_build.addArgs(&.{ "build", "install", "-Doptimize=ReleaseFast", "-Dgui=true" });
        sub_build.has_side_effects = true;

        const dist = distRun(b, dist_exe, t.kind, version, enable_container);
        dist.step.dependOn(&sub_build.step);

        const named = b.step(t.name, t.desc);
        named.dependOn(&dist.step);
        packages_step.dependOn(&dist.step);
    }

    // ----- prefetch nwjs SDKs -----
    //
    // Populates `zig-out/bin/data/cache/convert/sdks/nwjs-<v>/` with
    // tarballs from dl.nwjs.io. The runtime sdk_cache walks the same
    // path, so any cached version is consumed without a network round
    // trip when Convert runs. Intended use: `zig build prefetch-nwjs
    // -Dnwjs-versions="0.29.4,0.44.6,0.83.0"` before `zig build
    // portable`, so the resulting portable bundle ships with the SDKs
    // pre-extracted.
    //
    // No default version list — each tarball is ~200 MiB extracted,
    // shipping all 50 entries in chromeToNwjs would be 7+ GiB and
    // surprise users. Force them to opt in by spelling out the set
    // they care about.
    const nwjs_versions_csv = b.option(
        []const u8,
        "nwjs-versions",
        "Comma-separated list of nwjs versions (e.g. \"0.29.4,0.44.6,0.83.0\") for prefetch-nwjs.",
    ) orelse "";
    const prefetch_step = b.step("prefetch-nwjs", "Download nwjs SDKs into the portable cache (see -Dnwjs-versions=…)");
    const prefetch_run = b.addRunArtifact(dist_exe);
    prefetch_run.setCwd(b.path("."));
    prefetch_run.has_side_effects = true;
    prefetch_run.addArgs(&.{ "prefetch-nwjs", nwjs_versions_csv });
    prefetch_step.dependOn(&prefetch_run.step);

    // ----- tests: every module's `test {}` blocks -----

    // Pure UI logic modules (no dvui) — fast standalone tests.
    const ui_tokens_mod = mod(b, "ui_tokens", "src/ui/tokens.zig", target, optimize);
    const ui_sortx_mod = mod(b, "ui_sortx", "src/ui/sortx.zig", target, optimize);
    const ui_columns_mod = mod(b, "ui_columns", "src/ui/columns.zig", target, optimize);
    const util_argv_mod = mod(b, "util_argv", "src/util/argv.zig", target, optimize);
    const util_reltime_mod = mod(b, "util_reltime", "src/util/reltime.zig", target, optimize);
    const util_notify_mod = mod(b, "util_notify", "src/util/notify.zig", target, optimize);
    ui_mod.addImport("util_notify", util_notify_mod);
    // RPG Maker MV/MZ asset decryption (M3 mod tooling) — pure, unit-tested.
    const util_rpgm_crypt_mod = mod(b, "util_rpgm_crypt", "src/util/rpgm_crypt.zig", target, optimize);
    ui_mod.addImport("util_rpgm_crypt", util_rpgm_crypt_mod);
    // Ren'Py .rpa archive reader (+ its pickle index reader) — M3 mod tooling.
    const util_rpa_mod = mod(b, "util_rpa", "src/util/rpa.zig", target, optimize);
    ui_mod.addImport("util_rpa", util_rpa_mod);
    const util_ratelimit_mod = mod(b, "util_ratelimit", "src/util/ratelimit.zig", target, optimize);
    // One-shot HTTP helper consults the per-host limiter to space external requests.
    util_http_mod.addImport("util_ratelimit", util_ratelimit_mod);

    // aria2 rewrite — pure units, unit-tested standalone.
    const dl_aria2_args_mod = mod(b, "dl_aria2_args", "src/downloads/aria2_args.zig", target, optimize);
    const dl_rpc_mod = mod(b, "dl_rpc", "src/downloads/rpc.zig", target, optimize);
    const dl_jobs_mod = mod(b, "dl_jobs", "src/downloads/jobs.zig", target, optimize);
    const dl_transport_mod = mod(b, "dl_transport", "src/downloads/transport.zig", target, optimize);
    const dl_http_mod = mod(b, "dl_http", "src/downloads/http.zig", target, optimize);
    dl_http_mod.addImport("util_http", util_http_mod);
    // WebSocket transport — karlseguin/websocket.zig (experimental on 0.16).
    const websocket_dep = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const dl_ws_mod = mod(b, "dl_ws", "src/downloads/ws.zig", target, optimize);
    dl_ws_mod.addImport("websocket", websocket_dep.module("websocket"));
    // The real downloads module pulls ws.zig (via aria2_rpc.zig) → needs the dep too.
    downloads_mod.addImport("websocket", websocket_dep.module("websocket"));

    // Theme-driven dvui component layer (Design B). Imports dvui (gui builds) + tokens.
    const ui_comp_mod = mod(b, "ui_comp", "src/ui/comp.zig", target, optimize);
    ui_comp_mod.addImport("ui_tokens", ui_tokens_mod);
    if (dvui_dep_opt) |dep| ui_comp_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
    // The main UI module uses the runtime theme too (consoleTheme).
    ui_mod.addImport("ui_tokens", ui_tokens_mod);
    ui_mod.addImport("util_argv", util_argv_mod);
    ui_mod.addImport("util_reltime", util_reltime_mod);
    if (dvui_dep_opt != null) ui_mod.addImport("ui_comp", ui_comp_mod);

    // Per-engine palette — pure (library.Engine → tokens.Color); the
    // distinctness property is unit-tested here.
    const ui_engine_palette_mod = mod(b, "ui_engine_palette", "src/ui/engine_palette.zig", target, optimize);
    ui_engine_palette_mod.addImport("library", library_mod);
    ui_engine_palette_mod.addImport("ui_tokens", ui_tokens_mod);
    ui_mod.addImport("ui_engine_palette", ui_engine_palette_mod);

    // Theme persistence module — used by both main (load at startup) and the
    // settings screen (save on change).
    const ui_theme_store_mod = mod(b, "ui_theme_store", "src/ui/theme_store.zig", target, optimize);
    ui_theme_store_mod.addImport("ui_tokens", ui_tokens_mod);
    ui_theme_store_mod.addImport("util_atomic_io", util_atomic_io_mod);
    ui_theme_store_mod.addImport("util_test_env", util_test_env_mod);
    ui_mod.addImport("ui_theme_store", ui_theme_store_mod);
    exe_mod.addImport("ui_theme_store", ui_theme_store_mod);

    // ---- Headless integration-test artifact (Layer 1) ----
    // A second `ui` module graph built against dvui's *testing* backend
    // (pure CPU — no SDL/Vulkan/window) so f69's action + screen layer
    // can be driven headlessly + uniformly on any OS. See
    // docs/test-automation-research.md. Reuses every non-dvui sub-module;
    // only the dvui-importing modules (ui + ui_comp) get a testing twin.
    // Wired only when gui is enabled (default). Run: `zig build test-integration`.
    if (dvui_dep_opt != null) {
        const dvui_testing_dep = b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = @as([]const u8, "testing"),
        });
        const dvui_testing = dvui_testing_dep.module("dvui_testing");
        const dvui_testing_backend = dvui_testing_dep.module("testing");

        const ui_comp_test_mod = mod(b, "ui_comp_testing", "src/ui/comp.zig", target, optimize);
        ui_comp_test_mod.addImport("ui_tokens", ui_tokens_mod);
        ui_comp_test_mod.addImport("dvui", dvui_testing);

        // Same source as ui_mod, wired identically EXCEPT dvui→testing and
        // ui_comp→testing. Source of truth for this list is the
        // ui_mod.addImport(...) sites above; a miss here is a loud compile
        // error, so they can't silently drift.
        const ui_test_mod = mod(b, "ui_testing", "src/ui/ui.zig", target, optimize);
        ui_test_mod.addImport("library", library_mod);
        ui_test_mod.addImport("recipe", recipe_mod);
        ui_test_mod.addImport("resolver", resolver_mod);
        ui_test_mod.addImport("f95", f95_mod_);
        ui_test_mod.addImport("f95_indexer", f95_indexer_mod);
        ui_test_mod.addImport("downloads", downloads_mod);
        ui_test_mod.addImport("sandbox", sandbox_mod);
        ui_test_mod.addImport("convert", convert_mod);
        ui_test_mod.addImport("compat", compat_mod);
        ui_test_mod.addImport("installer", installer_mod);
        ui_test_mod.addImport("importers", importers_mod);
        ui_test_mod.addImport("image", image_mod);
        ui_test_mod.addImport("util_version", util_version_mod);
        ui_test_mod.addImport("util_file_picker", file_picker_mod);
        ui_test_mod.addImport("util_atomic_io", util_atomic_io_mod);
        ui_test_mod.addImport("build_options", build_opts_mod);
        ui_test_mod.addImport("util_notify", util_notify_mod);
        ui_test_mod.addImport("util_rpgm_crypt", util_rpgm_crypt_mod);
        ui_test_mod.addImport("util_rpa", util_rpa_mod);
        ui_test_mod.addImport("ui_tokens", ui_tokens_mod);
        ui_test_mod.addImport("util_argv", util_argv_mod);
        ui_test_mod.addImport("util_reltime", util_reltime_mod);
        ui_test_mod.addImport("ui_engine_palette", ui_engine_palette_mod);
        ui_test_mod.addImport("ui_theme_store", ui_theme_store_mod);
        ui_test_mod.addImport("dvui", dvui_testing);
        ui_test_mod.addImport("ui_comp", ui_comp_test_mod);
        // Mirror the main ui_mod: imports.zig's F95Checker config-path
        // resolution (buildConfigDataPath) needs util_paths.
        ui_test_mod.addImport("util_paths", util_paths_mod);

        const integration_mod = b.createModule(.{
            .root_source_file = b.path("src/testkit/integration.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_mod.addImport("ui", ui_test_mod);
        integration_mod.addImport("dvui", dvui_testing);
        integration_mod.addImport("dvui_testing_backend", dvui_testing_backend);
        integration_mod.addImport("util_test_env", util_test_env_mod);
        integration_mod.addImport("util_setting", util_setting_mod);
        integration_mod.addImport("library", library_mod);
        integration_mod.addImport("downloads", downloads_mod);
        integration_mod.addImport("recipe", recipe_mod);
        integration_mod.addImport("sandbox", sandbox_mod);
        integration_mod.addImport("convert", convert_mod);
        integration_mod.addImport("compat", compat_mod);
        integration_mod.addImport("f95", f95_mod_);
        integration_mod.addImport("f95_indexer", f95_indexer_mod);
        integration_mod.addImport("installer", installer_mod);
        integration_mod.addImport("util_file_picker", file_picker_mod);
        integration_mod.addImport("importers", importers_mod);
        integration_mod.addImport("util_version", util_version_mod);
        integration_mod.addImport("util_argv", util_argv_mod);
        integration_mod.addImport("util_archive", util_archive_mod);
        integration_mod.addImport("resolver", resolver_mod);
        integration_mod.addImport("util_reltime", util_reltime_mod);

        // The GUI suite is a SEPARATE root/exe from the headless one: the
        // headless io-heavy tests are the std.Io Windows park risk, and a
        // park in one exe must never take the GUI coverage with it —
        // test-windows-vm.sh watchdogs each exe independently.
        const integration_gui_mod = b.createModule(.{
            .root_source_file = b.path("src/testkit/integration_gui.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_gui_mod.addImport("ui", ui_test_mod);
        integration_gui_mod.addImport("dvui", dvui_testing);
        integration_gui_mod.addImport("library", library_mod);
        integration_gui_mod.addImport("util_test_env", util_test_env_mod);
        integration_gui_mod.addImport("util_file_picker", file_picker_mod);
        integration_gui_mod.addImport("sandbox", sandbox_mod);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const integration_gui_tests = b.addTest(.{ .name = "gui-test", .root_module = integration_gui_mod });
        const run_integration = b.addRunArtifact(integration_tests);
        const run_integration_gui = b.addRunArtifact(integration_gui_tests);
        const integration_step = b.step("test-integration", "Headless action-layer integration tests (dvui testing backend)");
        integration_step.dependOn(&run_integration.step);
        integration_step.dependOn(&run_integration_gui.step);

        // Same suite, built but NOT run — so it can be cross-compiled and
        // executed natively on a foreign target:
        //
        //   scripts/test-windows-vm.sh   ->  zig-out/test/*.exe  ->  the Win11 VM
        //
        // The Layer-1 harness needs no display (dvui testing backend), so the
        // binary runs fine over SSH in the guest. That is the only way to get
        // automated coverage of the OS-specific behaviour — launcher
        // discovery, path handling, sandbox backend selection — which is
        // exactly where the Windows bug reports come from. `addRunArtifact`
        // can't do this: the host cannot execute a Windows binary.
        const integration_install = b.addInstallArtifact(integration_tests, .{
            .dest_dir = .{ .override = .{ .custom = "test" } },
        });
        const integration_gui_install = b.addInstallArtifact(integration_gui_tests, .{
            .dest_dir = .{ .override = .{ .custom = "test" } },
        });
        const integration_exe_step = b.step(
            "test-integration-exe",
            "Build (don't run) the Layer-1 suite into zig-out/test/ for running on a foreign target",
        );
        integration_exe_step.dependOn(&integration_install.step);
        integration_exe_step.dependOn(&integration_gui_install.step);

        // Unit-test exes for the modules whose Windows arms matter most.
        // Zig only collects tests from a compilation's ROOT module — a
        // `test { _ = @import("sandbox") }` in integration.zig pulls in
        // nothing across the module boundary — so each module ships as its
        // own exe and test-windows-vm.sh runs every zig-out/test/*.exe.
        // util_atomic_io is NOT on this roster. Tried 2026-08-12: its very
        // first test (write → readFileAlloc round-trip) parks forever as a
        // STANDALONE exe on the Win11 VM — while the exact same operation
        // (writeFileAtomic → util_setting readFileAlloc, ui_scale test)
        // passes inside the integration binary. The park is therefore
        // binary-context-dependent, not primitive-dependent; atomic-io-test
        // .exe is the minimal repro for the upstream std.Io report.
        const win_unit_tests = [_]struct { name: []const u8, m: *std.Build.Module }{
            .{ .name = "sandbox-test", .m = sandbox_mod },
            .{ .name = "util-paths-test", .m = util_paths_mod },
        };
        for (win_unit_tests) |wt| {
            const unit = b.addTest(.{ .name = wt.name, .root_module = wt.m });
            const unit_install = b.addInstallArtifact(unit, .{
                .dest_dir = .{ .override = .{ .custom = "test" } },
            });
            integration_exe_step.dependOn(&unit_install.step);
        }
    }

    const test_targets = [_]*std.Build.Module{
        exe_mod,            ui_tokens_mod,   ui_sortx_mod,        ui_columns_mod,     util_argv_mod,
        util_reltime_mod,   ui_comp_mod,     ui_theme_store_mod,  util_ratelimit_mod, ui_engine_palette_mod,
        dl_aria2_args_mod,  dl_rpc_mod,      dl_jobs_mod,         dl_ws_mod,          dl_transport_mod,
        dl_http_mod,        util_notify_mod, util_rpgm_crypt_mod, util_rpa_mod,       library_mod,
        recipe_mod,         resolver_mod,    f95_mod_,            f95_indexer_mod,    downloads_mod,
        installer_mod,      convert_mod,     sandbox_mod,         server_mod,         ui_mod,
        config_mod,         image_mod,       importers_mod,       compat_mod,         util_paths_mod,
        util_kahn_mod,      util_db_mod,     util_crash_mod,      util_version_mod,   util_renpy_mod,
        util_atomic_io_mod, util_domain_mod, util_http_mod,       util_proc_mod,      util_setting_mod,
        util_test_env_mod,  file_picker_mod, util_archive_mod,
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_targets) |m| {
        const tests = b.addTest(.{ .root_module = m });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

fn mod(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addModule(name, .{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

/// Install a compat resource directory into the `<install>/bin/data/
/// compat-resources/<id>/` tree. Reads the absolute source path from
/// `env_var`; no-ops cleanly when the env var is unset (non-Nix
/// build, or the dev shell wasn't sourced).
fn installCompatResource(b: *std.Build, id: []const u8, env_var: []const u8, data_prefix: []const u8) void {
    const src = b.graph.environ_map.get(env_var) orelse return;
    const subdir = std.fmt.allocPrint(b.allocator, "{s}/compat-resources/{s}", .{ data_prefix, id }) catch return;
    const step = b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = src },
        .install_dir = .{ .custom = subdir },
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&step.step);
}

/// Parse `version = "X.Y.Z"` out of build.zig.zon at build-script start.
/// One source of truth — bump version in the .zon and every package
/// manifest tracks it.
fn readVersion(b: *std.Build) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var buf: [16 * 1024]u8 = undefined;
    const text = try cwd.readFile(b.graph.io, "build.zig.zon", &buf);
    const needle = ".version = \"";
    const start = std.mem.indexOf(u8, text, needle) orelse return error.NoVersionInZon;
    const rest = text[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoVersionInZon;
    return try b.allocator.dupe(u8, rest[0..end]);
}

/// One `tools/dist.zig <kind> <version> <container>` invocation, run from
/// the repo root. Side-effecting (writes zig-out/...), so never cached.
fn distRun(b: *std.Build, dist_exe: *std.Build.Step.Compile, kind: []const u8, version: []const u8, enable_container: bool) *std.Build.Step.Run {
    const run = b.addRunArtifact(dist_exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addArgs(&.{ kind, version, if (enable_container) "true" else "false" });
    return run;
}

// XDG desktop entry — installed to share/applications/f69.desktop.
const DESKTOP_ENTRY =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=f69
    \\GenericName=Game Library Manager
    \\Comment=F95Zone-focused game and mod library manager
    \\Exec=f69
    \\Icon=f69
    \\Terminal=false
    \\Categories=Game;
    \\Keywords=games;library;f95zone;mods;visual novel;
    \\StartupNotify=true
    \\
;

// App icon (Design B — electric teal "f69" on graphite). Scalable SVG,
// installed to share/icons/hicolor/scalable/apps/f69.svg.
const ICON_SVG =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
    \\  <rect width="256" height="256" rx="48" fill="#16212a"/>
    \\  <rect x="20" y="20" width="216" height="216" rx="36" fill="none" stroke="#1fa39a" stroke-width="6"/>
    \\  <text x="128" y="168" font-family="sans-serif" font-size="118" font-weight="700" fill="#1fa39a" text-anchor="middle">f69</text>
    \\</svg>
    \\
;

/// `@cImport` is gone in Zig 0.17: translate a one-line wrapper header to a
/// module instead. Callers add include paths / system libs on the result.
fn cTranslate(
    b: *std.Build,
    header_name: []const u8,
    header_text: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) *std.Build.Step.TranslateC {
    const wf = b.addWriteFiles();
    return b.addTranslateC(.{
        .root_source_file = wf.add(header_name, header_text),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}

/// translate-c only needs a library's headers, not the library itself —
/// `TranslateC.linkSystemLibrary` makes it try to link (and fail on
/// windows/static). Take the `-I` dirs from pkg-config instead.
fn addPkgConfigIncludes(b: *std.Build, tc: *std.Build.Step.TranslateC, pkg: []const u8) void {
    const out = switch (b.runFallible(&.{ "pkg-config", "--cflags-only-I", pkg }, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| stdout,
        else => return, // no pkg-config entry: headers must be on the default include path
    };
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) tc.addSystemIncludePath(.{ .cwd_relative = tok[2..] });
    }
}
