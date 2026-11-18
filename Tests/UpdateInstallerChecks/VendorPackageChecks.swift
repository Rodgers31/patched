import Foundation
import Darwin
import UpdateSources
import UpdateInstaller

// Developer package routes (VendorPackages): a system-owned app whose normal download is a zip or dmg is updated
// through the developer's own signed package and Apple's Installer. Fakes only: the downloader serves a minimal
// flat package at the route's URL, `pkgutil --expand` is a fake runner that writes a Distribution, and a
// "system-owned" app is simulated with a different installer uid, as in AdminChecks.

let chromeID = "com.google.Chrome"
let chromePackageURL = "https://dl.google.com/dl/chrome/mac/universal/stable/gcem/GoogleChrome.pkg"

/// A Distribution in the shape Google's package uses: a `pkg-ref` in the choice without a version, then again
/// with it. `bundle` adds a `<bundle-version>` entry as other vendors write it.
func distributionXML(id: String = chromeID, version: String? = "2.0", bundle: String? = nil) -> String {
    let versioned = version.map { "<pkg-ref id=\"\(id)\" version=\"\($0)\" onConclusion=\"none\">GoogleChrome.pkg</pkg-ref>" } ?? ""
    let bundled = bundle.map { "<pkg-ref id=\"\(id)\"><bundle-version><bundle CFBundleShortVersionString=\"\($0)\" id=\"\(id)\" path=\"Google Chrome.app\"/></bundle-version></pkg-ref>" } ?? ""
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <installer-gui-script minSpecVersion="2">
        <title>Google Chrome</title>
        <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
        <choices-outline><line choice="default"><line choice="\(id)"/></line></choices-outline>
        <choice id="default"/>
        <choice id="\(id)" visible="false"><pkg-ref id="\(id)"/></choice>
        \(versioned)
        \(bundled)
    </installer-gui-script>
    """
}

/// The real Distribution reader, with `pkgutil --expand` replaced by writing `xml` (nil: write nothing) where
/// pkgutil would put the Distribution.
func fakeDistributions(_ xml: String?, calls: CallLog? = nil, status: Int32 = 0) -> SystemPackageDistributionReader {
    SystemPackageDistributionReader(run: { tool, arguments, _ in
        calls?.add(([tool] + arguments).joined(separator: " "))
        guard status == 0, arguments.count == 3, arguments[0] == "--expand" else {
            return ProcessRunner.Output(status: status == 0 ? 2 : status, timedOut: false, stdout: "", stderr: "fake pkgutil: failed")
        }
        try? FileManager.default.createDirectory(atPath: arguments[2], withIntermediateDirectories: false)
        if let xml { try? Data(xml.utf8).write(to: URL(fileURLWithPath: arguments[2] + "/Distribution")) }
        return ProcessRunner.Output(status: 0, timedOut: false, stdout: "", stderr: "")
    })
}

/// Chrome's route, with its install path moved to the world's app (the real one is in /Applications).
func testRoute(_ w: World, team: String = teamA) -> VendorPackageRoute {
    let real = VendorPackages.route(forBundleID: chromeID)!
    return VendorPackageRoute(bundleID: chromeID, packageURL: real.packageURL, maxBytes: real.maxBytes, installPath: w.target, teamID: team)
}

func vendorAdminPath(_ w: World, route: VendorPackageRoute? = nil, distribution: String? = distributionXML(), packages: any PackageVerifying = fixturePackageVerifier(),
                     opener: FakeOpener = FakeOpener(), calls: CallLog? = nil, replacer: FakeReplacer = FakeReplacer(),
                     replacement: Bool = false, pkg: Bool = true) -> AdminUpdatePath {
    AdminUpdatePath(replacer: replacer, packages: packages, opener: opener,
                    waiter: VersionPollingWaiter(timeout: 1.5, interval: 0.02, stableReads: 2, settleInterval: 0.05, settleTimeout: 1.5),
                    session: FakeSession(), distributions: fakeDistributions(distribution, calls: calls),
                    packageRoutes: { [route = route ?? testRoute(w)] id in id == route.bundleID ? route : nil },
                    allowsReplacement: replacement, allowsPackages: pkg)
}

/// Installed Chrome 1.0 (a zip/dmg app as far as its check goes), a v2 zip at v2zip and a flat package at the route URL.
func chromeWorld(id: String = chromeID) throws -> World {
    let box = try Sandbox()
    let target = try makeApp(at: box.apps + "/Google Chrome.app", id: id, short: "1.0", build: "100")
    let source = box.fixtures + "/src"
    try makeApp(at: source + "/Google Chrome.app", id: id, short: "2.0", build: "200")
    let archive = box.fixtures + "/v2.zip"
    try zip(source + "/Google Chrome.app", to: archive)
    let pkg = box.fixtures + "/GoogleChrome.pkg"
    try makeFlatPackage(at: pkg)
    let downloader = FakeDownloader()
    downloader.serve(v2zip, from: archive)
    downloader.serve(chromePackageURL, from: pkg)
    return World(box: box, target: target, downloader: downloader, archive: pkg)
}

/// What Homebrew's `google-chrome` cask offers: a dmg/zip, not a package.
func caskOffer(_ short: String = "2.0") -> UpdateOffer {
    UpdateOffer(displayVersion: short, buildVersion: nil, downloadURL: URL(string: v2zip)!, format: .zip,
                source: .homebrewCask(token: "google-chrome"))
}

func chromeOutcome(_ w: World, _ offer: UpdateOffer = caskOffer()) -> AppCheckOutcome {
    AppCheckOutcome(app: InstalledApp(name: "Google Chrome", path: w.target, bundleID: (try? BundleFacts.read(bundleAt: w.target))?.bundleID,
                                      shortVersion: "1.0", build: "100"),
                    teamID: teamA, source: offer.source, lowConfidence: false, installable: true, result: .updateAvailable(offer))
}

/// Apple's Installer leaving Chrome `short` behind.
func installChrome(_ target: String, short: String = "2.0", build: String = "200", team: String = teamA, id: String = chromeID) throws {
    try FileManager.default.removeItem(atPath: target)
    try makeApp(at: target, id: id, short: short, build: build, team: team)
}

func registerVendorPackageChecks() {
    check("vendor pkg: the table lists Chrome's own package over HTTPS with a size cap, and nothing else by accident") {
        let route = try unwrap(VendorPackages.route(forBundleID: chromeID), "no Chrome route")
        try expectEqual(route.packageURL.absoluteString, chromePackageURL)
        try expect(route.installPath == "/Applications/Google Chrome.app" && route.teamID == "EQHXZ8M8AV", "\(route)")
        try expect(route.applies(toAppAt: "/Applications/Google Chrome.app", teamID: "EQHXZ8M8AV")
                   && route.applies(toAppAt: "/Applications//Google Chrome.app", teamID: "EQHXZ8M8AV")
                   && route.applies(toAppAt: "/Applications/Tools/../Google Chrome.app", teamID: "EQHXZ8M8AV"), "install path not matched")
        for (path, team) in [("/Users/Shared/Google Chrome.app", "EQHXZ8M8AV"), ("/Applications/Tools/Google Chrome.app", "EQHXZ8M8AV"),
                             ("/Applications/Google Chrome.app", "AAAAAAAAAA"), ("/Applications/Google Chrome.app", nil)] as [(String, String?)] {
            try expect(!route.applies(toAppAt: path, teamID: team), "route applies to \(path) \(String(describing: team))")
            try expect(VendorPackages.route(forBundleID: chromeID, appPath: path, teamID: team) == nil, "lookup for \(path)")
        }
        try expect(route.maxBytes > 300 * 1024 * 1024 && route.maxBytes < DownloadLimits.maxBytes, "cap \(route.maxBytes)")
        for (id, entry) in VendorPackages.routes {
            try expectEqual(entry.bundleID, id, "key and bundle ID differ")
            try expect(entry.packageURL.scheme == "https" && entry.packageURL.host?.isEmpty == false, "\(id) is not HTTPS")
            try expect(entry.packageURL.path.lowercased().hasSuffix(".pkg"), "\(id) is not a package")
        }
        try expect(VendorPackages.route(forBundleID: bundleID) == nil && VendorPackages.route(forBundleID: nil) == nil
                   && VendorPackages.route(forBundleID: "com.google.chrome") == nil, "lookup is not exact")
        let packaged = route.packageOffer(for: UpdateOffer(displayVersion: "2.0", buildVersion: "2.0", downloadURL: URL(string: v2zip)!,
                                                           sha256: String(repeating: "a", count: 64), edSignature: "x", length: 5,
                                                           format: .dmg, source: .homebrewCask(token: "google-chrome")))
        try expect(packaged.format == .pkg && packaged.downloadURL == route.packageURL && packaged.sha256 == nil
                   && packaged.length == nil && packaged.edSignature == nil && packaged.displayVersion == "2.0", "\(packaged)")
        // Off with installer packages off.
        let w = try chromeWorld()
        try expect(adminInstaller(w.box, admin: vendorAdminPath(w, pkg: false)).vendorPackageRoute(forBundleID: chromeID, appPath: w.target, teamID: teamA) == nil, "route with pkg off")
        try expect(adminInstaller(w.box, admin: nil).vendorPackageRoute(forBundleID: chromeID, appPath: w.target, teamID: teamA) == nil, "route with no admin path")
        try expect(adminInstaller(w.box, admin: vendorAdminPath(w)).vendorPackageRoute(forBundleID: chromeID, appPath: w.target, teamID: teamA) == testRoute(w), "route missing")
    }

    check("vendor pkg: a system-owned Chrome updates through its own package; the right steps run in order") {
        let w = try chromeWorld()
        let opener = FakeOpener(), calls = CallLog(), verifierCalls = CallLog()
        let target = w.target, downloads = w.box.locations.downloads
        opener.onOpen = { pkg in
            guard pkg.hasPrefix(downloads + "/"), FileSafety.mode(pkg) == 0o400 else { throw CheckFailure(description: "package not locked: \(pkg)") }
            try installChrome(target)
        }
        let path = vendorAdminPath(w, packages: fixturePackageVerifier(calls: verifierCalls), opener: opener, calls: calls)
        let messages = CallLog()
        let report = try await adminInstaller(w.box, admin: path, downloader: w.downloader)
            .update(chromeOutcome(w), admin: AdminInteraction(onInstallerOpened: { messages.add($0) }))
        try expectEqual(report.status, .installed)
        try expectEqual(report.toVersion, "2.0 (200)")
        try expect(report.privileged && report.note?.contains("developer's package (dl.google.com)") == true, "\(report)")
        try expectEqual(w.downloader.calls, 1, "downloaded more than the package")
        try expectEqual(verifierCalls.all, ["/usr/sbin/pkgutil", "/usr/sbin/spctl"], "signature and notarisation")
        try expectEqual(calls.all.count, 1, "Distribution not read once")
        try expect(calls.all[0].hasPrefix("/usr/sbin/pkgutil --expand " + downloads + "/"), calls.all[0])
        try expectEqual(opener.opened.count, 1)
        try expect(messages.all.first?.contains("Google Chrome.app 2.0") == true, "\(messages.all)")
        try expectEqual(try version(w.target), "2.0")
        try expectClean(w.box)
        // With the experimental replacement switched on too, the package route still comes first.
        let r = try chromeWorld()
        let rOpener = FakeOpener(), replacer = FakeReplacer()
        let rTarget = r.target
        rOpener.onOpen = { _ in try installChrome(rTarget) }
        let both = try await adminInstaller(r.box, admin: vendorAdminPath(r, opener: rOpener, replacer: replacer, replacement: true), downloader: r.downloader)
            .update(chromeOutcome(r), admin: AdminInteraction())
        try expect(both.status == .installed && rOpener.opened.count == 1 && replacer.authorizations == 0, "replacement used: \(both)")
    }

    check("vendor pkg: only a system-owned, listed app with consent and installer packages on takes the route") {
        // User-owned Chrome: the ordinary zip update, never Installer.
        let owned = try chromeWorld()
        let opener = FakeOpener(), calls = CallLog()
        let report = try await adminInstaller(owned.box, admin: vendorAdminPath(owned, opener: opener, calls: calls), downloader: owned.downloader, uid: geteuid())
            .update(chromeOutcome(owned), admin: AdminInteraction())
        try expect(report.status == .installed && !report.privileged, "user-owned Chrome used the package: \(report)")
        try expectEqual(try version(owned.target), "2.0")
        // System-owned but not listed; system-owned and listed without consent (Update All, automatic); packages off.
        let unlisted = try chromeWorld(id: bundleID)
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(unlisted.box, admin: vendorAdminPath(unlisted, opener: opener, calls: calls), downloader: unlisted.downloader)
                .update(chromeOutcome(unlisted), admin: AdminInteraction())
        }
        let listed = try chromeWorld()
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(listed.box, admin: vendorAdminPath(listed, opener: opener, calls: calls), downloader: listed.downloader)
                .update(chromeOutcome(listed), admin: nil)
        }
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(listed.box, admin: vendorAdminPath(listed, opener: opener, calls: calls, replacement: false, pkg: false),
                                         downloader: listed.downloader).update(chromeOutcome(listed), admin: AdminInteraction())
        }
        try await expectRefusal("needs_admin") {
            _ = try await adminInstaller(listed.box, admin: nil, downloader: listed.downloader).update(chromeOutcome(listed), admin: AdminInteraction())
        }
        try expectEqual(opener.opened.count, 0, "Installer opened")
        try expect(calls.all.isEmpty, "Distribution read: \(calls.all)")
        try expectEqual(listed.downloader.calls + unlisted.downloader.calls, 0, "downloaded")
        try expectEqual(try version(listed.target), "1.0")
        try expectClean(listed.box)
    }

    check("vendor pkg: a system-owned Chrome away from the package's install path, or from another team, is refused as before") {
        for (name, route) in [("real install path", VendorPackages.route(forBundleID: chromeID)!), ("another team", nil)] {
            let w = try chromeWorld()
            let opener = FakeOpener(), calls = CallLog()
            let chosen = route ?? testRoute(w, team: teamB)
            try await expectRefusal("needs_admin") {
                _ = try await adminInstaller(w.box, admin: vendorAdminPath(w, route: chosen, opener: opener, calls: calls), downloader: w.downloader)
                    .update(chromeOutcome(w), admin: AdminInteraction())
            }
            try expect(opener.opened.isEmpty && calls.all.isEmpty && w.downloader.calls == 0, "\(name): route taken")
            try expect(CommandLineUpdates.consent(.all, installer: adminInstaller(w.box, admin: vendorAdminPath(w, route: chosen)), notice: { _ in }) == nil, "consent")
            do {
                _ = try await CommandLineUpdates.update(chromeOutcome(w), installer: adminInstaller(w.box, admin: vendorAdminPath(w, route: chosen), downloader: w.downloader),
                                                        options: UpdateOptions(), scope: .all, notice: { _ in })
                throw CheckFailure(description: "installed")
            } catch let refusal as InstallRefusal {
                try expectEqual(refusal.code, "needs_admin", "\(name): --all")
            }
            try expectEqual(try version(w.target), "1.0")
        }
    }

    check("vendor pkg: an app that moved on during the download is never handed an older or equal package") {
        for moved in ["2.0", "2.5"] {
            let w = try chromeWorld()
            let opener = FakeOpener()
            let target = w.target
            // The app's own updater installs `moved` after the package was verified, before Installer opens.
            let racing = AfterVerify(inner: fixturePackageVerifier()) { _ in try installChrome(target, short: moved, build: moved == "2.0" ? "200" : "250") }
            try await expectRefusal("not_newer") {
                _ = try await adminInstaller(w.box, admin: vendorAdminPath(w, packages: racing, opener: opener), downloader: w.downloader)
                    .update(chromeOutcome(w), admin: AdminInteraction())
            }
            try expectEqual(opener.opened.count, 0, "\(moved): Installer opened")
            try expectEqual(try version(w.target), moved)
            try expectClean(w.box)
        }
        // Moved on to something still older than the package: it goes ahead.
        let w = try chromeWorld()
        let opener = FakeOpener()
        let target = w.target
        opener.onOpen = { _ in try installChrome(target) }
        let racing = AfterVerify(inner: fixturePackageVerifier()) { _ in try installChrome(target, short: "1.5", build: "150") }
        let report = try await adminInstaller(w.box, admin: vendorAdminPath(w, packages: racing, opener: opener), downloader: w.downloader)
            .update(chromeOutcome(w), admin: AdminInteraction())
        try expect(report.status == .installed && opener.opened.count == 1, "\(report)")
    }

    check("vendor pkg: a server announcing more than the route's cap is refused before the body") {
        let box = try Sandbox()
        VendorStubProtocol.announce = 5_000
        let downloader = URLSessionArtifactDownloader(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [VendorStubProtocol.self]
            return configuration
        })
        let sink = try ArtifactSink(path: box.fixtures + "/capped.pkg", maxBytes: 1_000)
        try await expectRefusal("too_large") { try await downloader.download(URL(string: chromePackageURL)!, into: sink, expectedLength: nil) }
        try expectEqual(sink.byteCount, 0, "body accepted")
        // Within the cap, the same server is fine.
        VendorStubProtocol.announce = 10
        let small = try ArtifactSink(path: box.fixtures + "/small.pkg", maxBytes: 1_000)
        try await downloader.download(URL(string: chromePackageURL)!, into: small, expectedLength: nil)
        try expectEqual(small.byteCount, 10)
    }

    check("vendor pkg: CLI update --all never takes the route, naming the app does") {
        let w = try chromeWorld()
        let opener = FakeOpener()
        let target = w.target
        opener.onOpen = { _ in try installChrome(target) }
        let cli = adminInstaller(w.box, admin: vendorAdminPath(w, opener: opener), downloader: w.downloader)
        do {
            _ = try await CommandLineUpdates.update(chromeOutcome(w), installer: cli, options: UpdateOptions(), scope: .all, notice: { _ in })
            throw CheckFailure(description: "--all installed Chrome")
        } catch let refusal as InstallRefusal {
            try expectEqual(refusal.code, "needs_admin_approval")
            try expect(refusal.message.contains("run `patched update \(w.target)` to approve"), refusal.message)
        }
        try expectEqual(opener.opened.count, 0, "--all opened Installer")
        try expectEqual(w.downloader.calls, 0, "--all downloaded")
        let report = try await CommandLineUpdates.update(chromeOutcome(w), installer: cli, options: UpdateOptions(), scope: .oneApp, notice: { _ in })
        try expect(report.status == .installed && report.privileged && opener.opened.count == 1, "\(report)")
    }

    check("vendor pkg: a package from another team, or not notarised, never reaches Apple's Installer") {
        for (verifier, code) in [(fixturePackageVerifier(pkgutil: "pkgutil-other-team.txt"), "package_signature_invalid"),
                                 (fixturePackageVerifier(spctl: "spctl-other-team.txt"), "notarisation_rejected")] {
            let w = try chromeWorld()
            let opener = FakeOpener(), calls = CallLog()
            try await expectRefusal(code) {
                _ = try await adminInstaller(w.box, admin: vendorAdminPath(w, packages: verifier, opener: opener, calls: calls), downloader: w.downloader)
                    .update(chromeOutcome(w), admin: AdminInteraction())
            }
            try expectEqual(opener.opened.count, 0, "\(code): Installer opened")
            try expect(calls.all.isEmpty, "\(code): Distribution read before the signature passed")
            try expectEqual(try version(w.target), "1.0")
            try expectClean(w.box)
        }
    }

    check("vendor pkg: a Distribution that is missing, versionless, older, for another app or conflicting is refused") {
        let cases: [(String, String?, String)] = [
            ("no Distribution", nil, "package_malformed"),
            ("not an installer script", "<html><body>hello</body></html>", "package_malformed"),
            ("not XML", "\u{0}\u{1}garbage", "package_malformed"),
            ("no version", distributionXML(version: nil), "package_version_mismatch"),
            ("older", distributionXML(version: "1.9.9"), "package_version_mismatch"),
            ("another bundle ID", distributionXML(id: "com.google.Keystone", version: "2.0"), "package_version_mismatch"),
            ("older app inside", distributionXML(version: "2.0", bundle: "1.5"), "package_version_mismatch"),
            ("conflicting", distributionXML(version: "2.0").replacingOccurrences(of: "</installer-gui-script>",
                with: "<pkg-ref id=\"\(chromeID)\" version=\"3.0\"/></installer-gui-script>"), "package_version_mismatch"),
        ]
        for (name, xml, code) in cases {
            let w = try chromeWorld()
            let opener = FakeOpener()
            try await expectRefusal(code) {
                _ = try await adminInstaller(w.box, admin: vendorAdminPath(w, distribution: xml, opener: opener), downloader: w.downloader)
                    .update(chromeOutcome(w), admin: AdminInteraction())
            }
            try expectEqual(opener.opened.count, 0, "\(name): Installer opened")
            try expectEqual(try version(w.target), "1.0", name)
            try expectClean(w.box)
            try expect(((try? FileManager.default.contentsOfDirectory(atPath: w.box.locations.backups)) ?? []).isEmpty, "\(name): copy kept")
        }
        try expectEqual(InstallRefusal.packageVersionMismatch("x").code, "package_version_mismatch")
    }

    check("vendor pkg: a newer package than the offer is accepted and the result is judged against the package's version") {
        // The unversioned URL served 2.1 while Homebrew offered 2.0: Installer's 2.1 is accepted.
        let w = try chromeWorld()
        let opener = FakeOpener(), messages = CallLog()
        let target = w.target
        opener.onOpen = { _ in try installChrome(target, short: "2.1", build: "210") }
        let report = try await adminInstaller(w.box, admin: vendorAdminPath(w, distribution: distributionXML(version: "2.1"), opener: opener),
                                              downloader: w.downloader)
            .update(chromeOutcome(w), admin: AdminInteraction(onInstallerOpened: { messages.add($0) }))
        try expect(report.status == .installed && report.toVersion == "2.1 (210)", "\(report)")
        try expect(messages.all.first?.contains("Google Chrome.app 2.1") == true, "\(messages.all)")
        try expectClean(w.box)
        // The package said 2.1 but Installer left 2.0: not what the package promised, so it fails verification.
        let x = try chromeWorld()
        let xOpener = FakeOpener()
        let xTarget = x.target
        xOpener.onOpen = { _ in try installChrome(xTarget, short: "2.0", build: "200") }
        try await expectRefusal("installed_unverified") {
            _ = try await adminInstaller(x.box, admin: vendorAdminPath(x, distribution: distributionXML(version: "2.1"), opener: xOpener),
                                         downloader: x.downloader).update(chromeOutcome(x), admin: AdminInteraction())
        }
        // The app's own version inside the Distribution wins over the package's when both are given.
        let offer = caskOffer("2.0")
        let both = try PackageDistribution.requireVersion(Data(distributionXML(version: "2.0.1", bundle: "2.0.5").utf8), bundleID: chromeID, offer: offer)
        try expectEqual(both, "2.0.5")
        try expect(PackageDistribution.expectedOffer(offer, packageVersion: "2.0") == offer, "an equal version changed the offer")
        let newer = PackageDistribution.expectedOffer(UpdateOffer(displayVersion: "2.0", buildVersion: "2.0.0.1", downloadURL: URL(string: chromePackageURL)!,
                                                                  format: .pkg, source: offer.source), packageVersion: "2.1")
        try expect(newer.displayVersion == "2.1" && newer.buildVersion == nil && newer.format == .pkg, "\(newer)")
    }

    check("vendor pkg: an interrupted install is recovered against the package's version, not the check's") {
        let w = try chromeWorld()
        let opener = FakeOpener()
        let target = w.target
        opener.onOpen = { _ in
            try installChrome(target, short: "2.1", build: "210")
            throw SimulatedCrash(phase: "installer open")
        }
        let admin = vendorAdminPath(w, distribution: distributionXML(version: "2.1"), opener: opener)
        do {
            _ = try await adminInstaller(w.box, admin: admin, downloader: w.downloader).update(chromeOutcome(w), admin: AdminInteraction())
            throw CheckFailure(description: "no crash")
        } catch is SimulatedCrash {}
        let recovered = await adminInstaller(w.box, admin: nil).recover()
        try expectEqual(recovered.reports.count, 1)
        try expect(recovered.reports.first?.result == .success(.completed), "\(recovered.reports)")
        try expectClean(w.box)
    }

    check("Distribution reader: only one small regular file is read back, and pkgutil failures are refusals") {
        let box = try Sandbox()
        let scratch = box.fixtures + "/scratch"
        try FileSafety.makeFreshPrivateDirectory(scratch)
        let data = try fakeDistributions(distributionXML()).distribution(ofPackageAt: box.fixtures + "/x.pkg", scratch: scratch)
        let read = try PackageDistribution.versions(in: data, bundleID: chromeID)
        try expect(read.packageRefs == ["2.0"] && read.bundles.isEmpty, "\(read)")
        // A symlinked or oversized Distribution, and pkgutil failing.
        let linked = box.fixtures + "/linked"
        try FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try Data(distributionXML().utf8).write(to: URL(fileURLWithPath: box.fixtures + "/real.xml"))
        try FileManager.default.createSymbolicLink(atPath: linked + "/Distribution", withDestinationPath: box.fixtures + "/real.xml")
        try await expectRefusal("package_malformed") { _ = try PackageDistribution.readFile(linked + "/Distribution") }
        try Data(repeating: 0x20, count: PackageDistribution.maxBytes + 1).write(to: URL(fileURLWithPath: box.fixtures + "/big.xml"))
        try await expectRefusal("package_malformed") { _ = try PackageDistribution.readFile(box.fixtures + "/big.xml") }
        let again = box.fixtures + "/scratch2"
        try FileSafety.makeFreshPrivateDirectory(again)
        try await expectRefusal("package_malformed") {
            _ = try fakeDistributions(distributionXML(), status: 1).distribution(ofPackageAt: box.fixtures + "/x.pkg", scratch: again)
        }
        // A FIFO in the Distribution's place is refused at once, never waited on.
        let fifoDir = box.fixtures + "/fifo"
        try FileManager.default.createDirectory(atPath: fifoDir, withIntermediateDirectories: true)
        try expect(mkfifo(fifoDir + "/Distribution", 0o600) == 0, "mkfifo")
        let outcome = CallLog()
        Thread.detachNewThread {
            do { _ = try PackageDistribution.readFile(fifoDir + "/Distribution"); outcome.add("read") }
            catch let refusal as InstallRefusal { outcome.add(refusal.code) } catch { outcome.add("\(error)") }
        }
        for _ in 0..<250 where outcome.all.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        if outcome.all.isEmpty {
            // Unblock the stuck open so the thread can end, then fail.
            let writer = open(fifoDir + "/Distribution", O_WRONLY | O_NONBLOCK); if writer >= 0 { close(writer) }
            throw CheckFailure(description: "opening a FIFO Distribution blocked")
        }
        try expectEqual(outcome.all, ["package_malformed"], "FIFO")
        // External entities are never loaded, and an entity cannot smuggle in a version.
        let external = """
        <?xml version="1.0"?><!DOCTYPE x [<!ENTITY v SYSTEM "file://\(box.fixtures)/real.xml">]>
        <installer-gui-script><pkg-ref id="\(chromeID)" version="&v;"/></installer-gui-script>
        """
        if let found = try? PackageDistribution.versions(in: Data(external.utf8), bundleID: chromeID) {
            try expect(found.packageRefs.allSatisfy { !$0.contains("installer-gui-script") }, "external entity loaded: \(found)")
        }
    }
}

func unwrap<T>(_ value: T?, _ message: String, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "line \(line): \(message)") }
    return value
}

/// Answers every request with HTTP 200, a Content-Length of `announce` and a 10-byte body.
final class VendorStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var announce = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(Self.announce)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x42, count: 10))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
