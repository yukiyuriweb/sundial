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

/// The id of the "Other Projects" share, which no project id (a lowercased folder name) can be
let otherProjectsID = "\u{0}other"

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
        shares.append(OverviewData.Share(id: otherProjectsID, name: String(localized: "Other Projects"), seconds: rest, muted: true))
    }
    if let none = projects.first(where: { $0.name == nil }) {
        shares.append(OverviewData.Share(id: "\u{0}none", name: String(localized: "No Project"), seconds: none.seconds, muted: true))
    }
    let trends = named.prefix(6).map { project in
        OverviewData.Trend(id: project.id, name: project.name!,
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
        // Widened within the day: one that would run past midnight grows backwards instead
        blocks = blocks.map { block in
            let end = min(max(block.upperBound, block.lowerBound.addingTimeInterval(120)), day.upperBound)
            return min(block.lowerBound, end.addingTimeInterval(-120))..<end
        }
        return DayRow(id: project.id, name: project.name ?? String(localized: "No Project"),
                      seconds: project.seconds, muted: project.name == nil, blocks: blocks)
    }
}

/// The part of the day the timeline shows: from an hour before the first block to an hour after the last,
/// on whole hours and within the day; all of it when there are no blocks
func timelineRange(_ rows: [DayRow], day: Range<Date>) -> Range<Date> {
    let blocks = rows.flatMap(\.blocks)
    guard let first = blocks.map(\.lowerBound).min(), let last = blocks.map(\.upperBound).max() else { return day }
    let calendar = Calendar.current
    let start = calendar.dateInterval(of: .hour, for: first.addingTimeInterval(-3600))!.start
    let end = last.addingTimeInterval(3600)
    let endHour = calendar.dateInterval(of: .hour, for: end)!
    return max(start, day.lowerBound)..<min(end == endHour.start ? end : endHour.end, day.upperBound)
}

/// Gridline times across the range, every hour, two or three depending on its length. They step by elapsed
/// hours, so on a day that changes to or from daylight saving time they stay where the blocks are.
func hourMarks(in range: Range<Date>) -> [Date] {
    let hours = range.upperBound.timeIntervalSince(range.lowerBound) / 3600
    let step = hours <= 6 ? 1 : hours <= 12 ? 2 : 3
    var marks: [Date] = []
    var t = range.lowerBound
    while t <= range.upperBound {
        marks.append(t)
        t = Calendar.current.date(byAdding: .hour, value: step, to: t)!
    }
    return marks
}

/// Where a moment falls across a strip of the given width
func xPosition(_ date: Date, in day: Range<Date>, width: CGFloat) -> CGFloat {
    width * date.timeIntervalSince(day.lowerBound) / day.upperBound.timeIntervalSince(day.lowerBound)
}

/// A track across the shown part of the day, with hour gridlines and a block for each stretch of work
struct DayStrip: View {
    let blocks: [Range<Date>]
    let day: Range<Date>
    let color: Color

    var body: some View {
        Canvas { context, size in
            func x(_ date: Date) -> CGFloat { xPosition(date, in: day, width: size.width) }
            for mark in hourMarks(in: day) {
                let gx = x(mark)
                context.fill(Path(CGRect(x: gx - 0.25, y: 0, width: 0.5, height: size.height)), with: .color(.secondary.opacity(0.3)))
            }
            for block in blocks {
                let rect = CGRect(x: x(block.lowerBound), y: 1, width: max(1.5, x(block.upperBound) - x(block.lowerBound)), height: size.height - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
    }
}

/// Hour labels under the day strips, one per gridline
struct HourAxis: View {
    let day: Range<Date>

    var body: some View {
        GeometryReader { geo in
            ForEach(hourMarks(in: day), id: \.self) { mark in
                let label = mark.formatted(.dateTime.hour())
                let half = (label as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width / 2
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // Centered under its gridline, but kept wholly inside at the two ends
                    .position(x: min(max(half, xPosition(mark, in: day, width: geo.size.width)), geo.size.width - half), y: 7)
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
            // The period's total is in the Projects card already
            Text(trend.name).font(.callout.weight(.semibold)).lineLimit(1)
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
            .frame(height: 52)
        }
    }
}
