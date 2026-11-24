import AppKit
import SwiftUI

enum Period: String, CaseIterable, Identifiable {
    case today, week, month
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        }
    }

    func range(now: Date = Date()) -> Range<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today)! }
        switch self {
        case .today: return today..<now
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
    // Ties go by name, so equal rows don't swap places between reloads
    .sorted { ($0.name == nil ? 1 : 0, -$0.seconds, -$0.agentSeconds, $0.id) < ($1.name == nil ? 1 : 0, -$1.seconds, -$1.agentSeconds, $1.id) }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(localized: "Under 1 min") }
    return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

@MainActor private var appIcons: [String: NSImage] = [:]

/// Looked up once per app, since views ask again on every redraw
@MainActor
func appIcon(_ bundle: String) -> NSImage {
    if let icon = appIcons[bundle] { return icon }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    appIcons[bundle] = icon
    return icon
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
