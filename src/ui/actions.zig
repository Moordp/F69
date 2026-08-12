// Re-export wall for the per-domain action modules. After R9 the
// actual action implementations live under `src/ui/actions/`. This
// file exists so every existing `actions.X` call site (mostly in
// ui.zig + screens/* + main.zig) keeps resolving without churn.
//
// Layout map:
//   sync.zig         — syncGame, syncWorker, drainSync, sync recap,
//                      sync-all queue, advanceSyncQueue, image queue
//                      (phase-2 screenshots), slide/thumb/cover caches
//                      + prewarm. Owns SyncJob, SyncRecapEntry, ImageJob.
//   downloads.zig    — doDownloadGame + enqueueOneSource, RPDL worker
//                      (Tier 2), Donor DDL worker (Tier 1) + telemetry +
//                      retry, drainCompletedDownloads bridge. Owns
//                      RpdlDownloadJob, DonorDownloadJob.
//   installer.zig    — modJobRunner + runInstall/Uninstall, test-install
//                      preview, doInstallMod + conflicts + clash modal,
//                      resolver preflight, post-install pipeline,
//                      manual-install pipeline, install rename/delete.
//                      Owns TestInstallJob, PostInstallJob,
//                      ManualInstallJob[List], ModFileConflictAll,
//                      ClashModalState. Hosts postInstalledSet helper.
//   launch.zig       — doLaunchGame, doStopGame, isGameRunning,
//                      drainRunningGames, doConvertGame, compat env,
//                      shouldSandbox / shouldAutoUpdate /
//                      hasAutoFetchableSource / recipeReadyForAutoUpdate,
//                      lookupVersionFromArchiveSha,
//                      openManualInstallForUpdate, doBackupSaves,
//                      doOpenGameFolder, doOpenSaves, expandSavesPath.
//   bookmarks.zig    — doPullBookmarks, BookmarksJob worker,
//                      drainBookmarks, stripThreadPrefix +
//                      isLikelyNonGameTitle helpers (with tests).
//                      Owns BookmarksJob, BookmarksJobPhase.
//   auth.zig         — doLogin / doLogout / doRpdlLogin / doRpdlLogout.
//   mods.zig         — modfileForGame, refreshModfileCache,
//                      dropModfileCache, modsPageCache + lookups,
//                      isModInstalled, doUninstallMod, preset cache
//                      wiring, recipe wizard, mod-recipe delete,
//                      doScanModfiles, doDeleteModfile,
//                      simulateCurrentPlan, archive/install top-dirs,
//                      modTrackerLayout, openSettingsTab,
//                      resolveModsPageInstall / resolveConvertSpec /
//                      resolveGameRoot. Owns ModfileCache,
//                      ModsTabCounts, ModsPageCache, ModTrackerLayout.
//   tags.zig         — startRefreshTags, RefreshTagsJob worker,
//                      drainRefreshTags. Owns RefreshTagsJob.
//   imports.zig      — F95Checker / xLibrary importers, update-check
//                      job. Owns UpdateCheckJob.
//   common.zig       — bridge helpers (cancelAllWorkers, workersBusy,
//                      deleteGameAndReturn, installedSet/installDotState/
//                      retryDownload glue, attemptsMap, settings
//                      persistence, browser launch, friendlyError,
//                      persistTextFile, exeExistsUnder, freePostInstalled).

const sync = @import("actions/sync.zig");
const dl = @import("actions/downloads.zig");
const installer = @import("actions/installer.zig");
const launch = @import("actions/launch.zig");
const bookmarks = @import("actions/bookmarks.zig");
const auth = @import("actions/auth.zig");
const mods = @import("actions/mods.zig");
const tags = @import("actions/tags.zig");
const imports = @import("actions/imports.zig");
const common = @import("actions/common.zig");

// ---- Public type aliases (kept identical to pre-R9 names) ----
pub const ModsTabCounts = mods.ModsTabCounts;
pub const InstallDotState = common.InstallDotState;
pub const DownloadedEntry = installer.DownloadedEntry;
pub const RunnerCtx = installer.RunnerCtx;

// ---- Sync recap + sync engine ----
pub const syncRecapEntries = sync.syncRecapEntries;
pub const freeSyncRecap = sync.freeSyncRecap;
pub const syncGame = sync.syncGame;
pub const slideBytes = sync.slideBytes;
pub const freeSlideCache = sync.freeSlideCache;
pub const thumbBytes = sync.thumbBytes;
pub const freeThumbCache = sync.freeThumbCache;
pub const drainSync = sync.drainSync;
pub const drainFastCheck = sync.drainFastCheck;
pub const setImageCpuLimit = sync.setImageCpuLimit;
pub const freeLibFilterCache = sync.freeLibFilterCache;
pub const freeSnapshotCache = sync.freeSnapshotCache;
pub const drainSlideLoads = sync.drainSlideLoads;
pub const drainCoverLoads = sync.drainCoverLoads;
pub const startSyncAll = sync.startSyncAll;
pub const startSyncAllUnsynced = sync.startSyncAllUnsynced;
pub const cancelSync = sync.cancelSync;
pub const cancelImageQueue = sync.cancelImageQueue;
pub const drainImageQueue = sync.drainImageQueue;
pub const coverBytes = sync.coverBytes;
// DIAG: cover-cache miss counter accessors (alias to a mutable global
// can't be a `const`, so wrap). Remove with the scroll-perf probe.
pub fn dbgCoverMisses() usize {
    return sync.dbg_cover_misses;
}
pub fn dbgResetCoverMisses() void {
    sync.dbg_cover_misses = 0;
}
pub const coverFullBytes = sync.coverFullBytes;
pub const freeCoverCache = sync.freeCoverCache;
pub const freeCoverLoads = sync.freeCoverLoads;
pub const spawnCoverPrewarm = sync.spawnCoverPrewarm;
pub const spawnThumbPrewarm = sync.spawnThumbPrewarm;

// ---- Update check + importers ----
pub const startUpdateCheck = imports.startUpdateCheck;
pub const drainUpdateCheck = imports.drainUpdateCheck;
pub const doImportFromF95Checker = imports.doImportFromF95Checker;
pub const doImportFromF95CheckerDirect = imports.doImportFromF95CheckerDirect;
pub const doStartF95CheckerReview = imports.doStartF95CheckerReview;
pub const doApplyF95CheckerReview = imports.doApplyF95CheckerReview;
pub const doCancelF95CheckerReview = imports.doCancelF95CheckerReview;
pub const freeF95Review = imports.freeF95Review;
pub const f95ReviewBundle = imports.f95ReviewBundle;
pub const doImportFromXLibrary = imports.doImportFromXLibrary;
pub const doExportToF95Checker = imports.doExportToF95Checker;
pub const doFolderScan = imports.doFolderScan;
pub const findLinuxLauncher = launch.findLinuxLauncher;
pub const findWindowsLauncher = launch.findWindowsLauncher;
pub const findLauncher = launch.findLauncher;
pub const folderScanBundle = imports.folderScanBundle;
pub const folderScanRowStates = imports.folderScanRowStates;
pub const folderScanLibSnapshot = imports.folderScanLibSnapshot;
pub const folderScanInProgress = imports.folderScanInProgress;
pub const tickFolderScan = imports.tickFolderScan;
pub const commitFolderImport = imports.commitFolderImport;
pub const resolveFolderEntry = imports.resolveFolderEntry;
pub const parseF95ThreadInput = imports.parseF95ThreadInput;
pub const freeFolderScan = imports.freeFolderScan;
pub const drainImport = imports.drainImport;
pub const drainFolderImport = imports.drainFolderImport;
pub const cancelFolderImport = imports.cancelFolderImport;
pub const folderImportActive = imports.folderImportActive;

// ---- Common glue ----
pub const cancelAllWorkers = common.cancelAllWorkers;
pub const workersBusy = common.workersBusy;
pub const openInBrowser = common.openInBrowser;
pub const openExternalUrl = common.openExternalUrl;
pub const addGuideForGame = common.addGuideForGame;
pub const openGuide = common.openGuide;
pub const removeGuide = common.removeGuide;
pub const listGuides = common.listGuides;
pub const freeGuides = common.freeGuides;
pub const GuideEntry = common.GuideEntry;
pub const saveBrowserPath = common.saveBrowserPath;
pub const persistUiScaleIfDirty = common.persistUiScaleIfDirty;
pub const persistAutoCheckIfDirty = common.persistAutoCheckIfDirty;
pub const applyLibPrefs = common.applyLibPrefs;
pub const seedLibPrefsMirror = common.seedLibPrefsMirror;
pub const persistLibPrefsIfDirty = common.persistLibPrefsIfDirty;
pub const persistAutoConvertIfDirty = common.persistAutoConvertIfDirty;
pub const persistAutoApplyCompatIfDirty = common.persistAutoApplyCompatIfDirty;
pub const persistSandboxDefaultIfDirty = common.persistSandboxDefaultIfDirty;
pub const persistAutoUpdateDefaultIfDirty = common.persistAutoUpdateDefaultIfDirty;
pub const persistDesktopNotificationsIfDirty = common.persistDesktopNotificationsIfDirty;
pub const persistRefreshBackendIfDirty = common.persistRefreshBackendIfDirty;
pub const persistUpdateCheckSourceIfDirty = common.persistUpdateCheckSourceIfDirty;
pub const persistMaxParallelSyncIfDirty = common.persistMaxParallelSyncIfDirty;
pub const persistMaxParallelImageIfDirty = common.persistMaxParallelImageIfDirty;
pub const persistMinSessionSecondsIfDirty = common.persistMinSessionSecondsIfDirty;
pub const saveAria2Port = common.saveAria2Port;
pub const saveAria2SeedRatio = common.saveAria2SeedRatio;
pub const saveAria2SeedTime = common.saveAria2SeedTime;
pub const decryptRpgmAssets = @import("actions/rpgm_tools.zig").decryptRpgmAssets;
pub const enableRenpyConsole = @import("actions/renpy_tools.zig").enableRenpyConsole;
pub const extractRpaArchives = @import("actions/renpy_tools.zig").extractRpaArchives;
const universal_mods_actions = @import("actions/universal_mods.zig");
pub const doAddUniversalMod = universal_mods_actions.doAddUniversalMod;
pub const doDeleteUniversalMod = universal_mods_actions.doDeleteUniversalMod;
pub const applyUniversalMod = universal_mods_actions.applyUniversalMod;
pub const universalModEngines = universal_mods_actions.ENGINES;
pub const universalModEngineForIndex = universal_mods_actions.engineForIndex;
pub const maybeAutoUpdateCheck = common.maybeAutoUpdateCheck;
pub const deleteGameAndReturn = common.deleteGameAndReturn;
pub const refreshInstalledSet = common.refreshInstalledSet;
pub const retryDownload = common.retryDownload;
pub const installDotState = common.installDotState;
pub const freeInstalledSet = common.freeInstalledSet;
pub const freePostInstalled = common.freePostInstalled;

// ---- Downloads ----
pub const startRpdlDownload = dl.startRpdlDownload;
pub const drainRpdlDownload = dl.drainRpdlDownload;
pub const freeDonorTables = dl.freeDonorTables;
pub const drainDonorTelemetry = dl.drainDonorTelemetry;
pub const isDonorJob = dl.isDonorJob;
pub const startDonorDownload = dl.startDonorDownload;
pub const drainDonorDownload = dl.drainDonorDownload;
pub const hasActiveDownloadForGame = dl.hasActiveDownloadForGame;
pub const findLeechingJobForGame = dl.findLeechingJobForGame;
pub const doDownloadGame = dl.doDownloadGame;
pub const drainCompletedDownloads = dl.drainCompletedDownloads;

// ---- Refresh tags ----
pub const startRefreshTags = tags.startRefreshTags;
pub const drainRefreshTags = tags.drainRefreshTags;
pub const freeTagsMaster = tags.freeTagsMaster;

// ---- Bookmarks ----
pub const cancelBookmarks = bookmarks.cancelBookmarks;
pub const startPullBookmarks = bookmarks.startPullBookmarks;
pub const drainBookmarks = bookmarks.drainBookmarks;

// ---- Auth ----
pub const doLogin = auth.doLogin;
pub const doSubmitTotp = auth.doSubmitTotp;
pub const cancelTwoStep = auth.cancelTwoStep;
pub const doLoginWithCookie = auth.doLoginWithCookie;
pub const doOpenF95Login = auth.doOpenF95Login;
pub const doLogout = auth.doLogout;
pub const checkDonorStatus = auth.checkDonorStatus;
pub const drainDonorProbe = auth.drainDonorProbe;
pub const doRpdlLogin = auth.doRpdlLogin;
pub const doRpdlLogout = auth.doRpdlLogout;

// ---- Launch / convert / running games / saves ----
pub const doOpenLogsFolder = launch.doOpenLogsFolder;
pub const doLaunchGame = launch.doLaunchGame;
pub const scanCompatForInstall = launch.scanCompatForInstall;
pub const freeCompatIssues = launch.freeCompatIssues;
pub const applyCompatFix = launch.applyCompatFix;
pub const shouldAutoUpdate = launch.shouldAutoUpdate;
pub const hasAutoFetchableSource = launch.hasAutoFetchableSource;
pub const lookupVersionFromArchiveSha = launch.lookupVersionFromArchiveSha;
pub const openManualInstallForUpdate = launch.openManualInstallForUpdate;
pub const doConvertGame = launch.doConvertGame;
pub const isGameRunning = launch.isGameRunning;
pub const doStopGame = launch.doStopGame;
pub const drainRunningGames = launch.drainRunningGames;
pub const doBackupSaves = launch.doBackupSaves;
pub const doImportSaves = launch.doImportSaves;
pub const doOpenGameFolder = launch.doOpenGameFolder;
pub const doOpenSaves = launch.doOpenSaves;
pub const doOpenInstallFolder = launch.doOpenInstallFolder;
pub const clearLaunchDiag = launch.clearLaunchDiag;
pub const drainLaunchWatcher = launch.drainLaunchWatcher;
pub const applyCompatFixForGame = launch.applyCompatFixForGame;

// ---- Installer (mod-job runner + post-install + manual install) ----
pub const doUninstallMod = installer.doUninstallMod;
pub const modJobRunner = installer.modJobRunner;
pub const recoverModJobsFromDisk = installer.recoverModJobsFromDisk;
pub const drainModJobs = installer.drainModJobs;
pub const doInstallMod = installer.doInstallMod;
pub const clashModalState = installer.clashModalState;
pub const closeClashModal = installer.closeClashModal;
pub const freeClashModalState = installer.freeClashModalState;
pub const clashModalAcceptAll = installer.clashModalAcceptAll;
pub const doTestInstallPreview = installer.doTestInstallPreview;
pub const drainTestInstall = installer.drainTestInstall;
pub const isTestInstallRunning = installer.isTestInstallRunning;
pub const freeTestInstallJob = installer.freeTestInstallJob;
pub const freePostInstallJobs = installer.freePostInstallJobs;
pub const isExtracting = installer.isExtracting;
pub const listDownloadedNotInstalled = installer.listDownloadedNotInstalled;
pub const startInstallFromDownloadJob = installer.startInstallFromDownloadJob;
pub const isInstallingForGame = installer.isInstallingForGame;
pub const extractProgressForGame = installer.extractProgressForGame;
pub const anyPostInstallActive = installer.anyPostInstallActive;
pub const drainPostInstall = installer.drainPostInstall;
pub const freeManualInstallJobs = installer.freeManualInstallJobs;
pub const startManualInstall = installer.startManualInstall;
pub const drainManualInstall = installer.drainManualInstall;
pub const doRenameInstall = installer.doRenameInstall;
pub const doDeleteInstall = installer.doDeleteInstall;

// ---- Library maintenance ----
pub const doReanalyseAllEngines = mods.doReanalyseAllEngines;
pub const EngineReanalyseStats = mods.EngineReanalyseStats;

// ---- Mods page ----
pub const doRegisterModArchive = mods.doRegisterModArchive;
pub const freeModfileCacheState = mods.freeModfileCacheState;
pub const modsPageCache = mods.modsPageCache;
pub const modfilesForGame = mods.modfilesForGame;
pub const doAddModfile = mods.doAddModfile;
pub const doImportModRecipe = mods.doImportModRecipe;
pub const modfileArchivePath = mods.modfileArchivePath;
pub const archiveTopDirs = mods.archiveTopDirs;
pub const freeTopDirs = mods.freeTopDirs;
pub const installTopDirs = mods.installTopDirs;
pub const simulateCurrentPlan = mods.simulateCurrentPlan;
pub const doDeleteUserPresetArmed = mods.doDeleteUserPresetArmed;
pub const getMergedPresets = mods.getMergedPresets;
pub const invalidatePresetCache = mods.invalidatePresetCache;
pub const doSetModfilePreset = mods.doSetModfilePreset;
pub const doSaveModRecipeAsPreset = mods.doSaveModRecipeAsPreset;
pub const openSettingsTab = mods.openSettingsTab;
pub const doScanModfiles = mods.doScanModfiles;
pub const doDeleteModfile = mods.doDeleteModfile;
pub const clearPendingDelete = mods.clearPendingDelete;
pub const doDeleteModRecipeArmed = mods.doDeleteModRecipeArmed;
pub const openWizardForModfile = mods.openWizardForModfile;
pub const closeWizard = mods.closeWizard;
pub const wizardAddBlock = mods.wizardAddBlock;
pub const wizardRemoveBlock = mods.wizardRemoveBlock;
pub const wizardSave = mods.wizardSave;

// Pull nested tests into this module's test binary. The re-exports above
// only analyze the referenced symbols, so nested `test` blocks would
// silently no-op (same idiom as downloads.zig / importers.zig roots).
test {
    _ = @import("actions/auth.zig");
    _ = @import("actions/bookmarks.zig");
    _ = @import("actions/common.zig");
    _ = @import("actions/downloads.zig");
    _ = @import("actions/imports.zig");
    _ = @import("actions/installer.zig");
    _ = @import("actions/launch.zig");
    _ = @import("actions/mods.zig");
    _ = @import("actions/renpy_tools.zig");
    _ = @import("actions/rpgm_tools.zig");
    _ = @import("actions/sync.zig");
    _ = @import("actions/tags.zig");
    _ = @import("actions/universal_mods.zig");
}
