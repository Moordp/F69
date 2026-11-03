// Public face of the convert context.

const dom = @import("domain.zig");
pub const errors = @import("errors.zig");

pub const Engine = dom.Engine;
pub const ConvertSpec = dom.ConvertSpec;
pub const Progress = dom.Progress;
pub const Distro = dom.Distro;
pub const Service = @import("service.zig").Service;
pub const detectEngine = @import("detect.zig").detectEngine;

// Surface the Ren'Py module for callers that want detection-only
// (e.g. UI "what version is this?" without a full convert).
pub const renpy = @import("renpy.zig");
pub const rpgm = @import("rpgm.zig");

// Convert presets — data-driven dispatch from engine to ConvertSpec.
// Replaces the recipe-side `convert_linux` block; built-ins cover the
// common cases, users can add `<data_root>/convert-presets/*.preset.zon`
// to extend.
const preset_mod = @import("preset.zig");
pub const Preset = preset_mod.Preset;
pub const MatchedPreset = preset_mod.Matched;
pub const MergedPresetSet = preset_mod.MergedSet;
pub const loadMergedPresets = preset_mod.loadMerged;
pub const pickPresetForEngine = preset_mod.pickForEngine;
pub const saveUserPreset = preset_mod.save;
pub const PRESET_FILE_SUFFIX = preset_mod.PRESET_FILE_SUFFIX;

// Test discovery — Zig 0.16's `zig build test` only walks tests in
// files reachable through *referenced declarations*. Without these
// the per-file `test {}` blocks silently no-op.
test {
    _ = @import("service.zig");
    _ = @import("detect.zig");
    _ = @import("renpy.zig");
    _ = @import("rpgm.zig");
    _ = @import("sdk_cache.zig");
    _ = @import("syslibs.zig");
    _ = @import("preset.zig");
}
