import SwiftUI

/// How often you switched between projects over a stretch of time. Switching tasks costs time and accuracy each
/// time (Rubinstein, Meyer & Evans 2001; Monsell 2003), and the task left behind lingers in the mind
/// (Leroy 2009), so frequent, short back-and-forth is a sign of strain. Research sets no fixed limit, so
/// the panel compares a day with your own previous week.
///
/// Only switches between projects count: moving between a project's terminal and its GitHub page is one task.
/// Time outside any project is skipped, and coming back to the same project within five minutes continues
/// the same visit.
struct SwitchStats {
    /// When each switch to another project happened
    let switches: [Date]
    /// How long each visit to a project lasted
    let visits: [TimeInterval]
    /// Switches that went straight back to the project before, within five minutes (A → B → A)
    let backAndForth: Int
    /// Time spent on projects, which the rate is per: time outside any project and gaps in recording would
    /// only water it down
    let projectTime: TimeInterval

    var perHour: Double? { projectTime >= 600 ? Double(switches.count) / (projectTime / 3600) : nil }

    var medianVisit: TimeInterval? {
        guard !visits.isEmpty else { return nil }
        let sorted = visits.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    var backAndForthShare: Double? { switches.isEmpty ? nil : Double(backAndForth) / Double(switches.count) }
}

func switching(_ spans: [Span], in range: Range<Date>) -> SwitchStats {
    var visits: [(start: Date, end: Date, project: String)] = []
    var projectTime: TimeInterval = 0
    for span in spans.sorted(by: { $0.start < $1.start }) {
        let start = max(span.start, range.lowerBound), end = min(span.end, range.upperBound)
        guard start < end, let project = span.project?.lowercased() else { continue }
        projectTime += end.timeIntervalSince(start)
        if let previous = visits.last, previous.project == project, start.timeIntervalSince(previous.end) < 300 {
            visits[visits.count - 1].end = max(previous.end, end)
        } else {
            visits.append((start, end, project))
        }
    }
    var switches: [Date] = []
    var backAndForth = 0
    for i in visits.indices.dropFirst() where visits[i].project != visits[i - 1].project {
        switches.append(visits[i].start)
        if i >= 2, visits[i].project == visits[i - 2].project,
           visits[i].start.timeIntervalSince(visits[i - 1].start) < 300 {
            backAndForth += 1
        }
    }
    return SwitchStats(switches: switches, visits: visits.map { $0.end.timeIntervalSince($0.start) },
                       backAndForth: backAndForth, projectTime: projectTime)
}

/// Switches in each half hour of the range, starting at its start (a whole hour)
func switchBins(_ switches: [Date], in range: Range<Date>) -> [(start: Date, count: Int)] {
    var bins: [(start: Date, count: Int)] = []
    var t = range.lowerBound
    while t < range.upperBound {
        let next = t.addingTimeInterval(1800)
        bins.append((t, switches.filter { $0 >= t && $0 < next }.count))
        t = next
    }
    return bins
}

/// The busiest quarter of half hours over the days before: half hours with more switches than this stand out
/// as more than usual. Only half hours with some activity count.
func usualSwitchesPerHalfHour(_ spans: [Span], days: [Range<Date>]) -> Double? {
    var counts: [Int] = []
    for day in days {
        // Only this day's spans set its bounds; a day with no activity adds nothing
        let mine = spans.filter { $0.end > day.lowerBound && $0.start < day.upperBound }
        guard let first = mine.map({ max($0.start, day.lowerBound) }).min(),
              let last = mine.map({ min($0.end, day.upperBound) }).max(),
              first < last else { continue }
        counts += switchBins(switching(mine, in: day).switches, in: first..<last).map(\.count)
    }
    guard counts.count >= 4 else { return nil }
    return Double(counts.sorted()[counts.count * 3 / 4])
}

/// The day's switches per half hour, darker for more, in neutral ink rather than a hue, so it isn't taken for
/// a project's color; half hours above the usual stand out at full strength. Each has a tooltip with its count.
struct SwitchStrip: View {
    let bins: [(start: Date, count: Int)]
    let range: Range<Date>
    let usual: Double?

    var body: some View {
        let peak = Double(max(bins.map(\.count).max() ?? 1, 1))
        GeometryReader { geo in
            ForEach(bins, id: \.start) { bin in
                let x0 = xPosition(bin.start, in: range, width: geo.size.width)
                let x1 = xPosition(min(bin.start.addingTimeInterval(1800), range.upperBound), in: range, width: geo.size.width)
                let aboveUsual = usual.map { Double(bin.count) > $0 } ?? false
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(bin.count == 0 ? 0.05 : aboveUsual ? 0.75 : 0.12 + 0.43 * Double(bin.count) / peak))
                    .frame(width: max(1, x1 - x0 - 1), height: geo.size.height)
                    .position(x: (x0 + x1) / 2, y: geo.size.height / 2)
                    .help(Text("\(bin.start.formatted(date: .omitted, time: .shortened)): ^[\(bin.count) switch](inflect: true)"))
            }
        }
    }
}
