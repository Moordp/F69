// Re-export wall for the per-screen modules. After R8 the actual
// screen implementations live under `src/ui/screens/`, with shared
// widgets in `src/ui/components.zig`. This file exists so every
// existing `screens.X` call site (mostly in ui.zig + main.zig)
// keeps resolving without churn.
//
// Layout map:
//   library.zig        — libraryScreen, sidebar/cards/sort
//   detail.zig         — detailScreen, carousel/ribbon/cover/tabs
//   mods.zig           — modsScreen + modfile rows
//   recipe_editor.zig  — recipeEditorScreen + wizard panels
//   settings.zig       — settingsScreen + tabs
//   import.zig         — importUrlsScreen, importFolderScreen
//   downloads.zig      — downloadsScreen + job rows
//   diagnostics.zig    — diagnosticsScreen
//   components.zig     — iconButton/iconOnly/tabButton/settingsHelpText,
//                        humanBytes/humanRate, formatUtcDateTime,
//                        renderSyncRecapPopup/renderToasts,
//                        engine + dev-status colour/label tables,
//                        gameByThreadId

const library_screen = @import("screens/library.zig");
const detail_screen = @import("screens/detail.zig");
const mods_screen = @import("screens/mods.zig");
const recipe_editor_screen = @import("screens/recipe_editor.zig");
const settings_screen = @import("screens/settings.zig");
const import_screen = @import("screens/import.zig");
const downloads_screen = @import("screens/downloads.zig");
const diagnostics_screen = @import("screens/diagnostics.zig");
const universal_mods_screen = @import("screens/universal_mods.zig");
const components = @import("components.zig");

// ---- Per-screen entry points (called by ui.zig) ----
pub const libraryScreen = library_screen.libraryScreen;
pub const detailScreen = detail_screen.detailScreen;
pub const modsScreen = mods_screen.modsScreen;
pub const recipeEditorScreen = recipe_editor_screen.recipeEditorScreen;
pub const settingsScreen = settings_screen.settingsScreen;
pub const importUrlsScreen = import_screen.importUrlsScreen;
pub const importFolderScreen = import_screen.importFolderScreen;
pub const importF95CheckerReviewScreen = import_screen.importF95CheckerReviewScreen;
pub const downloadsScreen = downloads_screen.downloadsScreen;
pub const renderDownloadsBody = downloads_screen.renderDownloadsBody;
pub const renderActivityDrawer = downloads_screen.renderActivityDrawer;
pub const diagnosticsScreen = diagnostics_screen.diagnosticsScreen;
pub const universalModsScreen = universal_mods_screen.universalModsScreen;

// ---- Cross-screen overlay widgets (called by ui.zig) ----
pub const renderSyncRecapPopup = components.renderSyncRecapPopup;
pub const renderLoginPopup = components.renderLoginPopup;
pub const renderLaunchDiagPopup = components.renderLaunchDiagPopup;
pub const renderToasts = components.renderToasts;
pub const renderIconRail = components.renderIconRail;
pub const renderStatusBar = components.renderStatusBar;
