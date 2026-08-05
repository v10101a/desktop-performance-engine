import Foundation

/// Shared easing curves for timed effects (cursor paths, window moves).
func easingCurve(_ name: String?) -> (Double) -> Double {
    switch name {
    case "easeIn":    return { $0 * $0 }
    case "easeOut":   return { 1 - (1 - $0) * (1 - $0) }
    case "easeInOut": return { $0 < 0.5 ? 2 * $0 * $0 : 1 - pow(-2 * $0 + 2, 2) / 2 }
    default:          return { $0 }   // linear
    }
}
