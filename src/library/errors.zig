pub const Error = error{
    GameNotFound,
    InstallNotFound,
    ModNotFound,
    DuplicateGame,
    DuplicateInstall,
    /// changeThreadId: the target thread id is already a game in the library.
    ThreadIdInUse,
    /// registerManualInstall: that folder is already registered to a game.
    InstallPathInUse,
    /// registerManualInstall: this game already has an install labelled that version.
    InstallVersionExists,
    InvalidVersion,
    SchemaMigrationFailed,
    SchemaTooNew,
    DatabaseError,
    OutOfMemory,
};
