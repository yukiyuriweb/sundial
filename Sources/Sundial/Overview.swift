import Charts
import SwiftUI

/// Your own time over a period, for the Overview: headline figures, each project's share, and each project's
/// day-by-day trend
struct OverviewData {
    struct Share: Identifiable {
        let id: String
        let name: String
        let seconds: TimeInterval
        /// "No Project" and "Other Projects" are drawn muted, apart from real projects
        let muted: Bool
    }

    struct Trend: Identifiable {
        let id: String
        let name: String
        let seconds: TimeInterval
        let daily: [Day]
    }

    struct Day: Identifiable {
        var id: Date { day }
        let day: Date
        let seconds: TimeInterval
    }

    let range: Range<Date>
    let total: TimeInterval
    let today: TimeInterval
    let dailyAverage: TimeInterval
    let busiest: Day?
    let shares: [Share]
    let trends: [Trend]
}

/// The projects past the first eight fold into "Other Projects"; trends show the first six.
func overview(_ spans: [Span], period: Period, now: Date = Date()) -> OverviewData {
    let calendar = Calendar.current
    let range = period.range(now: now)
    var days: [Range<Date>] = []
    var day = range.lowerBound
    while day < range.upperBound {
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        days.append(day..<min(next, range.upperBound))
        day = next
    }
    func daily(_ spans: [Span]) -> [OverviewData.Day] {
        days.map { d in OverviewData.Day(day: d.lowerBound, seconds: spans.reduce(0) { $0 + $1.seconds(in: d) }) }
    }

    let projects = summarize(spans, agents: [], in: range).filter { $0.seconds > 0 }
    let named = projects.filter { $0.name != nil }
    let total = projects.reduce(0) { $0 + $1.seconds }
    var shares = named.prefix(8).map { OverviewData.Share(id: $0.id, name: $0.name!, seconds: $0.seconds, muted: false) }
    let rest = named.dropFirst(8).reduce(0) { $0 + $1.seconds }
    if rest > 0 {
        shares.append(OverviewData.Share(id: "\u{0}other", name: String(localized: "Other Projects"), seconds: rest, muted: true))
    }
    if let none = projects.first(where: { $0.name == nil }) {
        shares.append(OverviewData.Share(id: "\u{0}none", name: String(localized: "No Project"), seconds: none.seconds, muted: true))
    }
    let trends = named.prefix(6).map { project in
        OverviewData.Trend(id: project.id, name: project.name!, seconds: project.seconds,
                           daily: daily(spans.filter { $0.project?.lowercased() == project.id }))
    }
    let totals = daily(spans)
    return OverviewData(
        range: range, total: total,
        today: spans.reduce(0) { $0 + $1.seconds(in: Period.today.range(now: now)) },
        dailyAverage: days.isEmpty ? 0 : total / Double(days.count),
        busiest: totals.max { $0.seconds < $1.seconds }.flatMap { $0.seconds > 0 ? $0 : nil },
        shares: shares, trends: trends)
}

/// One project's row in the day view: when in the day you worked on it
struct DayRow: Identifiable {
    let id: String
    let name: String
    let seconds: TimeInterval
    let muted: Bool
    let blocks: [Range<Date>]
}

/// Spans less than two minutes apart join into one block, and each block is at least two minutes wide,
/// so five-second samples stay visible on a 24-hour axis.
func dayRows(_ spans: [Span], day: Range<Date>) -> [DayRow] {
    let projects = summarize(spans, agents: [], in: day).filter { $0.seconds > 0 }
    return projects.map { project in
        var blocks: [Range<Date>] = []
        let mine = spans.filter { ($0.project?.lowercased() ?? "") == project.id }
            .map { max($0.start, day.lowerBound)..<min($0.end, day.upperBound) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        for span in mine {
            if let last = blocks.last, span.lowerBound.timeIntervalSince(last.upperBound) < 120 {
                blocks[blocks.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                blocks.append(span)
            }
        }
        blocks = blocks.map { $0.lowerBound..<max($0.upperBound, $0.lowerBound.addingTimeInterval(120)) }
        return DayRow(id: project.id, name: project.name ?? String(localized: "No Project"),
                      seconds: project.seconds, muted: project.name == nil, blocks: blocks)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("overviewPeriod") private var periodRaw = Period.week.rawValue
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var data: OverviewData?
    @State private var rows: [DayRow] = []
    @State private var palette: [String: Color] = [:]

    private var period: Period { Period(rawValue: periodRaw) ?? .week }
    private var dayRange: Range<Date> { day..<Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let data {
                    figures(data)
                    if !data.shares.isEmpty {
                        GroupBox { shareChart(data) } label: { Text("Projects").font(.headline) }
                        GroupBox { trendGrid(data) } label: { Text("Trends").font(.headline) }
                    }
                }
                GroupBox { dayView } label: { dayHeader }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(period.title)
        .toolbar {
            ToolbarItem {
                Picker("Period", selection: $periodRaw) {
                    Text("Last 7 Days").tag(Period.week.rawValue)
                    Text("Last 30 Days").tag(Period.month.rawValue)
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: store.revision) { reload() }
        .onChange(of: periodRaw) { reload() }
        .onChange(of: day) { reload() }
    }

    private func reload() {
        let now = Date()
        data = overview(store.spans(in: period.range(now: now)), period: period, now: now)
        rows = dayRows(store.spans(in: dayRange), day: dayRange)
        // The period's projects first, by time, then any only the shown day has
        let keys = (data?.shares.filter { !$0.muted }.map(\.id) ?? []) + rows.filter { !$0.muted }.map(\.id)
        var seen = Set<String>()
        palette = ProjectPalette.colors(for: keys.filter { seen.insert($0).inserted })
    }

    // MARK: Figures

    private func figures(_ data: OverviewData) -> some View {
        HStack(spacing: 12) {
            figure(formatDuration(data.total), "Total")
            figure(formatDuration(data.today), "Today")
            figure(formatDuration(data.dailyAverage), "Daily Average")
            figure(data.busiest.map { $0.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "–",
                   "Most Active Day", detail: data.busiest.map { formatDuration($0.seconds) })
        }
    }

    private func figure(_ value: String, _ label: LocalizedStringKey, detail: String? = nil) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(detail ?? " ").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: Share

    /// Ranked horizontal bars on one baseline, largest first, each row with its name, time and share
    private func shareChart(_ data: OverviewData) -> some View {
        let longest = data.shares.map(\.seconds).max() ?? 1
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(data.shares) { share in
                GridRow {
                    Text(share.name)
                        .foregroundStyle(share.muted ? .secondary : .primary)
                        .lineLimit(1)
                        .gridColumnAlignment(.trailing)
                    GeometryReader { geo in
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(share.muted ? mutedColor : palette[share.id] ?? mutedColor)
                            .frame(width: max(2, geo.size.width * share.seconds / longest))
                    }
                    .frame(height: 14)
                    Text(verbatim: "\(formatDuration(share.seconds)) · \(Int((share.seconds / max(data.total, 1) * 100).rounded()))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    // MARK: Trends

    /// One small chart per project on a shared scale, so they compare with each other as well as over time
    private func trendGrid(_ data: OverviewData) -> some View {
        let peak = data.trends.flatMap(\.daily).map(\.seconds).max() ?? 0
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(data.trends) { trend in
                TrendCell(trend: trend, color: palette[trend.id] ?? mutedColor, peakHours: max(peak / 3600, 0.25), period: period)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Day

    private var dayHeader: some View {
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
    }

    private func move(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day)!
    }

    /// One row per project across the day's 24 hours, with a block where you worked on it
    @ViewBuilder private var dayView: some View {
        if rows.isEmpty {
            Text("No activity on this day.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
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
                            .frame(height: 16)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Color.clear.frame(width: 0, height: 0)
                    HourAxis()
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }
}

/// A 24-hour track with gridlines every three hours and a block for each stretch of work
struct DayStrip: View {
    let blocks: [Range<Date>]
    let day: Range<Date>
    let color: Color

    var body: some View {
        Canvas { context, size in
            let length = day.upperBound.timeIntervalSince(day.lowerBound)
            func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(day.lowerBound) / length }
            for hour in stride(from: 0, through: 24, by: 3) {
                let gx = size.width * CGFloat(hour) / 24
                context.fill(Path(CGRect(x: gx - 0.25, y: 0, width: 0.5, height: size.height)), with: .color(.secondary.opacity(0.3)))
            }
            for block in blocks {
                let rect = CGRect(x: x(block.lowerBound), y: 1, width: max(1.5, x(block.upperBound) - x(block.lowerBound)), height: size.height - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
    }
}

/// Hour labels under the day strips, every three hours
struct HourAxis: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
                Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!, format: .dateTime.hour())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // Centered under its gridline, except midnight, which would be cut off at the edge
                    .position(x: max(6, geo.size.width * CGFloat(hour) / 24), y: 7)
            }
        }
        .frame(height: 14)
    }
}

struct TrendCell: View {
    let trend: OverviewData.Trend
    let color: Color
    let peakHours: Double
    let period: Period
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(trend.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(formatDuration(trend.seconds)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart {
                ForEach(trend.daily) { d in
                    AreaMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", d.seconds / 3600))
                        .foregroundStyle(color.opacity(0.15))
                    LineMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", d.seconds / 3600))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let selected, let d = trend.daily.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selected) }) {
                    RuleMark(x: .value("Day", d.day, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(verbatim: "\(d.day.formatted(.dateTime.month(.abbreviated).day()))  \(formatDuration(d.seconds))")
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                }
            }
            .chartYScale(domain: 0...peakHours)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) {
                    AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.defaultDigits).day())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours == 0 ? "0" : Duration.seconds(hours * 3600)
                                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                        }
                    }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 90)
        }
    }
}
