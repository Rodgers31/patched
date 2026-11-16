import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchedShell

private typealias HistoryState<Value> = State<Value>

// The History screen: the local record of update runs, newest first and grouped by day. Read-only: nothing here
// installs, rolls back or checks anything.

/// Words and grouping for the History screen and the menu's last-run line. Pure, so it can be checked without a view.
@_spi(Testing) public enum HistoryModel {
    /// One app across the history: its bundle ID, or its name when it has none.
    public struct AppChoice: Hashable, Identifiable, Sendable {
        public let key: String
        public let name: String
        public var id: String { key }
    }

    public static func key(_ item: HistoryItem) -> String { item.bundleID ?? "name:" + item.name }

    /// Every app that appears in the history, by name.
    public static func apps(_ runs: [HistoryRun]) -> [AppChoice] {
        var seen: [String: String] = [:]
        for run in runs { for item in run.items where seen[key(item)] == nil { seen[key(item)] = item.name } }
        return seen.map { AppChoice(key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The runs to show. Failures only keeps runs with a failure and, inside them, only the failed apps. One app
    /// keeps the runs that included it and, inside them, only that app.
    public static func visibleRuns(_ runs: [HistoryRun], failuresOnly: Bool, app: String?) -> [HistoryRun] {
        runs.compactMap { run in
            var items = run.items
            if failuresOnly { items = items.filter { $0.result == .failed } }
            if let app { items = items.filter { key($0) == app } }
            if (failuresOnly || app != nil) && items.isEmpty { return nil }
            return HistoryRun(id: run.id, startedAt: run.startedAt, finishedAt: run.finishedAt, trigger: run.trigger,
                              appsChecked: run.appsChecked, updatesFound: run.updatesFound, outcome: run.outcome,
                              note: run.note, items: items)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public struct Day: Identifiable, Equatable, Sendable {
        public let start: Date
        public let runs: [HistoryRun]
        public var id: Date { start }
    }

    /// Runs grouped by calendar day, newest day first and newest run first within each day.
    public static func days(_ runs: [HistoryRun], calendar: Calendar = .current) -> [Day] {
        let grouped = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            Day(start: day, runs: grouped[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    /// "Today", "Yesterday", or the full date.
    public static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full; formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    public static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "today 03:00", "yesterday 03:00", or a short date and time.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let clock = time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today \(clock)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday \(clock)")
        }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The menu's line: "Last run: today 03:00, 3 updated".
    public static func lastRunLine(_ run: HistoryRun, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        String(localized: "Last run: \(when(run.startedAt, now: now, calendar: calendar, locale: locale)), \(menuSummary(run))")
    }

    /// The summary with a lower-case first letter, to follow a comma.
    static func menuSummary(_ run: HistoryRun) -> String {
        let text = run.summary
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// What VoiceOver reads for a run's heading.
    public static func accessibilityLabel(_ run: HistoryRun, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let failed = run.hasFailures ? String(localized: "Something failed. ") : ""
        let apps = appsLine(run).map { ". " + $0 } ?? ""
        return failed + String(localized: "\(time(run.startedAt, calendar: calendar, locale: locale)), \(run.triggerText): \(run.summary)") + apps
    }

    /// "1.0 → 2.0", or the one version known. nil when neither is.
    public static func versions(_ item: HistoryItem) -> String? {
        switch (item.oldVersion, item.newVersion) {
        case let (old?, new?) where old != new: return "\(old) → \(new)"
        case let (old?, _): return old
        case let (nil, new?): return new
        default: return nil
        }
    }

    /// The apps in a run, shown under its summary so they can be seen without opening it. One app gets its
    /// versions ("DuckDuckGo 1.215.1 → 1.216.0"); several are named, updated ones first, up to three and a count.
    public static func appsLine(_ run: HistoryRun) -> String? {
        if run.items.count == 1, let item = run.items.first {
            return versions(item).map { "\(item.name) \($0)" } ?? item.name
        }
        let names = (run.items.filter { $0.result == .updated } + run.items.filter { $0.result != .updated }).map(\.name)
        switch names.count {
        case 0: return nil
        case 2...3: return names.dropLast().joined(separator: ", ") + String(localized: " and ") + names[names.count - 1]
        case 4...: return names.prefix(3).joined(separator: ", ") + String(localized: " and \(names.count - 3) more")
        default: return names[0]
        }
    }
}

/// What the History screen shows: the runs read from the store, and a run the menu or a notification asked to open.
@MainActor public final class HistoryController: ObservableObject {
    @Published public private(set) var runs: [HistoryRun] = []
    /// A run to expand and scroll to. Cleared by the view once shown.
    @Published public var focusedRunID: UUID?
    /// Bumped on every request, so asking for the same run again still scrolls to it.
    @Published public private(set) var focusRequest = 0
    /// The runs shown open, with their apps listed.
    @Published public var expanded: Set<UUID> = []
    private let store: () -> (any HistoryStoring)?

    public init(store: @escaping () -> (any HistoryStoring)?) { self.store = store }

    /// Reads the store again. The view calls this when it appears and whenever a new run is recorded.
    public func reload() { runs = store()?.runs() ?? [] }

    /// Opens a run and asks the view to scroll to it.
    public func focus(runID: UUID) {
        expanded.insert(runID)
        focusedRunID = runID
        focusRequest &+= 1
    }
}

extension NativeClientSession {
    /// The menu's last-run line and a notification after an automatic run: open History at that run. A run that
    /// has since been pruned leaves History showing the list.
    @discardableResult public func showHistory(runID: UUID?) -> Bool {
        navigation.select(.history)
        history.reload()
        if let runID { history.focus(runID: runID) }
        return true
    }
}

/// The History screen.
public struct HistoryView: View {
    @ObservedObject private var history: HistoryController
    @ObservedObject private var updates: AppUpdatesController
    @HistoryState private var failuresOnly = false
    @HistoryState private var app: String?
    @HistoryState private var exportShown = false
    @HistoryState private var exportLimited = false
    @HistoryState private var exportFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @HistoryState private var exportTo = Date()
    @HistoryState private var exportNotice: String?

    public init(history: HistoryController, updates: AppUpdatesController) {
        self.history = history
        self.updates = updates
    }

    private var visible: [HistoryRun] { HistoryModel.visibleRuns(history.runs, failuresOnly: failuresOnly, app: app) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            Divider()
            if visible.isEmpty { emptyState } else { list }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { history.reload() }
        .onReceive(updates.$lastRun) { _ in history.reload() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: subtitle).font(.body).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let exportNotice { Text(verbatim: exportNotice).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Button(action: { exportShown = true }) { Text("Export CSV…") }
                .buttonStyle(.bordered)
                .disabled(history.runs.isEmpty)
                .help(Text("Saves the history as a CSV file where you choose"))
                .accessibilityHint(Text("Choose an optional date range, then where to save the file"))
                .popover(isPresented: $exportShown, arrowEdge: .bottom) { exportOptions }
        }
        .frame(minHeight: 28)
    }

    /// The optional date range, then Export…, which opens the save panel. Nothing is written until a file is chosen.
    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export history").font(.headline)
            Toggle(isOn: $exportLimited) { Text("Only runs between these dates") }
                .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                DatePicker(selection: $exportFrom, displayedComponents: .date) { Text("From") }
                DatePicker(selection: $exportTo, displayedComponents: .date) { Text("To") }
            }
            .disabled(!exportLimited)
            Text("The file stays wherever you save it. Patched sends it nowhere.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button(action: { exportShown = false }) { Text("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button(action: export) { Text("Export…") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Runs only from the Export… button: builds the CSV, asks where to save it, and writes it there.
    private func export() {
        exportShown = false
        let from = exportLimited ? min(exportFrom, exportTo) : nil
        let to = exportLimited ? max(exportFrom, exportTo) : nil
        let runs = HistoryCSV.runs(history.runs, from: from, to: to)
        // A byte order mark, so spreadsheet apps read non-ASCII app names as UTF-8.
        let data = Data(("\u{FEFF}" + HistoryCSV.text(runs)).utf8)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "Patched update history.csv")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                exportNotice = runs.count == 1 ? String(localized: "Exported 1 run") : String(localized: "Exported \(runs.count) runs")
            } catch {
                exportNotice = String(localized: "Couldn't save the file: \(error.localizedDescription)")
            }
        }
    }

    private var subtitle: String {
        let count = history.runs.count
        let runs = count == 1 ? String(localized: "1 update run") : String(localized: "\(count) update runs")
        return String(localized: "\(runs), kept on this Mac for 90 days")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $failuresOnly) { Text("Failures only") }
                .toggleStyle(.checkbox)
            Picker(selection: $app) {
                Text("All apps").tag(String?.none)
                ForEach(HistoryModel.apps(history.runs)) { choice in
                    Text(verbatim: choice.name).tag(Optional(choice.key))
                }
            } label: { Text("App") }
            .frame(maxWidth: 260)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 6) {
            Text(history.runs.isEmpty ? "No update runs yet" : "No matching runs").font(.headline)
            Text(history.runs.isEmpty ? "Each update, including scheduled runs that find nothing to do, is listed here."
                                      : "Try turning off Failures only or choosing All apps.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(HistoryModel.days(visible)) { day in
                        Text(verbatim: HistoryModel.dayTitle(day.start)).font(.headline)
                            .padding(.top, 14).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.runs) { run in
                            HistoryRunRow(run: run, isExpanded: binding(run.id))
                                .id(run.id)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { showFocused(proxy) }
            .onReceive(history.$focusRequest) { _ in showFocused(proxy) }
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { history.expanded.contains(id) },
                set: { open in if open { history.expanded.insert(id) } else { history.expanded.remove(id) } })
    }

    /// Expands and scrolls to the run the menu or a notification asked for. Filters are cleared so it is listed.
    private func showFocused(_ proxy: ScrollViewProxy) {
        guard let id = history.focusedRunID else { return }
        history.focusedRunID = nil
        guard history.runs.contains(where: { $0.id == id }) else { return }
        failuresOnly = false; app = nil
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .top) } }
    }
}

private struct HistoryRunRow: View {
    let run: HistoryRun
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if run.items.isEmpty {
                    Text(verbatim: run.note ?? run.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(run.items.enumerated()), id: \.offset) { _, item in
                        HistoryItemRow(item: item)
                    }
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: Self.symbol(run)).foregroundStyle(Self.colour(run))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: HistoryModel.time(run.startedAt)).font(.body).monospacedDigit()
                    .frame(minWidth: 52, alignment: .leading)
                Text(verbatim: run.triggerText).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).frame(minWidth: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: run.summary).font(.body).lineLimit(2).truncationMode(.tail)
                    if let apps = HistoryModel.appsLine(run) {
                        Text(verbatim: apps).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: HistoryModel.accessibilityLabel(run)))
            .accessibilityHint(Text(isExpanded ? "Hides the apps in this run" : "Shows the apps in this run"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isExpanded.toggle() }
        }
        .padding(.vertical, 6)
    }

    static func symbol(_ run: HistoryRun) -> String {
        switch run.outcome {
        case .updated: return "checkmark.circle.fill"
        case .upToDate: return "checkmark.circle"
        case .partial, .failed: return "exclamationmark.triangle.fill"
        case .deferred: return "clock"
        case .nothingInstalled: return "minus.circle"
        }
    }

    static func colour(_ run: HistoryRun) -> Color {
        switch run.outcome {
        case .updated, .upToDate: return .green
        case .partial, .failed: return .orange
        case .deferred, .nothingInstalled: return .secondary
        }
    }
}

private struct HistoryItemRow: View {
    let item: HistoryItem

    private var versions: String? { HistoryModel.versions(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: item.name).font(.headline).lineLimit(1).truncationMode(.tail)
                if let versions { Text(verbatim: versions).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(verbatim: item.resultText).font(.callout)
                    .foregroundStyle(item.result == .failed ? Color.orange : (item.result == .updated ? BrandAccent.color : Color.secondary))
            }
            if let reason = item.reason {
                Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let detail = item.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
