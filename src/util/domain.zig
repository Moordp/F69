// Shared-kernel value objects — types so ubiquitous they belong above
// any single bounded context. Centralising them here removes the
// "redeclare-with-subtly-different-variants" failure mode that bit us
// before (compat's `Engine` was missing `unknown`; library knew about
// 15 engines while recipe/convert knew only 5; etc).
//
// Each context can still alias what it needs:
//
//     // src/recipe/domain.zig
//     pub const Engine = @import("util_domain").Engine;
//
// or expose a narrower subset via a re-export with renames if a strong
// case appears later. For now every consumer takes the full enum.

const std = @import("std");

/// Visual-novel / RPG engines we recognise on F95. Driven by:
///   - F95 thread title bracket tokens ("[Ren'Py]", "[Unity]", …)
///   - Engine-fingerprint heuristics in `convert/detect.zig`
///   - Compat / convert handler dispatch
///
/// `unknown` is the sentinel for "couldn't detect" / "not yet
/// classified" rows. Recipes can declare `engine = .unknown` to opt
/// out of auto-detection.
pub const Engine = enum {
    renpy,
    rpgm_mv,
    rpgm_mz,
    rpgm_vx,
    unity,
    unreal,
    html,
    flash,
    java,
    wolf_rpg,
    qsp,
    tyranobuilder,
    twine,
    adrift,
    rags,
    tads,
    webgl,
    other,
    unknown,

    /// Match the kebab / snake / underscore variants users type into
    /// recipe `.engine` fields. Comptime perfect-hash map — one O(1)
    /// probe per call instead of the previous N `mem.eql` cascade.
    pub fn fromStr(s: []const u8) Engine {
        return FROM_STR_MAP.get(s) orelse .unknown;
    }

    const FROM_STR_MAP = std.StaticStringMap(Engine).initComptime(.{
        .{ "renpy", .renpy },
        .{ "rpgm-mv", .rpgm_mv },
        .{ "rpgm_mv", .rpgm_mv },
        .{ "rpgm-mz", .rpgm_mz },
        .{ "rpgm_mz", .rpgm_mz },
        .{ "rpgm-vx", .rpgm_vx },
        .{ "rpgm_vx", .rpgm_vx },
        .{ "unity", .unity },
        .{ "unreal", .unreal },
        .{ "html", .html },
        .{ "flash", .flash },
        .{ "java", .java },
        .{ "wolf_rpg", .wolf_rpg },
        .{ "wolf-rpg", .wolf_rpg },
        .{ "qsp", .qsp },
        .{ "tyranobuilder", .tyranobuilder },
        .{ "twine", .twine },
        .{ "adrift", .adrift },
        .{ "rags", .rags },
        .{ "tads", .tads },
        .{ "webgl", .webgl },
        .{ "other", .other },
    });

    /// Best-effort match for the kind of bracket tokens F95 thread
    /// titles use ("Ren'Py", "RPGM MV", "Unity"). Strips apostrophes
    /// and whitespace so "Ren'Py" / "RenPy" / "Ren Py" all match.
    /// Lookup itself is a comptime perfect-hash map keyed by the
    /// normalised (alphanumeric-only, lowercased) form.
    pub fn fromBracket(token: []const u8) Engine {
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (token) |c| {
            if (std.ascii.isAlphanumeric(c) and n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        return FROM_BRACKET_MAP.get(buf[0..n]) orelse .unknown;
    }

    const FROM_BRACKET_MAP = std.StaticStringMap(Engine).initComptime(.{
        .{ "renpy", .renpy },
        .{ "rpgmmv", .rpgm_mv },
        .{ "rpgmakermv", .rpgm_mv },
        .{ "rpgmmz", .rpgm_mz },
        .{ "rpgmakermz", .rpgm_mz },
        .{ "rpgmvx", .rpgm_vx },
        .{ "rpgmakervx", .rpgm_vx },
        .{ "rpgmakervxace", .rpgm_vx },
        .{ "rpgm", .rpgm_mv },
        .{ "rpgmaker", .rpgm_mv },
        .{ "unity", .unity },
        .{ "unrealengine", .unreal },
        .{ "unreal", .unreal },
        .{ "ue4", .unreal },
        .{ "ue5", .unreal },
        .{ "html", .html },
        .{ "html5", .html },
        .{ "flash", .flash },
        .{ "java", .java },
        .{ "wolfrpg", .wolf_rpg },
        .{ "wolfrpgeditor", .wolf_rpg },
        .{ "qsp", .qsp },
        .{ "tyranobuilder", .tyranobuilder },
        .{ "tyrano", .tyranobuilder },
        .{ "twine", .twine },
        .{ "adrift", .adrift },
        .{ "rags", .rags },
        .{ "tads", .tads },
        .{ "webgl", .webgl },
        .{ "others", .other },
        .{ "other", .other },
    });
};

/// Linux distro family. Drives per-distro install-hint pickers in the
/// compat module + lib-bundling paths in `convert/syslibs.zig`.
pub const Distro = enum {
    nixos,
    arch,
    debian,
    ubuntu,
    fedora,
    other,

    /// Read `ID=...` from `/etc/os-release`. Falls back to `.other` on
    /// any IO error.
    pub fn detect(io: std.Io, alloc: std.mem.Allocator) Distro {
        const content = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", alloc, .limited(64 * 1024)) catch return .other;
        defer alloc.free(content);
        return parseOsReleaseId(content);
    }

    /// Pure — split out for unit testing without touching /etc/.
    pub fn parseOsReleaseId(content: []const u8) Distro {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "ID=")) continue;
            const v = std.mem.trim(u8, line[3..], "\"' \t");
            if (std.mem.eql(u8, v, "nixos")) return .nixos;
            if (std.mem.eql(u8, v, "arch")) return .arch;
            if (std.mem.eql(u8, v, "debian")) return .debian;
            if (std.mem.eql(u8, v, "ubuntu")) return .ubuntu;
            if (std.mem.eql(u8, v, "fedora")) return .fedora;
            return .other;
        }
        return .other;
    }
};

/// Operating system. Used by compat recipes' `platforms` array and
/// by the launcher to pick `launch.linux` vs `launch.windows`.
pub const Os = enum { linux, windows, macos };

const testing = std.testing;

test "Engine.fromBracket: common F95 spellings" {
    try testing.expectEqual(Engine.renpy, Engine.fromBracket("Ren'Py"));
    try testing.expectEqual(Engine.renpy, Engine.fromBracket("RenPy"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromBracket("RPGM MV"));
    try testing.expectEqual(Engine.rpgm_mz, Engine.fromBracket("RPGMaker MZ"));
    try testing.expectEqual(Engine.unity, Engine.fromBracket("Unity"));
    try testing.expectEqual(Engine.unreal, Engine.fromBracket("UE4"));
    try testing.expectEqual(Engine.unknown, Engine.fromBracket("Custom"));
}

test "Engine.fromStr: kebab + snake variants" {
    try testing.expectEqual(Engine.renpy, Engine.fromStr("renpy"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromStr("rpgm-mv"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromStr("rpgm_mv"));
    try testing.expectEqual(Engine.unknown, Engine.fromStr("garbage"));
}
