import Foundation
import RestABitCore

enum EdgeMotion: String, CaseIterable, Codable {
    case rotate, dash, hop, peek

    static let variants: [Self] = [.dash, .hop, .peek]

    var title: String {
        switch self {
        case .rotate: Copy.text("轮换", "Cycle")
        case .dash: Copy.text("小跑", "Run in")
        case .hop: Copy.text("轻跃", "Hop in")
        case .peek: Copy.text("探头", "Peek in")
        }
    }
}

enum BlinkMotion: String, CaseIterable, Codable {
    case rotate, hop, rise, sway

    static let variants: [Self] = [.hop, .rise, .sway]

    var title: String {
        switch self {
        case .rotate: Copy.text("轮换", "Cycle")
        case .hop: Copy.text("跳一下", "Hop")
        case .rise: Copy.text("慢慢探头", "Rise slowly")
        case .sway: Copy.text("轻轻摇头", "Sway")
        }
    }
}

enum RestScene: String, CaseIterable, Codable {
    case rotate, hills, shore, grove, plain

    static let variants: [Self] = [.hills, .shore, .grove]

    var title: String {
        switch self {
        case .rotate: Copy.text("轮换插画", "Cycle")
        case .hills: Copy.text("远山", "Foothills")
        case .shore: Copy.text("湖畔", "Lakeshore")
        case .grove: Copy.text("松林", "Pine grove")
        case .plain: Copy.text("静色", "Plain")
        }
    }
}

#if DEBUG
extension EntranceOrigin {
    var previewTitle: String {
        switch self {
        case .left: Copy.text("从左侧入场", "From the left")
        case .right: Copy.text("从右侧入场", "From the right")
        case .top: Copy.text("从上侧入场", "From the top")
        case .bottom: Copy.text("从下侧入场", "From the bottom")
        case .topLeft: Copy.text("从左上角入场", "From the top left")
        case .topRight: Copy.text("从右上角入场", "From the top right")
        case .bottomLeft: Copy.text("从左下角入场", "From the bottom left")
        case .bottomRight: Copy.text("从右下角入场", "From the bottom right")
        }
    }
}
#endif
