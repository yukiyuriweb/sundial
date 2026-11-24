import Charts
import SwiftUI

/// Minutes spent on one project within one hour (for a day) or one day (for longer periods)
struct Bucket: Identifiable {
    let id: String
    let start: Date
    let project: String
    let minutes: Double
}

/// The projects the timeline names, in the order their colors are given, so colors stay put between reloads
func timelineSeries(_ projects: [ProjectSummary]) -> [String] {
    projects.filter { $0.name != nil && $0.seconds > 0 }.prefix(5).compactMap(\.name)
        + [String(localized: "Other Projects"), String(localized: "No Project")]
}

/// Your own time per hour or per day, stacked by project. The projects after the first five share one color.
func timeline(_ spans: [Span], projects: [ProjectSummary], in range: Range<Date>, unit: Calendar.Component) -> [Bucket] {
    let calendar = Calendar.current
    let named = projects.filter { $0.name != nil && $0.seconds > 0 }.prefix(5)
    func label(_ span: Span) -> String {
        guard let key = span.project?.lowercased() else { return String(localized: "No Project") }
        return named.first { $0.id == key }?.name ?? String(localized: "Other Projects")
    }
    var minutes: [Date: [String: Double]] = [:]
    for span in spans {
        var t = max(span.start, range.lowerBound)
        let end = min(span.end, range.upperBound)
        while t < end, let bucket = calendar.dateInterval(of: unit, for: t) {
            let next = min(bucket.end, end)
            minutes[bucket.start, default: [:]][label(span), default: 0] += next.timeIntervalSince(t) / 60
            t = next
        }
    }
    let order = timelineSeries(projects)
    return minutes.flatMap { start, byProject in
        byProject.map { Bucket(id: "\(start.timeIntervalSince1970)\n\($0.key)", start: start, project: $0.key, minutes: $0.value) }
    }
    .sorted { ($0.start, order.firstIndex(of: $0.project) ?? order.count) < ($1.start, order.firstIndex(of: $1.project) ?? order.count) }
}

struct TimelineChart: View {
    let buckets: [Bucket]
    /// Series names in color order; only those with bars are passed, so the legend lists what is drawn
    let series: [String]
    /// The whole span the chart covers, such as all of today rather than today until now
    let domain: Range<Date>
    let unit: Calendar.Component

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Time", bucket.start, unit: unit),
                    y: .value("Time Spent", unit == .hour ? bucket.minutes : bucket.minutes / 60))
                .foregroundStyle(by: .value("Project", bucket.project))
        }
        .chartForegroundStyleScale(domain: series)
        .chartXScale(domain: domain.lowerBound...domain.upperBound)
        .chartXAxis {
            if unit == .hour {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: domain.upperBound.timeIntervalSince(domain.lowerBound) > 8 * 86400 ? 7 : 1)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(v, format: .number.precision(.fractionLength(0...1))) } }
            }
        }
        .chartYAxisLabel(unit == .hour ? "min" : "hr")
        .chartLegend(position: .bottom, alignment: .leading)
    }
}
