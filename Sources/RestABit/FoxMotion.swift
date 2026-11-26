import AppKit
import ImageIO
import QuartzCore
import RestABitCore

enum FoxPose: String, CaseIterable {
    case peek, run, gather, brake, look, rest
    case stand, lookBack, settle, step, stretch, land
    case blinkOpen, blinkHalf, blinkClosed, blinkCrouch, blinkAir, blinkLand
    case frontLeft, frontGather, frontRight, frontStand
    case rearLeft, rearGather, rearRight, rearStand, rearTurnStart, rearTurnMiddle, rearLook
    case drinkLower, drinkSip, drinkSwallow

    var substitute: FoxPose? {
        switch self {
        case .stand, .lookBack: .look
        case .settle: .peek
        case .step: .gather
        case .stretch, .land: .brake
        case .blinkOpen, .blinkHalf, .blinkClosed, .blinkCrouch, .blinkAir, .blinkLand: .look
        case .frontLeft, .frontRight, .rearLeft, .rearRight: .blinkAir
        case .frontGather, .rearGather: .blinkCrouch
        case .frontStand, .rearStand: .blinkOpen
        case .rearTurnStart: .rearStand
        case .rearTurnMiddle: .lookBack
        case .rearLook: .frontStand
        case .drinkLower, .drinkSip, .drinkSwallow: .stretch
        default: nil
        }
    }
}

@MainActor
final class FoxArt {
    private var sources: [FoxPose: URL]
    private var images: [FoxPose: CGImage] = [:]

    init?() {
        var sources: [FoxPose: URL] = [:]
        for pose in FoxPose.allCases {
            if let url = Bundle.module.url(forResource: pose.rawValue, withExtension: "png", subdirectory: "Assets") {
                sources[pose] = url
            } else if pose.substitute == nil {
                return nil
            }
        }
        self.sources = sources
    }

    var hasBlinkSequence: Bool {
        [FoxPose.blinkOpen, .blinkHalf, .blinkClosed, .blinkCrouch, .blinkAir, .blinkLand]
            .allSatisfy { sources[$0] != nil }
    }

    #if DEBUG
    var hasWaterPoses: Bool {
        [FoxPose.drinkLower, .drinkSip, .drinkSwallow].allSatisfy { sources[$0] != nil }
    }

    var hasDirectionalGaits: Bool {
        let frames: [FoxPose] = [.frontLeft, .frontGather, .frontRight, .frontStand,
                                 .rearLeft, .rearGather, .rearRight, .rearStand,
                                 .rearTurnStart, .rearTurnMiddle, .rearLook]
        return frames.allSatisfy { sources[$0] != nil }
    }
    #endif

    func prepare(_ poses: [FoxPose]) {
        for pose in Set(poses) { _ = self[pose] }
    }

    subscript(pose: FoxPose) -> CGImage? {
        if let image = images[pose] { return image }
        if let url = sources[pose] {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                images[pose] = image
                return image
            }
            sources[pose] = nil
        }
        return pose.substitute.flatMap { self[$0] }
    }
}

struct FoxClip {
    struct Pose {
        let time: Double
        let frame: FoxPose

        init(_ time: Double, _ frame: FoxPose) {
            self.time = time
            self.frame = frame
        }
    }

    struct Point {
        let time: Double
        let position: CGPoint

        init(_ time: Double, _ x: Double, _ y: Double) {
            self.time = time
            position = CGPoint(x: x, y: y)
        }
    }

    let duration: Double
    let mirrored: Bool
    let points: [Point]
    let poses: [Pose]
    var arrivalTime: Double? = nil
    var pacedPath = false
    var angles: [(time: Double, angle: Double)] = []

    static func entrance(to landing: Landing, kind: Reminder, motion: EdgeMotion) -> FoxClip {
        let stage = landing.stage
        let dx = Double(landing.stop.x - landing.entry.x)
        let dy = Double(landing.stop.y - landing.entry.y)
        let distance = hypot(dx, dy)
        let ux = dx / distance
        let uy = dy / distance
        let originX = Double(landing.entry.x - stage.minX)
        let originY = Double(landing.entry.y - stage.minY)

        let depthView = landing.origin == .top || landing.origin == .bottom ||
            (landing.origin.isCorner && abs(dy) > abs(dx) * 1.1)
        let mirrored = !depthView && dx < 0
        let approachesViewer = depthView && dy < 0
        let turnsBack = depthView && !approachesViewer
        let pause: Double
        let pace: Double
        let stride: [FoxPose]
        switch motion {
        case .rotate, .dash:
            pause = 0.055
            pace = 665
            stride = [.gather, .run, .step, .run]
        case .hop:
            pause = 0.11
            pace = 600
            stride = [.gather, .run, .run, .step]
        case .peek:
            pause = 0.19
            pace = 555
            stride = [.step, .gather, .step, .land]
        }

        let gait: [FoxPose]
        let waiting: FoxPose
        let standing: FoxPose
        if approachesViewer {
            gait = [.frontLeft, .frontGather, .frontRight, .frontGather]
            waiting = .frontGather
            standing = .frontStand
        } else if depthView {
            gait = [.rearLeft, .rearGather, .rearRight, .rearGather]
            waiting = .rearGather
            standing = .rearStand
        } else {
            gait = stride
            waiting = .peek
            standing = .stand
        }

        let reveal = 0.34
        let leaveEdge = reveal + pause
        let travel = min(1.92, max(0.90, distance / pace + (approachesViewer ? 0.14 : 0)))
        let arrival = leaveEdge + travel
        let duration = arrival + (turnsBack ? 0.56 : 0.27)
        let peekDistance = min(distance * 0.23, landing.origin.isCorner ? 43 : 18)
        let curve = min(43, min(abs(dx), abs(dy)) * (motion == .hop ? 0.17 : 0.11))
        let frames = Int(ceil(duration * 90))
        let steps = max(7, min(16, Int(travel * (motion == .peek ? 9 : 11))))
        var poses = [Pose(0, waiting)]
        if !depthView && motion == .peek { poses.append(Pose(reveal, .lookBack)) }
        var step = -1

        let points = (0...frames).map { frame -> Point in
            let t = Double(frame) * duration / Double(frames)
            let progress = ease((t - leaveEdge) / travel)
            let forward = t < reveal
                ? -112 + (112 + peekDistance) * ease(t / reveal)
                : peekDistance + (distance - peekDistance) * progress
            let arch = sin(progress * .pi)
            // Keep the bend shallow so a fox never has to double back to reach the target.
            let lateral = curve * arch * arch

            if t >= leaveEdge && t < arrival - 0.095 {
                let next = Int(progress * Double(steps))
                if next != step {
                    step = next
                    poses.append(Pose(t, gait[next % gait.count]))
                }
            }
            let x = originX + ux * forward - uy * lateral
            let hopLift = motion == .hop && !depthView ? 12 * arch * arch : 0
            let y = originY + uy * forward + ux * lateral + hopLift
            return Point(t, mirrored ? Double(stage.width) - x : x, y)
        }

        poses.append(Pose(arrival - 0.09, depthView ? gait.last ?? waiting : .step))
        poses.append(Pose(arrival, standing))
        if turnsBack {
            poses += [Pose(arrival + 0.11, .rearTurnStart),
                      Pose(arrival + 0.22, .rearTurnMiddle),
                      Pose(arrival + 0.36, .rearLook)]
        } else if !depthView {
            poses.append(Pose(arrival + 0.12, kind == .stand ? .stretch : .look))
        }

        let tilt = depthView ? 0.0 : max(-0.24, min(0.24, atan2(dy, abs(dx)) * 0.48))
        let angles = tilt == 0 ? [] : [
            (time: 0.0, angle: 0.0), (time: leaveEdge, angle: 0.0),
            (time: leaveEdge + 0.27 * travel, angle: tilt),
            (time: arrival - 0.16, angle: tilt), (time: arrival, angle: 0.0),
            (time: duration, angle: 0.0)
        ]
        return FoxClip(duration: duration, mirrored: mirrored, points: points, poses: poses,
                       arrivalTime: arrival, pacedPath: true, angles: angles)
    }

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    static func water() -> FoxClip {
        let duration = 1.86
        let stop = WaterScene.foxStop
        let frames = Int(ceil(duration * 60))
        let points = (0...frames).map { frame -> Point in
            let t = Double(frame) * duration / Double(frames)
            let approach = ease(t / 0.94)
            let x = 46 + (stop.x - 46) * approach
            return Point(t, x, stop.y + 2.4 * sin(approach * 5 * .pi) * sin(approach * .pi))
        }
        return FoxClip(duration: duration, mirrored: false, points: points, poses: [
            Pose(0, .step), Pose(0.18, .gather), Pose(0.34, .step), Pose(0.52, .gather),
            Pose(0.68, .step), Pose(0.85, .stand), Pose(0.96, .drinkLower),
            Pose(1.07, .drinkSip), Pose(1.27, .drinkSwallow), Pose(1.41, .drinkSip),
            Pose(1.60, .drinkSwallow), Pose(1.76, .drinkSip)
        ], pacedPath: true)
    }

    static func blink(in width: CGFloat, motion: BlinkMotion) -> FoxClip {
        let center = Double(width / 2)
        let duration = Reminder.blink.presentationSeconds
        let arrival: [Point]
        let blinkTimes: [Double]
        let angles: [(time: Double, angle: Double)]
        switch motion {
        case .rotate, .hop:
            arrival = [Point(0, center, 27), Point(0.10, center, 30),
                       Point(0.21, center, 74), Point(0.36, center, 110),
                       Point(0.48, center, 103), Point(0.65, center, 67),
                       Point(0.75, center, 73), Point(0.88, center, 70)]
            blinkTimes = [1.02, 1.65]
            angles = []
        case .rise:
            arrival = [Point(0, center, 8), Point(0.18, center, 24), Point(0.36, center, 50),
                       Point(0.51, center, 63), Point(0.78, center, 70), Point(0.92, center, 70)]
            blinkTimes = [1.12, 1.92]
            angles = [(0, -0.10), (0.42, -0.12), (0.76, 0), (duration, 0)]
        case .sway:
            arrival = [Point(0, center, 24), Point(0.28, center, 79), Point(0.58, center, 70),
                       Point(0.87, center - 11, 72), Point(1.11, center - 12, 71),
                       Point(1.51, center + 11, 73), Point(1.84, center + 12, 70),
                       Point(2.19, center, 70)]
            blinkTimes = [0.98, 1.70]
            angles = [(0, 0), (0.56, 0), (0.99, 0.12), (1.32, 0),
                      (1.69, -0.12), (2.12, 0), (duration, 0)]
        }

        let greeting: [Pose] = motion == .rise
            ? [Pose(0, .blinkCrouch), Pose(0.38, .blinkLand), Pose(0.64, .blinkOpen)]
            : [Pose(0, .blinkCrouch), Pose(0.16, .blinkAir), Pose(0.53, .blinkLand), Pose(0.75, .blinkOpen)]
        let blinks = blinkTimes.flatMap { t in
            [Pose(t, .blinkHalf), Pose(t + 0.055, .blinkClosed),
             Pose(t + 0.18, .blinkHalf), Pose(t + 0.24, .blinkOpen)]
        }
        return FoxClip(duration: duration, mirrored: false, points: arrival + [
            Point(2.50, center, 70), Point(2.72, center, 70), Point(2.85, center, 66),
            Point(3.12, center, 39), Point(duration, center, 36)
        ], poses: greeting + blinks + [Pose(2.84, .blinkCrouch)], angles: angles)
    }


}

@MainActor
final class FoxPlayer: NSView {
    private let wrapper = CALayer()
    private let sprite = CALayer()
    private let art: FoxArt

    init(frame: CGRect, art: FoxArt) {
        self.art = art
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(wrapper)
        wrapper.bounds = CGRect(x: 0, y: 0, width: 154, height: 120)
        sprite.frame = wrapper.bounds
        sprite.contentsGravity = .resizeAspect
        sprite.minificationFilter = .trilinear
        wrapper.addSublayer(sprite)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func prepare(_ clip: FoxClip) {
        guard let firstPoint = clip.points.first, let firstPose = clip.poses.first else { return }
        art.prepare(clip.poses.map(\.frame))
        place(firstPose.frame, at: firstPoint.position, mirrored: clip.mirrored,
              tilt: clip.angles.first.map { CGFloat($0.angle) } ?? 0)
    }

    func place(_ pose: FoxPose, at point: CGPoint, mirrored: Bool = false, tilt: CGFloat = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wrapper.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        wrapper.position = position(point, mirrored: mirrored)
        sprite.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        sprite.contents = art[pose]
        CATransaction.commit()
    }

    func play(_ clip: FoxClip) {
        guard let finalPoint = clip.points.last, let finalPose = clip.poses.last else { return }
        let flip = clip.mirrored ? -1.0 : 1.0

        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = clip.points.map { NSValue(point: position($0.position, mirrored: clip.mirrored)) }
        path.keyTimes = clip.points.map { NSNumber(value: $0.time / clip.duration) }
        path.calculationMode = clip.pacedPath ? .linear : .cubic
        path.duration = clip.duration

        let drawings = CAKeyframeAnimation(keyPath: "contents")
        drawings.values = clip.poses.compactMap { art[$0.frame] }
        drawings.keyTimes = clip.poses.map { NSNumber(value: $0.time / clip.duration) } + [1]
        drawings.calculationMode = .discrete
        drawings.duration = clip.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wrapper.setAffineTransform(CGAffineTransform(scaleX: flip, y: 1))
        wrapper.position = position(finalPoint.position, mirrored: clip.mirrored)
        sprite.setAffineTransform(.identity)
        sprite.contents = art[finalPose.frame]
        wrapper.add(path, forKey: "entrance.path")
        if drawings.values?.count == clip.poses.count {
            sprite.add(drawings, forKey: "entrance.drawings")
        }
        if !clip.angles.isEmpty {
            let tilt = CAKeyframeAnimation(keyPath: "transform.rotation")
            tilt.values = clip.angles.map(\.angle)
            tilt.keyTimes = clip.angles.map { NSNumber(value: $0.time / clip.duration) }
            tilt.duration = clip.duration
            sprite.add(tilt, forKey: "entrance.tilt")
        }
        CATransaction.commit()
    }

    private func position(_ point: CGPoint, mirrored: Bool) -> CGPoint {
        CGPoint(x: mirrored ? bounds.width - point.x : point.x, y: point.y)
    }
}
