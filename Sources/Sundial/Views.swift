import AppKit
import SwiftUI

enum Period: String, CaseIterable, Identifiable {
    case today, yesterday, week, month
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .yesterday: "sun.horizon"
        case .week: "calendar"
        case .month: "calendar.badge.clock"
        }
    }

    func range(now: Date = Date()) -> Range<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today)! }
        switch self {
        case .today: return today..<now
        case .yesterday: return daysAgo(1)..<today
        case .week: return daysAgo(6)..<now
        case .month: return daysAgo(29)..<now
        }
    }
}

struct Share: Identifiable {
    let id: String
    let name: String
    let bundle: String
    let seconds: TimeInterval
}

/// Time on one project, or on everything outside a project when `name` is nil
struct ProjectSummary: Identifiable {
    let id: String
    let name: String?
    let seconds: TimeInterval
    let apps: [Share]
    let details: [Share]
}

/// Projects are matched without regard to case, so the GitHub repository "rejoin" joins the local folder "Rejoin"
func summarize(_ spans: [Span], in range: Range<Date>) -> [ProjectSummary] {
    var groups: [String: [Span]] = [:]
    for span in spans where span.seconds(in: range) > 0 {
        groups[span.project?.lowercased() ?? "", default: []].append(span)
    }
    func shares(_ spans: [Span], key: (Span) -> (id: String, name: String)?) -> [Share] {
        var seconds: [String: (name: String, bundle: String, seconds: TimeInterval)] = [:]
        for span in spans {
            guard let k = key(span) else { continue }
            seconds[k.id, default: (k.name, span.bundle, 0)].seconds += span.seconds(in: range)
        }
        return seconds.map { Share(id: $0.key, name: $0.value.name, bundle: $0.value.bundle, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }
    return groups.map { key, spans in
        // The spelling that got the most time names the project
        let name = shares(spans) { $0.project.map { ($0, $0) } }.first?.name
        return ProjectSummary(
            id: key, name: key.isEmpty ? nil : name,
            seconds: spans.reduce(0) { $0 + $1.seconds(in: range) },
            apps: shares(spans) { ($0.bundle, $0.app) },
            details: shares(spans) { span in span.detail.map { (span.bundle + "\n" + $0, $0) } })
    }
    .sorted { ($0.name == nil ? 1 : 0, -$0.seconds) < ($1.name == nil ? 1 : 0, -$1.seconds) }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(localized: "Under 1 min") }
    return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

func appIcon(_ bundle: String) -> NSImage {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
    return NSWorkspace.shared.icon(forFile: url.path)
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var recorder: Recorder
    @State private var period: Period? = .today
    @State private var selection: String?
    @State private var totals: [Period: TimeInterval] = [:]
    @State private var projects: [ProjectSummary] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $period) {
                ForEach(Period.allCases) { p in
                    Label(p.title, systemImage: p.symbol)
                        .badge(Text(totals[p].map(formatDuration) ?? ""))
                        .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            projectList
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let project = projects.first(where: { $0.id == selection }) {
                ProjectDetail(project: project)
            } else {
                ContentUnavailableView("Select a Project", systemImage: "folder")
            }
        }
        .toolbar {
            if !recorder.hasAccessibility {
                Button { recorder.requestAccessibility() } label: {
                    Label("Allow Accessibility", systemImage: "exclamationmark.triangle")
                }
                .help("Sundial needs Accessibility access to see which file CotEditor and Markdown Preview have open.")
            }
            Button { recorder.paused.toggle() } label: {
                recorder.paused
                    ? Label("Resume Recording", systemImage: "record.circle")
                    : Label("Pause Recording", systemImage: "pause.circle")
            }
            .help(recorder.paused ? "Resume Recording" : "Pause Recording")
        }
        .task(id: store.revision) { reload() }
        .onChange(of: period) { reload() }
    }

    private var projectList: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name ?? String(localized: "No Project"))
                            .font(.headline)
                            .foregroundStyle(project.name == nil ? .secondary : .primary)
                        Spacer()
                        Text(formatDuration(project.seconds))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(project.apps.prefix(3).map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(project.id)
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "sun.max",
                                       description: Text(recorder.paused ? "Recording is paused." : "Time you spend in apps shows up here."))
            }
        }
        .navigationTitle(period?.title ?? "Sundial")
        .navigationSubtitle(period.flatMap { totals[$0] }.map(formatDuration) ?? "")
    }

    private func reload() {
        let now = Date()
        let month = Period.month.range(now: now)
        let spans = store.spans(in: month)
        totals = Dictionary(uniqueKeysWithValues: Period.allCases.map { p in
            let range = p.range(now: now)
            return (p, spans.reduce(0) { $0 + $1.seconds(in: range) })
        })
        projects = summarize(spans, in: (period ?? .today).range(now: now))
        if selection == nil || !projects.contains(where: { $0.id == selection }) {
            selection = projects.first?.id
        }
    }
}

struct ProjectDetail: View {
    let project: ProjectSummary

    var body: some View {
        List {
            Section("Apps") {
                ForEach(project.apps) { app in
                    ShareRow(share: app, total: project.seconds) {
                        Image(nsImage: appIcon(app.bundle)).resizable().frame(width: 20, height: 20)
                    }
                }
            }
            if !project.details.isEmpty {
                Section(project.name == nil ? "Windows" : "Files, Folders and Pages") {
                    ForEach(project.details.prefix(50)) { detail in
                        ShareRow(share: detail, total: project.seconds) {
                            Image(nsImage: appIcon(detail.bundle)).resizable().frame(width: 16, height: 16)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(project.name ?? String(localized: "No Project"))
        .navigationSubtitle(formatDuration(project.seconds))
    }
}

struct ShareRow<Icon: View>: View {
    let share: Share
    let total: TimeInterval
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(share.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(formatDuration(share.seconds))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: total > 0 ? share.seconds / total : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
    }
}
