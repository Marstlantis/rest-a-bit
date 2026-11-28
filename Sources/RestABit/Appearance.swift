import SwiftUI
import RestABitCore

enum AppLanguage: String, CaseIterable, Codable {
    case system, chinese, english

    var title: String {
        switch self {
        case .system: Copy.text("跟随系统", "Follow system")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

enum Copy {
    static var language: AppLanguage = .system

    static var chinese: Bool {
        switch language {
        case .chinese: true
        case .english: false
        case .system: Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        }
    }

    static func text(_ chinese: String, _ english: String) -> String {
        Self.chinese ? chinese : english
    }

    static var name: String { text("歇哈嘛", "Rest a Bit") }
    static var settingsTitle: String { text("\(name)设置", "\(name) Settings") }
    static var quitTitle: String { text("退出\(name)", "Quit \(name)") }
}

extension Reminder {
    var name: String {
        switch self {
        case .look: Copy.text("远眺", "Eye break")
        case .water: Copy.text("喝水", "Water")
        case .stand: Copy.text("站立", "Stand up")
        case .blink: Copy.text("眨眼", "Blink")
        case .pelvicFloor: Copy.text("提肛", "Kegel exercises")
        }
    }

    var icon: String {
        switch self {
        case .look: "eye"
        case .water: "drop"
        case .stand: "figure.stand"
        case .blink: "eye.circle"
        case .pelvicFloor: "waveform.path"
        }
    }

    var nudge: String {
        switch self {
        case .look: Copy.text("看哈远处嘛", "Look into the distance")
        case .water: Copy.text("该喝水啦～", "Sip some water")
        case .stand: Copy.text("站起来休息哈嘛", "Stand up for a bit")
        case .blink: Copy.text("眨两哈嘛", "Blink twice")
        case .pelvicFloor: Copy.text("跟狐狸练哈嘛", "Kegels with the fox")
        }
    }

    var restTitle: String {
        switch self {
        case .look: Copy.text("看哈屏幕外的远处嘛", "Look into the distance")
        case .stand: Copy.text("站起来休息哈嘛", "Stand up for a bit")
        case .water, .blink, .pelvicFloor: nudge
        }
    }

    var aside: String {
        switch self {
        case .look: Copy.text("也看哈远处嘛", "Look into the distance")
        case .water: Copy.text("也可以喝几口水", "Sip some water")
        case .stand: Copy.text("也可以起来走几步", "Walk a few steps")
        case .blink: Copy.text("眨两哈嘛", "Blink twice")
        case .pelvicFloor: nudge
        }
    }
}

struct Palette {
    let dark: Bool

    var paper: Color { dark ? Color(red: 0.15, green: 0.13, blue: 0.12) : Color(red: 0.99, green: 0.96, blue: 0.90) }
    var shade: Color { dark ? Color(red: 0.22, green: 0.17, blue: 0.16) : Color(red: 0.94, green: 0.86, blue: 0.77) }
    var ink: Color { dark ? Color(red: 0.98, green: 0.93, blue: 0.87) : Color(red: 0.17, green: 0.14, blue: 0.13) }
    var quiet: Color { dark ? Color(red: 0.83, green: 0.74, blue: 0.68) : Color(red: 0.40, green: 0.32, blue: 0.28) }
    var accent: Color { dark ? Color(red: 1, green: 0.63, blue: 0.46) : Color(red: 0.60, green: 0.23, blue: 0.13) }
    var hairline: Color { accent.opacity(0.24) }
}

struct ReminderGlyph: View {
    let reminder: Reminder
    var size: CGFloat = 14

    var body: some View {
        Group {
            if reminder == .blink {
                ClosedEye().stroke(style: StrokeStyle(lineWidth: 1.55, lineCap: .round))
                    .frame(width: size + 2, height: size)
            } else {
                Image(systemName: reminder.icon)
                    .font(.system(size: size, weight: .medium))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct ClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.12, y: h * 0.40))
        path.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.40),
                          control: CGPoint(x: w * 0.50, y: h * 0.89))
        path.move(to: CGPoint(x: w * 0.24, y: h * 0.53))
        path.addLine(to: CGPoint(x: w * 0.17, y: h * 0.68))
        path.move(to: CGPoint(x: w * 0.76, y: h * 0.53))
        path.addLine(to: CGPoint(x: w * 0.83, y: h * 0.68))
        return path
    }
}

struct NudgeCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let batch: ReminderBatch
    var edge: ScreenEdge?
    let preview: Bool
    let dismissOnly: Bool
    let confirm: () -> Void
    let deferBreak: () -> Void

    var arrowInsets: CGSize {
        switch edge {
        case .left, .right: CGSize(width: Landing.Callout.arrowDepth, height: 0)
        case .top, .bottom: CGSize(width: 0, height: Landing.Callout.arrowDepth)
        case nil: .zero
        }
    }

    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var canStartBreak: Bool { !preview && !dismissOnly && batch.main.usesEdgeEntrance }
    private var title: String {
        if batch.main == .stand, batch.included.contains(.look) {
            return Copy.text("站起来休息哈，也看哈远处", "Stand up and look away")
        }
        return batch.main.nudge
    }

    private var primaryAction: some View {
        Button(canStartBreak ? Copy.text("现在休息", "Take a break") : Copy.text("知道了", "Got it"),
               action: confirm)
            .buttonStyle(CardActionStyle(palette: palette, emphasis: canStartBreak))
    }

    private var headline: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    var body: some View {
        let bubble = SpeechBubble(edge: edge)
        Group {
            if batch.main == .water {
                HStack(spacing: 7) {
                    ReminderGlyph(reminder: .water, size: 13)
                        .foregroundStyle(palette.accent)
                    headline
                    primaryAction.padding(.leading, 4)
                }
                .fixedSize(horizontal: true, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        if edge == nil {
                            ReminderGlyph(reminder: batch.main, size: 13).foregroundStyle(palette.accent)
                        }
                        headline.lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        primaryAction
                        if canStartBreak {
                            Button(Copy.text("5 分钟后", "In 5 min"), action: deferBreak)
                                .buttonStyle(CardActionStyle(palette: palette, emphasis: false))
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, batch.main == .water ? 12 : 13)
        .padding(.vertical, batch.main == .water ? 8 : 10)
        .padding(edge == .left ? .leading : .trailing, arrowInsets.width)
        .padding(edge == .top ? .top : .bottom, arrowInsets.height)
        .background {
            bubble.fill(palette.paper)
                .overlay { bubble.stroke(palette.hairline, lineWidth: 1) }
        }
    }
}

private struct SpeechBubble: Shape {
    let edge: ScreenEdge?

    func path(in rect: CGRect) -> Path {
        let margin: CGFloat = 1.5
        let tail = Landing.Callout.arrowDepth
        let r: CGFloat = 14
        let left = rect.minX + margin + (edge == .left ? tail : 0)
        let right = rect.maxX - margin - (edge == .right ? tail : 0)
        let top = rect.minY + margin + (edge == .top ? tail : 0)
        let bottom = rect.maxY - margin - (edge == .bottom ? tail : 0)
        let mx = (left + right) / 2
        let my = (top + bottom) / 2

        var path = Path()
        path.move(to: CGPoint(x: left + r, y: top))
        if edge == .top {
            [CGPoint(x: mx - 5, y: top), CGPoint(x: mx, y: top - tail), CGPoint(x: mx + 5, y: top)].forEach { path.addLine(to: $0) }
        }
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
        if edge == .right {
            [CGPoint(x: right, y: my - 5), CGPoint(x: right + tail, y: my), CGPoint(x: right, y: my + 5)].forEach { path.addLine(to: $0) }
        }
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        if edge == .bottom {
            [CGPoint(x: mx + 5, y: bottom), CGPoint(x: mx, y: bottom + tail), CGPoint(x: mx - 5, y: bottom)].forEach { path.addLine(to: $0) }
        }
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        if edge == .left {
            [CGPoint(x: left, y: my + 5), CGPoint(x: left - tail, y: my), CGPoint(x: left, y: my - 5)].forEach { path.addLine(to: $0) }
        }
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}

struct CardActionStyle: ButtonStyle {
    let palette: Palette
    let emphasis: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 27)
            .background(emphasis ? palette.accent.opacity(palette.dark ? 0.21 : 0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(emphasis ? palette.accent : palette.quiet)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct RestScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let batch: ReminderBatch
    let timing: RestTiming
    let fox: [FoxPose: CGImage]
    let illustration: CGImage?
    let motion: Bool
    let close: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let palette = Palette(dark: colorScheme == .dark)
            let compact = geometry.size.height < 540
            ZStack {
                LinearGradient(colors: [palette.paper, palette.shade],
                               startPoint: .top, endPoint: .bottomTrailing)

                if let illustration {
                    RestBackdrop(image: illustration, size: geometry.size, palette: palette)
                } else {
                    Horizon()
                        .stroke(palette.accent.opacity(0.13), lineWidth: 1)
                        .accessibilityHidden(true)
                }

                VStack(spacing: compact ? 13 : 21) {
                    Text(batch.main.restTitle)
                        .font(.system(size: compact ? 42 : 56, weight: .medium, design: .serif))
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    let other = batch.included.filter { $0 != batch.main }.map(\.aside)
                    if !other.isEmpty {
                        Text(other.joined(separator: Copy.text("，", " · ")))
                            .font(.system(size: 15))
                            .foregroundStyle(palette.quiet)
                    }
                }
                .padding(.horizontal, 44)
                .offset(y: compact ? -16 : -25)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 0) {
                        Spacer()
                        Button(action: close) {
                            HStack(spacing: 8) {
                                Text(Copy.text("结束休息", "End break"))
                                Text("esc").font(.system(size: 10, design: .monospaced))
                                    .opacity(0.65).accessibilityHidden(true)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.ink)
                            .padding(.vertical, 8).padding(.horizontal, 13)
                            .background(palette.paper.opacity(0.75), in: Capsule())
                            .overlay { Capsule().strokeBorder(palette.hairline, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, compact ? 22 : 38)
                    .padding(.bottom, 15)

                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        let uptime = ProcessInfo.processInfo.systemUptime
                        let fraction = timing.remaining(at: uptime) / timing.duration
                        let seconds = timing.secondsRemaining(at: uptime)
                        VStack(spacing: 6) {
                            FoxProgressTrack(fox: fox, palette: palette, progress: 1 - fraction,
                                             motion: motion, frame: Int(uptime * 6))
                                .frame(width: min(262, geometry.size.width / 3), height: 32)
                                .accessibilityHidden(true)
                            Text(Copy.text("剩余 \(seconds) 秒", seconds == 1 ? "1 second left" : "\(seconds) seconds left"))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(palette.quiet)
                        }
                    }
                    .padding(.bottom, compact ? 23 : 32)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct FoxProgressTrack: View {
    let fox: [FoxPose: CGImage]
    let palette: Palette
    let progress: Double
    let motion: Bool
    let frame: Int

    private static let gait: [FoxPose] = [.step, .run, .gather, .step]

    var body: some View {
        GeometryReader { track in
            let width = track.size.width
            let x = 16 + max(0, width - 32) * progress
            ZStack(alignment: .bottomLeading) {
                Capsule().fill(palette.hairline).frame(height: 2)
                Capsule().fill(palette.accent.opacity(0.72)).frame(width: width * progress, height: 2)
                let pose = motion ? Self.gait[frame % Self.gait.count] : .stand
                if let image = fox[pose] {
                    Image(decorative: image, scale: 2)
                        .resizable().scaledToFit()
                        .frame(width: 42, height: 32)
                        .position(x: x, y: 16)
                }
            }
            .animation(motion ? .linear(duration: 0.19) : nil, value: progress)
        }
    }
}

private struct Horizon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for offset in [0.0, 0.065, 0.13] {
            path.move(to: CGPoint(x: 0, y: rect.height * (0.71 + offset)))
            path.addCurve(to: CGPoint(x: rect.width, y: rect.height * (0.63 + offset)),
                          control1: CGPoint(x: rect.width * 0.39, y: rect.height * (0.62 + offset)),
                          control2: CGPoint(x: rect.width * 0.67, y: rect.height * (0.83 + offset)))
        }
        return path
    }
}
