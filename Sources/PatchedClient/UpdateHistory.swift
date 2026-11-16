import Foundation
import Darwin
import UpdateSources
import UpdateInstaller

// The local update history: what each update run did, kept in one file on this Mac. Nothing in it is ever sent
// anywhere. Recording never changes what an update does: a store that cannot read or write simply records nothing.

/// One update run: a scheduled (automatic) run, an Update All, one app's update, or `patched update` on the
/// command line. A scheduled run that found nothing to install, or that had to wait, is a run too.
public struct HistoryRun: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        case scheduled, updateAll, singleApp, commandLine
    }
    public enum Outcome: String, Codable, Sendable {
        /// Nothing to install: every app checked was up to date.
        case upToDate
        /// Every app attempted was updated.
        case updated
        /// Some apps were updated and some failed.
        case partial
        /// Nothing was updated and at least one app failed.
        case failed
        /// Nothing was updated and nothing failed: apps were open, needed admin rights, had changed, or were cancelled.
        case nothingInstalled
        /// A scheduled run that had to wait (see `note`).
        case deferred
    }

    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let trigger: Trigger
    public let appsChecked: Int
    public let updatesFound: Int
    public let outcome: Outcome
    /// Why a scheduled run waited, or what else happened (the App Store was opened). Plain English.
    public let note: String?
    public let items: [HistoryItem]

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date, trigger: Trigger, appsChecked: Int, updatesFound: Int,
                outcome: Outcome? = nil, note: String? = nil, items: [HistoryItem]) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt; self.trigger = trigger
        self.appsChecked = appsChecked; self.updatesFound = updatesFound
        self.items = Array(items.prefix(HistoryRetention.maxItemsPerRun))
        self.note = note.map { HistoryItem.bounded($0, HistoryItem.maxReasonLength) }
        self.outcome = outcome ?? Self.outcome(for: items, updatesFound: updatesFound)
    }

    static func outcome(for items: [HistoryItem], updatesFound: Int) -> Outcome {
        if items.isEmpty { return updatesFound == 0 ? .upToDate : .nothingInstalled }
        let updated = items.filter { $0.result == .updated }.count
        let failed = items.filter { $0.result == .failed }.count
        if updated == items.count { return .updated }
        if updated > 0 { return failed > 0 ? .partial : .updated }
        return failed > 0 ? .failed : .nothingInstalled
    }

    public var hasFailures: Bool { items.contains { $0.result == .failed } }
    public func count(_ result: HistoryItem.Result) -> Int { items.filter { $0.result == result }.count }

    /// "3 updated, 1 failed", "Checked 12 apps, all up to date", "Waited: ...".
    public var summary: String {
        switch outcome {
        case .deferred:
            return note.map { String(localized: "Waited: \($0)") } ?? String(localized: "Waited")
        case .upToDate:
            let checked = appsChecked == 1 ? String(localized: "Checked 1 app, all up to date")
                                           : String(localized: "Checked \(appsChecked) apps, all up to date")
            return note.map { checked + ", " + $0 } ?? checked
        default:
            var parts: [String] = []
            let updated = count(.updated), failed = count(.failed), open = count(.skippedOpen)
            let admin = count(.needsAdmin), changed = count(.changed), cancelled = count(.cancelled)
            if updated > 0 || items.isEmpty { parts.append(String(localized: "\(updated) updated")) }
            if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
            if open > 0 { parts.append(String(localized: "\(open) skipped because open")) }
            if admin > 0 { parts.append(admin == 1 ? String(localized: "1 needs admin") : String(localized: "\(admin) need admin")) }
            if changed > 0 { parts.append(String(localized: "\(changed) changed, not installed")) }
            if cancelled > 0 { parts.append(String(localized: "\(cancelled) cancelled")) }
            if items.isEmpty, updatesFound > 0, note == nil {
                parts = [updatesFound == 1 ? String(localized: "1 update found, none installed automatically")
                                           : String(localized: "\(updatesFound) updates found, none installed automatically")]
            }
            if let note { parts.append(note) }
            return parts.joined(separator: ", ")
        }
    }

    public var triggerText: String {
        switch trigger {
        case .scheduled: return String(localized: "Scheduled")
        case .updateAll: return String(localized: "Update All")
        case .singleApp: return String(localized: "Single app")
        case .commandLine: return String(localized: "Command line")
        }
    }
}

/// What happened to one app in a run.
public struct HistoryItem: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable, CaseIterable {
        case updated, failed, skippedOpen, needsAdmin, changed, cancelled
    }
    static let maxReasonLength = 600
    static let maxDetailLength = 400

    public let name: String
    public let bundleID: String?
    public let oldVersion: String?
    public let newVersion: String?
    public let result: Result
    /// The same plain-English line the Updates screen showed, from `OutcomeText` or `PlainRefusalText`.
    public let reason: String?
    /// A short technical detail, such as a refusal code, when there is one.
    public let detail: String?

    public init(name: String, bundleID: String?, oldVersion: String?, newVersion: String?, result: Result,
                reason: String?, detail: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.oldVersion = oldVersion; self.newVersion = newVersion
        self.result = result
        self.reason = reason.map { Self.bounded($0, Self.maxReasonLength) }
        self.detail = detail.map { Self.bounded($0, Self.maxDetailLength) }
    }

    static func bounded(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    public var resultText: String {
        switch result {
        case .updated: return String(localized: "Updated")
        case .failed: return String(localized: "Failed")
        case .skippedOpen: return String(localized: "Skipped, app open")
        case .needsAdmin: return String(localized: "Needs admin")
        case .changed: return String(localized: "Changed, not installed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

/// Keep 90 days or the last 500 runs, whichever is smaller.
public enum HistoryRetention {
    public static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    public static let maxRuns = 500
    /// A bound on one run's size, so the file stays small enough to read in one go.
    public static let maxItemsPerRun = 300

    /// Newest first, within 90 days of `now`, at most 500. A run stamped in the future (a clock set back) is kept.
    public static func apply(_ runs: [HistoryRun], now: Date) -> [HistoryRun] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let kept = runs.filter { $0.startedAt >= cutoff }.sorted { $0.startedAt > $1.startedAt }
        return Array(kept.prefix(maxRuns))
    }
}

/// Where the history is kept. Implementations never throw to the caller: a failed read is an empty history and a
/// failed write records nothing.
@MainActor public protocol HistoryStoring: AnyObject {
    /// Every kept run, newest first.
    func runs() -> [HistoryRun]
    func record(_ run: HistoryRun)
    /// Applies `HistoryRetention`. Called when the app launches.
    func prune(now: Date)
}

/// In memory only: checks, fixtures, and any run under the test tripwire.
@MainActor public final class MemoryHistoryStore: HistoryStoring {
    private var stored: [HistoryRun] = []
    public init(runs: [HistoryRun] = []) { stored = runs }
    public func runs() -> [HistoryRun] { stored.sorted { $0.startedAt > $1.startedAt } }
    public func record(_ run: HistoryRun) {
        stored.append(run)
        stored = Array(runs().prefix(HistoryRetention.maxRuns))
    }
    public func prune(now: Date) { stored = HistoryRetention.apply(stored, now: now) }
}

/// `history.json` in `~/Library/Application Support/Patched` (or a folder given by the caller). The app and the
/// command line both write it, so every change re-reads the file under a lock and replaces it atomically (a 0600
/// temporary file, fsync, rename). A file that cannot be decoded is moved aside rather than overwritten.
@MainActor public final class FileHistoryStore: HistoryStoring {
    public static let fileName = "history.json"
    nonisolated static let readLimit = 16 * 1024 * 1024
    private struct File: Codable { var version: Int; var runs: [HistoryRun] }

    private let folder: () -> String?
    private let memory = MemoryHistoryStore()
    private let useMemory: Bool

    /// `folder` is resolved on first use, never at construction. Returning nil records nothing.
    public init(folder: @escaping () -> String?) {
        self.folder = folder
        useMemory = false
    }

    /// The real location. Under the test tripwire everything stays in memory, as the other default stores do.
    public static func standard() -> FileHistoryStore {
        FileHistoryStore(standardFolder: { try? InstallerLocations.patchedSupportFolder() })
    }
    private init(standardFolder: @escaping () -> String?) {
        folder = standardFolder
        useMemory = RealStateTripwire.isActive
    }

    public var path: String? { folder().map { $0 + "/" + Self.fileName } }

    public func runs() -> [HistoryRun] {
        if useMemory { return memory.runs() }
        guard let path else { return [] }
        return (try? Self.read(path))?.sorted { $0.startedAt > $1.startedAt } ?? []
    }

    public func record(_ run: HistoryRun) {
        if useMemory { memory.record(run); return }
        change { runs in
            runs.removeAll { $0.id == run.id }
            runs.append(run)
            runs = Array(runs.sorted { $0.startedAt > $1.startedAt }.prefix(HistoryRetention.maxRuns))
        }
    }

    public func prune(now: Date) {
        if useMemory { memory.prune(now: now); return }
        change { runs in runs = HistoryRetention.apply(runs, now: now) }
    }

    /// Reads, changes and writes the file under an exclusive lock. Any failure leaves the file as it was.
    private func change(_ edit: (inout [HistoryRun]) -> Void) {
        guard let folder = folder(), let path else { return }
        do {
            try Self.makeFolder(folder)
            let lockPath = folder + "/.history.lock"
            let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { return }
            defer { flock(lock, LOCK_UN); close(lock) }
            // Never wait long on the main actor: another writer holds the lock for milliseconds, so try for up to a
            // second and then record nothing rather than freeze the window.
            var locked = false
            for _ in 0..<20 {
                if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                usleep(50_000)
            }
            guard locked else { return }
            var runs: [HistoryRun]
            do { runs = try Self.read(path) ?? [] }
            catch is NewerHistory {
                // Written by a newer Patched: leave it exactly as it is and record nothing.
                return
            } catch {
                // Never overwrite a history we could not read: keep it beside the new one for inspection.
                let aside = path + ".unreadable-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(8)
                guard rename(path, aside) == 0 else { return }
                runs = []
            }
            let before = runs
            edit(&runs)
            guard runs != before else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(Self.dateFormatter().string(from: date))
            }
            encoder.outputFormatting = [.sortedKeys]
            try FileSafety.writeAtomically(try encoder.encode(File(version: 1, runs: runs)), to: path)
        } catch {
            return
        }
    }

    /// nil when there is no file yet. Throws when the file is there but is not a history Patched can read.
    nonisolated static func read(_ path: String) throws -> [HistoryRun]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              let data = FileSafety.readSmallFile(path, limit: readLimit) else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter().date(from: text) else { throw CocoaError(.fileReadCorruptFile) }
            return date
        }
        // The version is read on its own first, so a file from a newer Patched (with cases this one does not know)
        // is recognised and left alone instead of being treated as damaged.
        struct Version: Decodable { let version: Int }
        let version = try decoder.decode(Version.self, from: data).version
        guard version <= 1 else { throw NewerHistory() }
        guard version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return try decoder.decode(File.self, from: data).runs
    }

    /// A history written by a newer Patched. Any change to what a run can hold must raise `File.version`.
    struct NewerHistory: Error {}

    /// ISO 8601 in UTC with milliseconds, so a run read back is the run that was written.
    nonisolated static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    nonisolated private static func makeFolder(_ folder: String) throws {
        var info = stat()
        if lstat(folder, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CocoaError(.fileWriteNoPermission) }
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// The history as CSV, for the Export CSV button. Pure: building it reads and writes nothing.
public enum HistoryCSV {
    public static let header = ["Run ID", "Started", "Finished", "Trigger", "Outcome", "Summary", "Apps checked", "Updates found",
                                "App", "Bundle ID", "Old version", "New version", "Result", "Reason", "Detail"]

    /// The runs whose start falls between the first day's start and the last day's end, inclusive. nil: no limit.
    public static func runs(_ runs: [HistoryRun], from: Date?, to: Date?, calendar: Calendar = .current) -> [HistoryRun] {
        let lower = from.map { calendar.startOfDay(for: $0) }
        let upper = to.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return runs.filter { run in
            (lower.map { run.startedAt >= $0 } ?? true) && (upper.map { run.startedAt < $0 } ?? true)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// One line per app, and one line for a run with no apps (an up-to-date or deferred run). Newest run first.
    public static func text(_ runs: [HistoryRun], timeZone: TimeZone = .current) -> String {
        let dates = ISO8601DateFormatter()
        dates.timeZone = timeZone
        dates.formatOptions = [.withInternetDateTime]
        var lines = [header.map(cell).joined(separator: ",")]
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            let common = [run.id.uuidString, dates.string(from: run.startedAt), dates.string(from: run.finishedAt), run.triggerText,
                          run.outcome.rawValue, run.summary, String(run.appsChecked), String(run.updatesFound)]
            let rows: [[String]] = run.items.isEmpty ? [Array(repeating: "", count: 7)] : run.items.map { item in
                [item.name, item.bundleID ?? "", item.oldVersion ?? "", item.newVersion ?? "", item.resultText, item.reason ?? "",
                 item.detail ?? ""]
            }
            for row in rows { lines.append((common + row).map(cell).joined(separator: ",")) }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting. A cell that a spreadsheet would read as a formula (it starts with =, +, -, @, a tab or a
    /// carriage return) is prefixed with an apostrophe, so an app name or message can never run as one.
    @_spi(Testing) public static func cell(_ value: String) -> String {
        var text = value
        // Spreadsheets can skip leading spaces before reading a formula, so look past any whitespace or byte
        // order mark (but not tab or carriage return, which are triggers themselves).
        let triggers = "=+-@\t\r".unicodeScalars
        if let first = text.unicodeScalars.first(where: {
            triggers.contains($0) || !($0.properties.isWhitespace || $0 == "\u{FEFF}")
        }), triggers.contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
