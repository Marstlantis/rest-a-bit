import CoreGraphics
import Foundation

public enum ScreenEdge: String, CaseIterable, Codable, Sendable {
    case left, right, bottom, top
}

public enum EntranceOrigin: String, CaseIterable, Sendable {
    case left, right, bottom, top, topLeft, topRight, bottomLeft, bottomRight

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        default: false
        }
    }

    public var calloutSide: ScreenEdge {
        switch self {
        case .left, .topLeft, .bottomLeft: .left
        case .right, .topRight, .bottomRight: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    func point(in screen: CGRect, along fraction: CGFloat) -> CGPoint {
        switch self {
        case .left: CGPoint(x: screen.minX, y: screen.minY + screen.height * fraction)
        case .right: CGPoint(x: screen.maxX, y: screen.minY + screen.height * fraction)
        case .bottom: CGPoint(x: screen.minX + screen.width * fraction, y: screen.minY)
        case .top: CGPoint(x: screen.minX + screen.width * fraction, y: screen.maxY)
        case .topLeft: CGPoint(x: screen.minX, y: screen.maxY)
        case .topRight: CGPoint(x: screen.maxX, y: screen.maxY)
        case .bottomLeft: CGPoint(x: screen.minX, y: screen.minY)
        case .bottomRight: CGPoint(x: screen.maxX, y: screen.minY)
        }
    }
}

public struct Landing: Equatable {
    public let origin: EntranceOrigin
    public let entry: CGPoint
    public let stage: CGRect
    public let stop: CGPoint
    public let callout: Callout
    public var card: CGRect { callout.frame }

    public struct Callout: Equatable {
        public let frame: CGRect
        public let arrow: ScreenEdge
    }

    private static let cardWidth: CGFloat = 258
    private static let cardHeight: CGFloat = 84
    private static let inset: CGFloat = 12

    public static func candidates(in safe: CGRect, pointer: CGPoint) -> [Landing] {
        guard safe.width >= 326, safe.height >= 260 else { return [] }
        let stop = CGPoint(x: safe.midX, y: safe.midY)
        let margin: CGFloat = 92
        return EntranceOrigin.allCases.flatMap { origin -> [Landing] in
            guard let callout = callout(near: stop, in: safe, pointer: pointer, preferred: origin.calloutSide)
            else { return [] }
            let locations: [CGFloat] = origin.isCorner ? [0.5] : [0.19, 0.34, 0.50, 0.66, 0.81]
            return locations.map { fraction in
                let entry = origin.point(in: safe, along: fraction)
                let span = CGRect(x: min(entry.x, stop.x), y: min(entry.y, stop.y),
                                  width: abs(entry.x - stop.x), height: abs(entry.y - stop.y))
                let stage = span.insetBy(dx: -margin, dy: -margin).intersection(safe)
                return Landing(origin: origin, entry: entry, stage: stage, stop: stop, callout: callout)
            }
        }
    }

    public static func callout(near stop: CGPoint, in safe: CGRect, pointer: CGPoint,
                               preferred: ScreenEdge, compact: Bool = false) -> Callout? {
        let width: CGFloat = compact ? 214 : cardWidth
        let height: CGFloat = compact ? 54 : cardHeight
        let opposite: ScreenEdge
        switch preferred {
        case .left: opposite = .right
        case .right: opposite = .left
        case .top: opposite = .bottom
        case .bottom: opposite = .top
        }
        let order = [preferred, opposite] + ScreenEdge.allCases.filter { $0 != preferred && $0 != opposite }
        for arrow in order {
            let x: CGFloat
            let y: CGFloat
            switch arrow {
            case .left: (x, y) = (stop.x + 64, stop.y - height / 2)
            case .right: (x, y) = (stop.x - 64 - width, stop.y - height / 2)
            case .top: (x, y) = (stop.x - width / 2, stop.y - 54 - height)
            case .bottom: (x, y) = (stop.x - width / 2, stop.y + 58)
            }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            if safe.insetBy(dx: inset, dy: inset).contains(frame),
               !frame.insetBy(dx: -16, dy: -16).contains(pointer) {
                return Callout(frame: frame, arrow: arrow)
            }
        }
        return nil
    }

    public static func choose<R: RandomNumberGenerator>(in safe: CGRect, pointer: CGPoint,
                                                        previous: EntranceOrigin?, force: EntranceOrigin?,
                                                        using random: inout R) -> Landing? {
        let all = candidates(in: safe, pointer: pointer)
        if let force { return all.filter { $0.origin == force }.randomElement(using: &random) }
        // Choose the region first so five positions on an edge do not drown out the corners.
        let available = EntranceOrigin.allCases.filter { origin in all.contains { $0.origin == origin } }
        let fresh = available.filter { $0 != previous }
        guard let origin = (fresh.isEmpty ? available : fresh).randomElement(using: &random) else { return nil }
        return all.filter { $0.origin == origin }.randomElement(using: &random)
    }

    public static func fallback(in safe: CGRect, pointer: CGPoint, compact: Bool = false) -> CGRect? {
        let width: CGFloat = compact ? 214 : cardWidth
        let height: CGFloat = compact ? 54 : cardHeight
        guard safe.width >= width + 2 * inset, safe.height >= height + 2 * inset else { return nil }
        let corners = [
            CGPoint(x: safe.minX + inset, y: safe.minY + inset),
            CGPoint(x: safe.maxX - width - inset, y: safe.minY + inset),
            CGPoint(x: safe.minX + inset, y: safe.maxY - height - inset),
            CGPoint(x: safe.maxX - width - inset, y: safe.maxY - height - inset)
        ]
        return corners.map { CGRect(origin: $0, size: CGSize(width: width, height: height)) }
            .max { hypot($0.midX - pointer.x, $0.midY - pointer.y) < hypot($1.midX - pointer.x, $1.midY - pointer.y) }
    }
}

public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}
