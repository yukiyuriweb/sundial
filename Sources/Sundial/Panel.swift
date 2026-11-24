import ServiceManagement
import SwiftUI

/// The menu bar panel: the overview for the last 7 or 30 days in glass cards, as in MemoryLens, laid out as a
/// grid so it fits without scrolling: figures across the top, project shares beside the trends, and the day
/// timeline across the bottom. It is no wider than half a small screen: the panel hangs from the menu bar item
/// and, where it doesn't fit to the right, grows to the left, and the system doesn't pull it back on screen. Clicking a project switches the panel to its breakdown by agent, app and file.
struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var recorder: Recorder
    @AppStorage("overviewPeriod") private var periodRaw = Period.week.rawValue
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var data: OverviewData?
    @State private var summaries: [ProjectSummary] = []
    @State private var rows: [DayRow] = []
    @State private var palette: [String: Color] = [:]
    /// The project shown in detail: its id, or "" for time outside any project
    @State private var selected: String?
    @State private var contentHeight: CGFloat = 400

    private var period: Period { Period(rawValue: periodRaw) == .month ? .month : .week }
    private var dayRange: Range<Date> { day..<Calendar.current.date(byAdding: .day, value: 1, to: day)! }
    /// Tall enough for everything, but never past the screen
    private var maxScrollHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 120 }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                ScrollView {
                    VStack(spacing: 10) {
                        if let selected, let project = summaries.first(where: { $0.id == selected }) {
                            ProjectCard(project: project, period: period) { self.selected = nil }
                        } else {
                            headerCard
                            if let data, !data.shares.isEmpty {
                                // Side by side, stretched to the taller one
                                HStack(alignment: .top, spacing: 10) {
                                    sharesCard(data)
                                    trendsCard(data)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            dayCard
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // Scrolls only on a screen too short for the grid, and never shows a scroller over the cards
                .scrollIndicators(.never)
                .frame(height: min(contentHeight, maxScrollHeight))
                footer
            }
        }
        .padding(12)
        .frame(width: 700)
        .onAppear { model.panelOpen = true }
        .onDisappear { model.panelOpen = false }
        .task(id: store.revision) { reload() }
        .onChange(of: periodRaw) { reload() }
        .onChange(of: day) { reload() }
    }

    private func reload() {
        let now = Date()
        let range = period.range(now: now)
        let spans = store.spans(in: range)
        data = overview(spans, period: period, now: now)
        summaries = summarize(spans, agents: store.agentSpans(in: range), in: range)
        rows = dayRows(store.spans(in: dayRange), day: dayRange)
        // The period's projects first, by time, then any only the shown day has
        let keys = (data?.shares.filter { !$0.muted }.map(\.id) ?? []) + rows.filter { !$0.muted }.map(\.id)
        var seen = Set<String>()
        palette = ProjectPalette.colors(for: keys.filter { seen.insert($0).inserted })
    }

    // MARK: Header

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data {
                figure("Total", formatDuration(data.total))
                figure("Today", formatDuration(data.today))
                figure("Daily Average", formatDuration(data.dailyAverage))
                figure("Most Active Day",
                       data.busiest.map { $0.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "–",
                       detail: data.busiest.map { formatDuration($0.seconds) })
            }
        }
        .card()
    }

    private func figure(_ label: LocalizedStringKey, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Projects

    /// Ranked horizontal bars on one baseline, largest first; a click opens the project
    private func sharesCard(_ data: OverviewData) -> some View {
        let longest = data.shares.map(\.seconds).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text("Projects").font(.headline)
            ForEach(data.shares) { share in
                // "Other Projects" is many projects at once, so it has no detail to open
                let target: String? = share.id == "\u{0}other" ? nil : share.id == "\u{0}none" ? "" : share.id
                HoverRow(enabled: target != nil) { selected = target } content: {
                    HStack(spacing: 10) {
                        Text(share.name)
                            .foregroundStyle(share.muted ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(width: 80, alignment: .trailing)
                        GeometryReader { geo in
                            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(share.muted ? mutedColor : palette[share.id] ?? mutedColor)
                                .frame(width: max(2, geo.size.width * share.seconds / longest))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 12)
                        Text(verbatim: "\(formatDuration(share.seconds)) · \(Int((share.seconds / max(data.total, 1) * 100).rounded()))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 104, alignment: .trailing)
                    }
                }
            }
        }
        .font(.callout)
        .card()
    }

    // MARK: Trends

    /// One small chart per project on a shared scale, so they compare with each other as well as over time
    private func trendsCard(_ data: OverviewData) -> some View {
        let peak = data.trends.flatMap(\.daily).map(\.seconds).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Trends").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), alignment: .leading, spacing: 10) {
                ForEach(data.trends) { trend in
                    TrendCell(trend: trend, color: palette[trend.id] ?? mutedColor, peakHours: max(peak / 3600, 0.25), period: period)
                }
            }
        }
        .card()
    }

    // MARK: Day

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous Day")
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next Day")
                    .disabled(day >= Calendar.current.startOfDay(for: Date()))
                Spacer()
                Text(formatDuration(rows.reduce(0) { $0 + $1.seconds })).foregroundStyle(.secondary).monospacedDigit()
            }
            .buttonStyle(.borderless)
            if rows.isEmpty {
                Text("No activity on this day.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name)
                                .foregroundStyle(row.muted ? .secondary : .primary)
                                .lineLimit(1)
                                .gridColumnAlignment(.trailing)
                            Text(formatDuration(row.seconds))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            DayStrip(blocks: row.blocks, day: dayRange, color: row.muted ? mutedColor : palette[row.id] ?? mutedColor)
                                .frame(height: 14)
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Color.clear.frame(width: 0, height: 0)
                        HourAxis()
                    }
                }
                .font(.callout)
            }
        }
        .card()
    }

    private func move(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day)!
    }

    // MARK: Footer

    /// The rarely used commands sit in one menu
    private var footer: some View {
        HStack {
            Picker("Period", selection: $periodRaw) {
                Text("7 Days").tag(Period.week.rawValue)
                Text("30 Days").tag(Period.month.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if recorder.paused {
                Label("Recording Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
            } else if !recorder.hasAccessibility {
                Label("Accessibility access needed", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(recorder.paused ? "Resume Recording" : "Pause Recording") { recorder.paused.toggle() }
                Toggle("Open at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Sundial couldn't change Open at Login: %@", error.localizedDescription)
                        }
                    }))
                if !recorder.hasAccessibility {
                    Button("Allow Accessibility Access…") { recorder.requestAccessibility() }
                }
                Divider()
                Button("Quit Sundial") { NSApp.terminate(nil) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
        .buttonStyle(.glass)
    }
}

/// The project's breakdown for the period: agents, apps, and files, folders and pages
struct ProjectCard: View {
    let project: ProjectSummary
    let period: Period
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back")
                Text(project.name ?? String(localized: "No Project")).font(.headline)
                Spacer()
                Text(period.title).font(.subheadline).foregroundStyle(.secondary)
            }
            if !project.agents.isEmpty {
                section("Agents", note: "From your prompt until the agent stops. Agents running side by side each count in full.") {
                    ForEach(project.agents) { agent in
                        ShareRow(share: agent, total: project.agentSeconds) {
                            Image(systemName: "sparkles").frame(width: 18, height: 18)
                        }
                    }
                }
            }
            if !project.apps.isEmpty {
                section("Apps") {
                    ForEach(project.apps) { app in
                        ShareRow(share: app, total: project.seconds) {
                            Image(nsImage: appIcon(app.bundle)).resizable().frame(width: 18, height: 18)
                        }
                    }
                }
            }
            if !project.details.isEmpty {
                section(project.name == nil ? "Windows" : "Files, Folders and Pages") {
                    ForEach(project.details.prefix(30)) { detail in
                        ShareRow(share: detail, total: project.seconds) {
                            Image(nsImage: appIcon(detail.bundle)).resizable().frame(width: 16, height: 16)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.callout)
        .card()
    }

    private func section<Content: View>(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row that highlights under the pointer and acts on a click, as the app rows in MemoryLens do
struct HoverRow<Content: View>: View {
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(enabled && hovering ? 0.08 : 0)))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { if enabled { action() } }
    }
}

extension View {
    /// A glass card, as in MemoryLens
    func card() -> some View {
        padding(14)
            // Fills its cell, so cards side by side end at the same height
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
