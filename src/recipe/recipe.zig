// Public face of the recipe context. Per architect review: minimal
// re-exports — only the top-level Repo struct + the few domain types
// callers commonly bind. Anything else: callers reach into domain.zig.

const dom = @import("domain.zig");
pub const errors = @import("errors.zig");

pub const Recipe = dom.Recipe;
pub const GameRecipe = dom.GameRecipe;
pub const ModRecipe = dom.ModRecipe;
pub const Source = dom.Source;
pub const MirrorHost = dom.MirrorHost;
pub const InstallStep = dom.InstallStep;
pub const ModConstraint = dom.ModConstraint;
pub const Provided = dom.Provided;
pub const ConvertSpec = dom.ConvertSpec;
pub const SandboxBlock = dom.SandboxBlock;
pub const SavesPaths = dom.SavesPaths;
pub const UpdateStrategy = dom.UpdateStrategy;
pub const Engine = dom.Engine;

pub const Repo = @import("repository.zig").Repo;
pub const validate = @import("validator.zig").validate;
pub const derive = @import("derive.zig");
pub const gameRecipeAppliesTo = dom.gameRecipeAppliesTo;
pub const modRecipeAppliesTo = dom.modRecipeAppliesTo;

const preset_mod = @import("preset.zig");
pub const Preset = preset_mod.Preset;
pub const MatchSpec = preset_mod.MatchSpec;
pub const MatchedPreset = preset_mod.MatchedPreset;
pub const ParsedPreset = preset_mod.ParsedPreset;
pub const BuiltinSet = preset_mod.BuiltinSet;
pub const MergedPresetSet = preset_mod.MergedSet;
pub const parsePresetFromBytes = preset_mod.parseFromBytes;
pub const loadBuiltinPresets = preset_mod.loadBuiltins;
pub const loadMergedPresets = preset_mod.loadMerged;
pub const saveUserPreset = preset_mod.saveUserPreset;
pub const detectPresetBest = preset_mod.detectBest;
pub const detectPresetAll = preset_mod.detectAll;
pub const scorePreset = preset_mod.scorePreset;
pub const globMatch = preset_mod.globMatch;
pub const PRESET_FILE_SUFFIX = preset_mod.PRESET_FILE_SUFFIX;

const zon = @import("zon_loader.zig");
pub const ParsedGame = zon.ParsedGame;
pub const ParsedMod = zon.ParsedMod;
pub const loadGame = zon.loadGame;
pub const loadMod = zon.loadMod;
pub const parseGameFromBytes = zon.parseGameFromBytes;
pub const parseModFromBytes = zon.parseModFromBytes;
pub const saveGame = zon.saveGame;
pub const saveMod = zon.saveMod;

// Pull nested tests into this module's test binary. Without these
// references the compiler only analyzes the re-exported symbols above,
// so nested `test` blocks would silently no-op (same idiom as
// downloads.zig / importers.zig roots).
test {
    _ = @import("derive.zig");
    _ = @import("domain.zig");
    _ = @import("errors.zig");
    _ = @import("preset.zig");
    _ = @import("repository.zig");
    _ = @import("validator.zig");
    _ = @import("zon_loader.zig");
}

/// Path-safety checks, used by the hostile test suite to assert that recipe
/// paths cannot escape the install directory.
pub const validator = @import("validator.zig");
