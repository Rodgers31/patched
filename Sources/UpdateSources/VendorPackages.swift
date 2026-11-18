import Foundation

/// A developer's own signed installer package for an app, used only when the installed copy is owned by the system
/// (root-owned, for example after the app's "update for all users" step or an MDM install), so Patched cannot replace
/// it itself. The version on offer still comes from the app's normal check; this only says where the package is.
/// The package must still pass every installer package check (Developer ID Installer from the installed app's Team
/// ID, notarised), and its Distribution must name this bundle ID at the offered version or newer.
public struct VendorPackageRoute: Sendable, Equatable {
    public let bundleID: String
    /// Unversioned: it may serve a newer build than the check offered, which is why the package's own Distribution
    /// version is read and checked before Apple's Installer is opened.
    public let packageURL: URL
    /// Hard ceiling for this download, well below the general one.
    public let maxBytes: Int64
    /// Where the package installs the app. The route applies only to an app at exactly this path: a copy
    /// elsewhere would be left alone by the package while Patched waited for it to change.
    public let installPath: String
    /// The developer's Team ID. The installed app must be signed by it, and so (because the package's Developer
    /// ID Installer Team ID must equal the installed app's) must the package.
    public let teamID: String

    public init(bundleID: String, packageURL: URL, maxBytes: Int64, installPath: String, teamID: String) {
        self.bundleID = bundleID; self.packageURL = packageURL; self.maxBytes = maxBytes
        self.installPath = installPath; self.teamID = teamID
    }

    /// The route is for this installed app: the package's install path (compared after collapsing `//`, `.` and
    /// `..`, as the installer does) and the developer's Team ID.
    public func applies(toAppAt path: String, teamID: String?) -> Bool {
        teamID == self.teamID && Self.normalised(path) == Self.normalised(installPath)
    }

    static func normalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The offer to download: the checked version, the package URL, nothing of the original download's length,
    /// digests or signature (they describe a different file). The source stays, so versions compare as before.
    public func packageOffer(for offer: UpdateOffer) -> UpdateOffer {
        UpdateOffer(displayVersion: offer.displayVersion, buildVersion: offer.buildVersion, downloadURL: packageURL,
                    format: .pkg, source: offer.source)
    }
}

/// Compiled-in constants: nothing is read from disk or the network to build this list.
public enum VendorPackages {
    public static let routes: [String: VendorPackageRoute] = [
        // Google Chrome: Developer ID Installer: Google LLC (EQHXZ8M8AV), notarised, about 280 MB.
        "com.google.Chrome": VendorPackageRoute(
            bundleID: "com.google.Chrome",
            packageURL: URL(string: "https://dl.google.com/dl/chrome/mac/universal/stable/gcem/GoogleChrome.pkg")!,
            maxBytes: 1024 * 1024 * 1024,
            installPath: "/Applications/Google Chrome.app",
            teamID: "EQHXZ8M8AV"),
    ]

    public static func route(forBundleID bundleID: String?) -> VendorPackageRoute? {
        bundleID.flatMap { routes[$0] }
    }

    /// The route for this installed app, only when it is at the package's install path and signed by the developer.
    public static func route(forBundleID bundleID: String?, appPath: String, teamID: String?) -> VendorPackageRoute? {
        route(forBundleID: bundleID).flatMap { $0.applies(toAppAt: appPath, teamID: teamID) ? $0 : nil }
    }
}
