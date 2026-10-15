import Foundation

enum QuranReadingMode: String, CaseIterable {
    case arabic = "Arabic"
    case english = "English"

    mutating func toggle() { self = self == .arabic ? .english : .arabic }
}

enum QuranAutoScrollSpeed: String, CaseIterable, Identifiable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var id: String { rawValue }

    var pointsPerSecond: Double {
        switch self {
        case .slow: return 12
        case .medium: return 24
        case .fast: return 42
        }
    }
}

/// Frame-rate independent movement, clamped to the visible document's bounds.
/// Limit the elapsed time so a delayed frame cannot skip a passage.
enum QuranScrollMotion {
    static func nextOffset(current: Double, minimum: Double, maximum: Double,
                           elapsed: Double, speed: QuranAutoScrollSpeed) -> Double {
        let end = max(minimum, maximum)
        return min(end, max(minimum, current) + speed.pointsPerSecond * min(0.1, max(0, elapsed)))
    }
}
