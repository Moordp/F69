pub const Error = error{
    UnknownEngine,
    EngineMismatch,
    VersionDetectFailed,
    SdkNotCached,
    SdkLayoutInvalid,
    SyslibResolveFailed,
    LauncherWriteFailed,
    LauncherNotFound,
    UnsupportedDistro,
    InstallNotFound,
    OutOfMemory,
    NetworkError,
    NotFound,
    NotImplemented,
    /// Convert-preset ZON failed to parse.
    ParseFailed,
    /// Failed to write a user preset file.
    WriteFailed,
    /// mkxp-z binary missing — non-Linux build or vendored
    /// `third_party/mkxp-z/` was not copied into the install tree.
    MkxpZNotBundled,
    /// The caller's `Progress.cancelled` hook asked the step to stop.
    Cancelled,
};
