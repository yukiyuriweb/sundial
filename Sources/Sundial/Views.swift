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

    /// Hours for a single day, days for longer periods
    var unit: Calendar.Component { self == .today || self == .yesterday ? .hour : .day }

    /// What the timeline shows: all of today rather than today until now
    func chartDomain(now: Date = Date()) -> Range<Date> {
        let r = range(now: now)
        return r.lowerBound..<Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: r.upperBound.addingTimeInterval(-1))!)
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

/// Time on one project, or on everything outside a project when `name` is nil. `seconds` is your own time in
/// apps; agents' time is kept apart, since agents run while you do other things and alongside each other.
struct ProjectSummary: Identifiable {
    let id: String
    let name: String?
    let seconds: TimeInterval
    let apps: [Share]
    let details: [Share]
    let agentSeconds: TimeInterval
    let agents: [Share]
}

func agentName(_ tool: String) -> String {
    switch tool {
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "antigravity": "Antigravity CLI"
    default: tool
    }
}

/// Projects are matched without regard to case, so the GitHub repository "rejoin" joins the local folder "Rejoin"
func summarize(_ spans: [Span], agents agentSpans: [AgentSpan], in range: Range<Date>) -> [ProjectSummary] {
    var groups: [String: [Span]] = [:]
    for span in spans where span.seconds(in: range) > 0 {
        groups[span.project?.lowercased() ?? "", default: []].append(span)
    }
    var agentGroups: [String: [AgentSpan]] = [:]
    for span in agentSpans where span.seconds(in: range) > 0 {
        agentGroups[span.project?.lowercased() ?? "", default: []].append(span)
    }
    func shares<T>(_ items: [T], seconds: (T) -> TimeInterval, key: (T) -> (id: String, name: String, bundle: String)?) -> [Share] {
        var totals: [String: (name: String, bundle: String, seconds: TimeInterval)] = [:]
        for item in items {
            guard let k = key(item) else { continue }
            totals[k.id, default: (k.name, k.bundle, 0)].seconds += seconds(item)
        }
        return totals.map { Share(id: $0.key, name: $0.value.name, bundle: $0.value.bundle, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }
    let inRange = { (span: Span) in span.seconds(in: range) }
    let agentInRange = { (span: AgentSpan) in span.seconds(in: range) }
    return Set(groups.keys).union(agentGroups.keys).map { key in
        let spans = groups[key] ?? []
        let agentSpans = agentGroups[key] ?? []
        // The spelling that got the most time names the project
        let name = shares(spans, seconds: inRange) { $0.project.map { ($0, $0, "") } }.first?.name
            ?? agentSpans.first?.project
        return ProjectSummary(
            id: key, name: key.isEmpty ? nil : name,
            seconds: spans.reduce(0) { $0 + inRange($1) },
            apps: shares(spans, seconds: inRange) { ($0.bundle, $0.app, $0.bundle) },
            details: shares(spans, seconds: inRange) { span in span.detail.map { (span.bundle + "\n" + $0, $0, span.bundle) } },
            agentSeconds: agentSpans.reduce(0) { $0 + agentInRange($1) },
            agents: shares(agentSpans, seconds: agentInRange) { ($0.tool, agentName($0.tool), "") })
    }
    .sorted { ($0.name == nil ? 1 : 0, -$0.seconds, -$0.agentSeconds) < ($1.name == nil ? 1 : 0, -$1.seconds, -$1.agentSeconds) }
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
    @State private var buckets: [Bucket] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $period) {
                ForEach(Period.allCases) { p in
                    Label(p.title, systemImage: p.symbol)
                        .badge(Text((totals[p] ?? 0) > 0 ? formatDuration(totals[p]!) : ""))
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
            if !buckets.isEmpty, let period {
                let drawn = Set(buckets.map(\.project))
                let all = timelineSeries(projects)
                let series = all.filter(drawn.contains)
                TimelineChart(buckets: buckets, series: series, colors: series.map { timelineColor($0, in: all) },
                              domain: period.chartDomain(), unit: period.unit)
                    .frame(height: 150)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name ?? String(localized: "No Project"))
                            .font(.headline)
                            .foregroundStyle(project.name == nil ? .secondary : .primary)
                        Spacer()
                        // A project only agents worked on has none of your own time to show
                        if project.seconds > 0 {
                            Text(formatDuration(project.seconds))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.apps.prefix(3).map(\.name).joined(separator: ", "))
                            .lineLimit(1)
                        Spacer()
                        if project.agentSeconds > 0 {
                            Label(formatDuration(project.agentSeconds), systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                                .monospacedDigit()
                                .help("Time agents spent working")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        .navigationSubtitle(period.flatMap { totals[$0] }.map { $0 > 0 ? formatDuration($0) : "" } ?? "")
    }

    private func reload() {
        let now = Date()
        let month = Period.month.range(now: now)
        let spans = store.spans(in: month)
        totals = Dictionary(uniqueKeysWithValues: Period.allCases.map { p in
            let range = p.range(now: now)
            return (p, spans.reduce(0) { $0 + $1.seconds(in: range) })
        })
        let current = period ?? .today
        let range = current.range(now: now)
        projects = summarize(spans, agents: store.agentSpans(in: month), in: range)
        buckets = timeline(spans, projects: projects, in: range, unit: current.unit)
        if selection == nil || !projects.contains(where: { $0.id == selection }) {
            selection = projects.first?.id
        }
    }
}

struct ProjectDetail: View {
    let project: ProjectSummary

    var body: some View {
        List {
            if !project.agents.isEmpty {
                Section {
                    ForEach(project.agents) { agent in
                        ShareRow(share: agent, total: project.agentSeconds) {
                            Image(systemName: "sparkles").frame(width: 20, height: 20)
                        }
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("From your prompt until the agent stops. Agents running side by side each count in full.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !project.apps.isEmpty {
                Section("Apps") {
                    ForEach(project.apps) { app in
                        ShareRow(share: app, total: project.seconds) {
                            Image(nsImage: appIcon(app.bundle)).resizable().frame(width: 20, height: 20)
                        }
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
        .navigationSubtitle(project.seconds > 0 ? formatDuration(project.seconds) : "")
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
