import Foundation
import UpdateSources
import UpdateInstaller
@_spi(Testing) import PatchedClient

// Experimental admin path on the Updates screen. Off: every text and action is as before, and the
// installer is never handed a consent token. On: only an explicit click on one row may use it.

/// Google Chrome where its package installs it, signed by Google: the one place the developer package route applies.
func chromeApp(path: String = "/Applications/Google Chrome.app") -> InstalledApp {
    InstalledApp(name: "Google Chrome", path: path, bundleID: "com.google.Chrome", shortVersion: "1.0", build: "1.0")
}
func chromeOutcome(_ app: InstalledApp, _ result: CheckResult, source: UpdateSource? = nil, team: String = "EQHXZ8M8AV") -> AppCheckOutcome {
    AppCheckOutcome(app: app, teamID: team, source: source ?? .sparkle(feed: URL(string: "https://example.com/feed.xml")!),
                    lowConfidence: false, installable: true, result: result)
}

final class AdminBox: @unchecked Sendable {
    private let lock = NSLock(); private var paths: Set<String>
    init(_ paths: Set<String>) { self.paths = paths }
    func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    func set(_ new: Set<String>) { lock.withLock { paths = new } }
}

@MainActor func adminEvents(_ installer: FakeInstaller) -> [String] { installer.recorder.events.filter { $0.hasPrefix("admin") } }

@MainActor func registerAdminUpdateChecks() {
    check("admin off: rows, buttons and refusals are exactly as before and no consent ever reaches the installer") {
        let admin = app("Admin"), pkg = app("Pkgy")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in throw InstallRefusal.needsAdmin("root-owned") }
        installer.backups = [try backup(admin)]
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0"))),
                                                   outcome(pkg, .updateAvailable(offer("2.0", format: .pkg)))], installer: installer)
        await runCheck(controller)
        try expect(!controller.adminUpdatesEnabled, "admin on by default")
        @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
        try expect(row("Pkgy").status == .packageUnsupported && row("Pkgy").statusText == "Installer package updates are turned off", "pkg row changed")
        try expect(row("Pkgy").updateActionTitle == "Update" && row("Admin").updateActionTitle == "Update", "button titles changed")
        await runOperation(controller) { controller.update(id: admin.path) }
        try expect(row("Admin").result?.text == "Admin: Needs admin rights. Open the app and use its own updater.", "needs_admin text: \(String(describing: row("Admin").result))")
        try expect(row("Admin").updateActionTitle == "Update" && row("Admin").privilege == .standard, "row marked admin with the flag off")
        try expect(row("Admin").needsManualAdmin, "row not marked as needing a manual update")
        await runOperation(controller) { controller.update(id: admin.path) }
        await runOperation(controller) { controller.updateAll() }
        await runOperation(controller) { controller.rollBack(id: admin.path) }
        try expect(adminEvents(installer).isEmpty, "consent passed with the flag off: \(adminEvents(installer))")
        try expect(controller.installerWait == nil, "installer sheet shown")
    }

    check("admin on: a needs_admin refusal turns the row into Update (admin), and only that click passes consent") {
        let admin = app("Admin"), plain = app("Plain")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Admin" { throw InstallRefusal.needsAdmin("root-owned") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        installer.adminHandler = { _, _ in
            AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b",
                            note: "installed with admin rights; the app is now owned by uid 0")
        }
        let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0"))), outcome(plain, .updateAvailable(offer("2.0")))],
                                        installer: installer, adminUpdates: true)
        await runCheck(controller)
        @MainActor func row(_ name: String) -> AppUpdateRow? { controller.rows.first { $0.name == name } }
        try expect(row("Admin")?.updateActionTitle == "Update", "admin title before anything is known")
        // Update All never passes consent; the app that needs admin is skipped and marked.
        await runOperation(controller) { controller.updateAll() }
        try expect(adminEvents(installer).isEmpty, "Update All passed consent: \(adminEvents(installer))")
        try expect(controller.summary == "1 updated, 1 skipped.", "summary: \(controller.summary)")
        try expect(row("Admin")?.privilege == .admin && row("Admin")?.updateActionTitle == "Update (admin)", "not marked admin: \(String(describing: row("Admin")))")
        try expect(row("Admin")?.result?.text.contains("Choose Update (admin)") == true && row("Admin")?.result?.kind == .info, "text: \(String(describing: row("Admin")?.result))")
        try expect(controller.updatableRows.isEmpty, "admin row offered to Update All: \(controller.updatableRows.map(\.name))")
        try expect(controller.canUpdate(row("Admin")!), "admin row must be updatable by its own button")
        // The mark survives a new check.
        await runCheck(controller)
        try expect(row("Admin")?.updateActionTitle == "Update (admin)", "mark lost after a check")
        await runOperation(controller) { controller.update(id: admin.path) }
        try expect(adminEvents(installer) == ["admin-update Admin"], "explicit click did not pass consent: \(installer.recorder.events)")
        try expect(row("Admin")?.result?.text.contains("installed with admin rights") == true && row("Admin")?.status == .upToDate,
                   "after: \(String(describing: row("Admin")))")
    }

    check("admin on: a pkg row is Update (installer), opens the Installer sheet, and Done reaches the installer") {
        let pkg = app("Pkgy")
        let installer = FakeInstaller()
        installer.adminHandler = { outcome, interaction in
            interaction.installerOpened("Apple's Installer has opened for Pkgy.app 2.0.")
            for _ in 0..<500 where !interaction.userSaysFinished { try await Task.sleep(nanoseconds: 10_000_000) }
            guard interaction.userSaysFinished else { throw InstallRefusal.installerNotFinished("no Done") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: nil,
                                   note: "installed by Apple's Installer")
        }
        let controller = makeController(outcomes: [outcome(pkg, .updateAvailable(offer("2.0", format: .pkg)))], installer: installer, packageUpdates: true)
        await runCheck(controller)
        let row = controller.rows[0]
        try expect(row.status == .updateAvailable && row.privilege == .installer && row.updateActionTitle == "Update (installer)", "pkg row: \(row)")
        try expect(row.statusText.contains("Apple's Installer"), "status text: \(row.statusText)")
        try expect(controller.canUpdate(row) && controller.updatableRows.isEmpty, "pkg must be its own click only")
        controller.update(id: pkg.path)
        for _ in 0..<300 where controller.installerWait == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(controller.installerWait?.name == "Pkgy" && controller.installerWait?.message.contains("has opened") == true,
                   "sheet: \(String(describing: controller.installerWait))")
        controller.finishInstaller()
        await controller.waitUntilIdle()
        try expect(controller.installerWait == nil, "sheet left open")
        try expect(controller.rows[0].result?.text == "Pkgy: updated 1.0 -> 2.0; no backup kept; installed by Apple's Installer",
                   "result: \(String(describing: controller.rows[0].result))")
        try expect(adminEvents(installer) == ["admin-update Pkgy"], "events: \(installer.recorder.events)")
    }

    check("flags are separate: pkg-only never marks Update (admin), admin-only leaves pkg unsupported") {
        let admin = app("Admin"), pkg = app("Pkgy")
        for (adminOn, pkgOn) in [(false, true), (true, false)] {
            let installer = FakeInstaller()
            installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
            installer.backups = [try backup(admin)]
            let controller = makeController(outcomes: [outcome(admin, .updateAvailable(offer("2.0"))), outcome(pkg, .updateAvailable(offer("2.0", format: .pkg)))],
                                            installer: installer, adminUpdates: adminOn, packageUpdates: pkgOn)
            await runCheck(controller)
            @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
            try expect(row("Pkgy").updateActionTitle == (pkgOn ? "Update (installer)" : "Update"), "pkg title admin=\(adminOn) pkg=\(pkgOn)")
            try expect((row("Pkgy").status == .packageUnsupported) == !pkgOn, "pkg status admin=\(adminOn) pkg=\(pkgOn)")
            await runOperation(controller) { controller.update(id: admin.path) }
            try expect(row("Admin").updateActionTitle == (adminOn ? "Update (admin)" : "Update"), "admin title admin=\(adminOn) pkg=\(pkgOn)")
            if !adminOn { try expect(row("Admin").result?.text == "Admin: Needs admin rights. Open the app and use its own updater.", "text: \(String(describing: row("Admin").result))") }
            await runOperation(controller) { controller.rollBack(id: admin.path) }
            try expect(adminEvents(installer).filter { $0.hasPrefix("admin-rollback") }.isEmpty == !adminOn, "rollback consent admin=\(adminOn)")
        }
    }

    check("admin on: macOS refusing the replacement for this build shows update manually, not an error") {
        let a = app("Admin")
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("root-owned") }
        installer.adminHandler = { _, _ in throw InstallRefusal.adminReplaceUnavailable("replace: NSCocoaErrorDomain 512") }
        let controller = makeController(outcomes: [outcome(a, .updateAvailable(offer("2.0")))], installer: installer, adminUpdates: true)
        await runCheck(controller)
        await runOperation(controller) { controller.update(id: a.path) }
        await runOperation(controller) { controller.update(id: a.path) }
        let result = controller.rows[0].result
        try expect(result?.kind == .info && result?.text == "Admin: macOS refused the privileged replacement for this build. Update this app manually.",
                   "result: \(String(describing: result))")
    }

    check("admin on: Roll back is an explicit click and passes consent; off, it never does") {
        for enabled in [false, true] {
            let a = app("Alpha")
            let installer = FakeInstaller()
            installer.backups = [try backup(a)]
            let controller = makeController(outcomes: [outcome(a, .upToDate)], installer: installer, adminUpdates: enabled)
            await runCheck(controller)
            await runOperation(controller) { controller.rollBack(id: a.path) }
            try expect(adminEvents(installer) == (enabled ? ["admin-rollback Alpha.app"] : []), "enabled=\(enabled): \(installer.recorder.events)")
        }
    }

    check("admin on: scheduled checks never reach the installer, let alone the admin path") {
        let rig = Rig([outcome(app("Admin"), .updateAvailable(offer("2.0"))), outcome(app("Pkgy"), .updateAvailable(offer("3.0", format: .pkg)))],
                      adminUpdates: true, packageUpdates: true)
        rig.scheduler.start(); await rig.settle()
        rig.clock.advance(UpdateCheckScheduler.interval)
        try rig.timer.fireActive(); await rig.settle()
        try expect(rig.checks.count == 2, "checks: \(rig.checks.count)")
        try rig.noInstallerActivity()
        try expect(rig.controller.availableUpdateCount == 2, "badge: \(rig.controller.availableUpdateCount)")
    }

    check("vendor pkg row: a system-owned listed app becomes Update…, never in Update All or automatic, and only its click passes consent") {
        let chrome = chromeApp(), plain = app("Plain")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Google Chrome" { throw InstallRefusal.needsAdmin("owned by uid 0") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        installer.adminHandler = { _, interaction in
            interaction.installerOpened("Apple's Installer has opened for Google Chrome.app 2.0.")
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: nil,
                                   note: "installed by Apple's Installer from the developer's package (dl.google.com)")
        }
        let cask = UpdateSource.homebrewCask(token: "google-chrome")
        let controller = makeController(outcomes: [chromeOutcome(chrome, .updateAvailable(offer("2.0", source: cask)), source: cask),
                                                   outcome(plain, .updateAvailable(offer("2.0")))],
                                        installer: installer, packageUpdates: true)
        await runCheck(controller)
        @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
        // Not known to need admin yet: an ordinary row (the table alone never changes a row).
        try expect(row("Google Chrome").privilege == .standard && row("Google Chrome").adminHelpText == nil, "routed before needs_admin")
        // Update All never passes consent; Chrome is skipped, marked and offered as Update….
        await runOperation(controller) { controller.updateAll() }
        try expect(adminEvents(installer).isEmpty, "Update All passed consent: \(adminEvents(installer))")
        let routed = row("Google Chrome")
        try expect(routed.privilege == .vendorPackage && routed.updateActionTitle == "Update…" && !routed.needsManualAdmin, "row: \(routed)")
        try expect(routed.adminHelpText == "Opens Apple's Installer, which asks for your password.", "help: \(String(describing: routed.adminHelpText))")
        try expect(routed.statusText == "Update available. Needs admin rights." && routed.kindNote == "Needs admin", "\(routed.statusText) / \(String(describing: routed.kindNote))")
        try expect(!controller.canOpenApp(routed) && controller.canUpdate(routed), "Open offered or Update… disabled")
        try expect(controller.updatableRows.isEmpty && controller.updateAllCount == 0, "routed row counted for Update All: \(controller.updatableRows.map(\.name))")
        try expect(controller.menuUpdates().rows.first { $0.name == "Google Chrome" }?.note == "Needs admin", "menu note")
        // Update All again still never reaches it (automatic runs pick from `updatableRows` only; see the automatic checks).
        await runOperation(controller) { controller.updateAll() }
        try expect(adminEvents(installer).isEmpty, "Update All passed consent: \(adminEvents(installer))")
        // The mark survives a new check, and the one click passes consent.
        await runCheck(controller)
        try expect(row("Google Chrome").updateActionTitle == "Update…", "mark lost after a check")
        await runOperation(controller) { controller.update(id: chrome.path) }
        try expect(adminEvents(installer) == ["admin-update Google Chrome"], "click did not pass consent: \(installer.recorder.events)")
        try expect(row("Google Chrome").result?.text.contains("developer's package") == true, "result: \(String(describing: row("Google Chrome").result))")
    }

    check("needs admin help: a needs-admin row with no package route shows the one-time fix; Chrome with packages off falls back too") {
        let other = app("Admin"), chrome = chromeApp()
        for packagesOn in [true, false] {
            let installer = FakeInstaller()
            installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("owned by uid 0") }
            let controller = makeController(outcomes: [outcome(other, .updateAvailable(offer("2.0"))), chromeOutcome(chrome, .updateAvailable(offer("2.0")))],
                                            installer: installer, packageUpdates: packagesOn)
            await runCheck(controller)
            await runOperation(controller) { controller.updateAll() }
            @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
            let help = "Patched can't replace apps owned by the system. Replacing it once with a copy downloaded from the developer lets Patched update it without a password."
            try expect(row("Admin").needsManualAdmin && row("Admin").adminHelpText == help, "Admin help (pkg \(packagesOn)): \(String(describing: row("Admin").adminHelpText))")
            try expect(controller.canOpenApp(row("Admin")) && row("Admin").kindNote == "Needs admin", "Admin row")
            if packagesOn {
                try expect(row("Google Chrome").privilege == .vendorPackage && row("Google Chrome").adminHelpText != help, "Chrome routed")
            } else {
                try expect(row("Google Chrome").needsManualAdmin && row("Google Chrome").adminHelpText == help
                           && row("Google Chrome").updateActionTitle == "Update", "Chrome with packages off: \(row("Google Chrome"))")
            }
            try expect(adminEvents(installer).isEmpty, "consent passed")
        }
        // A plain update or an up-to-date row has no help line.
        let controller = makeController(outcomes: [outcome(app("Plain"), .updateAvailable(offer("2.0"))), outcome(app("Done"), .upToDate)])
        await runCheck(controller)
        try expect(controller.rows.allSatisfy { $0.adminHelpText == nil }, "help on an ordinary row")
    }

    check("vendor pkg row: Chrome anywhere but the package's install path, or signed by another team, is Needs admin with the one-time fix") {
        let elsewhere = chromeApp(path: "/Users/Shared/Google Chrome.app"), copy = chromeApp(path: "/Applications/Tools/Google Chrome.app")
        for (candidate, team) in [(elsewhere, "EQHXZ8M8AV"), (copy, "EQHXZ8M8AV"), (chromeApp(), "AAAAAAAAAA")] {
            let installer = FakeInstaller()
            installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("owned by uid 0") }
            let controller = makeController(outcomes: [chromeOutcome(candidate, .updateAvailable(offer("2.0")), team: team)],
                                            installer: installer, packageUpdates: true)
            await runCheck(controller)
            await runOperation(controller) { controller.update(id: candidate.path) }
            let row = controller.rows[0]
            try expect(row.privilege == .standard && row.needsManualAdmin && row.adminHelpText == AppUpdateRow.needsAdminHelp,
                       "\(candidate.path) team \(team) routed: \(row)")
            try expect(adminEvents(installer).isEmpty, "consent passed")
        }
    }

    check("early admin test: root-owned apps are marked straight after the check, with no install attempt") {
        let chrome = chromeApp(), unrouted = app("Rooted"), mine = app("Mine")
        let installer = FakeInstaller()
        let rootOwned: Set<String> = [chrome.path, unrouted.path]
        let cask = UpdateSource.homebrewCask(token: "google-chrome")
        let controller = makeController(outcomes: [chromeOutcome(chrome, .updateAvailable(offer("2.0", source: cask)), source: cask),
                                                   outcome(unrouted, .updateAvailable(offer("2.0"))),
                                                   outcome(mine, .updateAvailable(offer("2.0")))],
                                        installer: installer, packageUpdates: true, likelyNeedsAdmin: { rootOwned.contains($0) })
        await runCheck(controller)
        @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
        try expect(row("Google Chrome").privilege == .vendorPackage && row("Google Chrome").updateActionTitle == "Update…"
                   && !row("Google Chrome").needsManualAdmin, "chrome: \(row("Google Chrome"))")
        try expect(row("Rooted").privilege == .standard && row("Rooted").needsManualAdmin
                   && row("Rooted").adminHelpText == AppUpdateRow.needsAdminHelp, "unrouted: \(row("Rooted"))")
        try expect(row("Mine").privilege == .standard && !row("Mine").needsManualAdmin && row("Mine").adminHelpText == nil, "user-owned changed")
        try expect(controller.updateAllCount == 1 && controller.updatableRows.map(\.name) == ["Mine"],
                   "update all: \(controller.updateAllCount) \(controller.updatableRows.map(\.name))")
        try expect(!installer.recorder.events.contains { $0.hasPrefix("update") || $0.hasPrefix("admin") }, "install attempted: \(installer.recorder.events)")
    }

    check("early admin test: ownership fixed clears the early mark on the next check; a refusal-learned mark stays") {
        let early = app("Early"), refused = app("Refused")
        let installer = FakeInstaller()
        installer.updateHandler = { outcome, _ in
            if outcome.app.name == "Refused" { throw InstallRefusal.needsAdmin("owned by uid 0") }
            return AppUpdateReport(status: "installed", fromVersion: "1.0", toVersion: "2.0", backupFolder: "/b")
        }
        let box = AdminBox([early.path])
        let controller = makeController(outcomes: [outcome(early, .updateAvailable(offer("2.0"))), outcome(refused, .updateAvailable(offer("2.0")))],
                                        installer: installer, likelyNeedsAdmin: { box.contains($0) })
        await runCheck(controller)
        @MainActor func row(_ name: String) -> AppUpdateRow { controller.rows.first { $0.name == name }! }
        try expect(row("Early").needsManualAdmin && !row("Refused").needsManualAdmin, "before")
        await runOperation(controller) { controller.update(id: refused.path) }
        try expect(row("Refused").needsManualAdmin, "refusal not learned")
        box.set([])
        await runCheck(controller)
        try expect(!row("Early").needsManualAdmin && row("Early").privilege == .standard && row("Early").adminHelpText == nil, "stale mark: \(row("Early"))")
        try expect(row("Refused").needsManualAdmin, "refusal-learned mark dropped")
        try expect(controller.updatableRows.map(\.name) == ["Early"], "update all: \(controller.updatableRows.map(\.name))")
    }

    check("vendor pkg row: a pkg offer for a listed app stays Update (installer); the route only replaces zip and dmg downloads") {
        let chrome = chromeApp()
        let installer = FakeInstaller()
        installer.updateHandler = { _, _ in throw InstallRefusal.needsAdmin("owned by uid 0") }
        let controller = makeController(outcomes: [chromeOutcome(chrome, .updateAvailable(offer("2.0", format: .pkg)))], installer: installer, packageUpdates: true)
        await runCheck(controller)
        try expect(controller.rows[0].privilege == .installer && controller.rows[0].updateActionTitle == "Update (installer)", "\(controller.rows[0])")
    }

    check("source guard: only a user click or the typed CLI command can create admin consent") {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String]) ?? []
        try expect(files.count > 10, "source tree not found")
        var makers: [String] = []
        for relative in files where relative.hasSuffix(".swift") {
            let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
            if text.contains("AdminInteraction(") { makers.append(relative) }
        }
        try expect(makers.sorted() == ["PatchedClient/AppUpdatesController.swift", "UpdateInstaller/CommandLineConsent.swift"], "consent created in \(makers.sorted())")
        // The CLI decides consent only through CommandLineUpdates, and its --all loop asks for the batch scope.
        let cli = try String(contentsOfFile: sources.path + "/PatchedCLI/main.swift", encoding: .utf8)
        try expect(cli.contains("install(outcome, installer: installer, scope: .all)") && !cli.contains("admin: "), "CLI bypasses CommandLineUpdates")
        // The scheduler holds the controller and checks. Its one install path is the gated automatic Update All
        // (see the Update All source guard), which never passes consent, so no admin word may appear here.
        for relative in ["PatchedClient/BackgroundUpdateChecks.swift"] {
            let text = try String(contentsOfFile: sources.path + "/" + relative, encoding: .utf8)
            for forbidden in ["AdminInteraction", "AdminUpdatePath", "admin:", ".update(id", "rollBack(", "finishInstaller", ".recover()"] {
                try expect(!text.contains(forbidden), "\(relative) mentions \(forbidden)")
            }
        }
        // In the controller, Update All passes `admin: false`.
        let controller = try String(contentsOfFile: sources.path + "/PatchedClient/AppUpdatesController.swift", encoding: .utf8)
        try expect(controller.contains("performUpdate(path: path, quit: false, interactive: false, admin: false, onlyKeys: keys)"), "Update All may pass consent")
    }
}
