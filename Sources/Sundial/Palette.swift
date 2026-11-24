import AppKit
import SwiftUI

/// The eight categorical colors of the reference palette in Claude Code's dataviz skill, in its order, with a
/// step for light and one for dark appearance. The palette is validated there for color-vision deficiency.
private let slots: [(light: UInt32, dark: UInt32)] = [
    (0x2a78d6, 0x3987e5), // blue
    (0xeb6834, 0xd95926), // orange
    (0x1baf7a, 0x199e70), // aqua
    (0xeda100, 0xc98500), // yellow
    (0xe87ba4, 0xd55181), // magenta
    (0x008300, 0x0ca30c), // green
    (0x6250d6, 0x9085e9), // violet
    (0xe34948, 0xe66767), // red
]

private func slotColor(_ index: Int) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hex = dark ? slots[index].dark : slots[index].light
        return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                       blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    })
}

/// "No Project", "Other Projects", and projects past the eighth on one screen
let mutedColor = Color.gray.opacity(0.5)

/// Gives each project a color of its own that stays the same across views, periods and launches. A project
/// keeps the slot it was first given; one seen for the first time takes the free slot whose last owner was seen
/// longest ago. Only when two projects on screen share a slot does the one with less time move to a free slot,
/// and when all eight are taken, it is drawn muted.
@MainActor
enum ProjectPalette {
    private static let slotsKey = "projectColorSlots"
    private static let seenKey = "projectColorSeen"

    /// `keys` are project ids (lowercased names), most time first
    static func colors(for keys: [String]) -> [String: Color] {
        let defaults = UserDefaults.standard
        var assigned = defaults.dictionary(forKey: slotsKey) as? [String: Int] ?? [:]
        var seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        var used = Set<Int>()
        var result: [String: Int] = [:]
        for key in keys {
            if let slot = assigned[key], slot < slots.count, !used.contains(slot) {
                used.insert(slot)
                result[key] = slot
            }
        }
        func lastSeen(_ slot: Int) -> Double {
            assigned.filter { $0.value == slot }.keys.compactMap { seen[$0] }.max() ?? -.infinity
        }
        for key in keys where result[key] == nil {
            guard let slot = (0..<slots.count).filter({ !used.contains($0) }).min(by: { lastSeen($0) < lastSeen($1) })
            else { break }
            assigned[key] = slot
            used.insert(slot)
            result[key] = slot
        }
        let now = Date().timeIntervalSince1970
        for key in result.keys { seen[key] = now }
        defaults.set(assigned, forKey: slotsKey)
        defaults.set(seen, forKey: seenKey)
        return result.mapValues(slotColor)
    }
}
