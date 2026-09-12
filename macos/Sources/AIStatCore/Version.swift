import Foundation

public enum AIStatCore {
    /// The running version, read from the bundle that hosts this code.
    ///
    /// Deliberately not a constant in source. The repository's single source of
    /// truth for the version is `[workspace.package] version` in the Rust
    /// workspace's `Cargo.toml`, and the release workflow refuses to build a
    /// tag that disagrees with it — a second copy here would be one more thing
    /// to keep in step, and the one most likely to be forgotten. `bundle.sh`
    /// reads that number and stamps it into `CFBundleShortVersionString`.
    ///
    /// `swift run` and the test suite have no bundle to read, so they report
    /// `dev`, which is also what the HTTP user agent then says.
    public static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
