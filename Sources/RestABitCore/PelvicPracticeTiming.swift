import Foundation

public enum PelvicPracticeTiming {
    public enum Phase: Equatable { case prepare, squeeze, release, finished }

    public struct Cue: Equatable {
        public let phase: Phase
        public let round: Int
        public let secondsLeft: Int
        public let progress: Double
    }

    public static let rounds = 5
    public static let prepareSeconds: TimeInterval = 3
    public static let squeezeSeconds: TimeInterval = 3
    public static let releaseSeconds: TimeInterval = 6
    public static let cycleSeconds = squeezeSeconds + releaseSeconds
    public static let exerciseSeconds = cycleSeconds * Double(rounds)
    public static let duration = prepareSeconds + exerciseSeconds

    public static func foxKeyframes(frameCount: Int) -> [(time: TimeInterval, frame: Int)] {
        var keys: [(time: TimeInterval, frame: Int)] = [(0, 0)]
        guard frameCount > 1 else { return keys }
        let last = frameCount - 1
        for round in 0..<rounds {
            let squeezeAt = prepareSeconds + Double(round) * cycleSeconds
            let releaseAt = squeezeAt + squeezeSeconds
            for index in 1...last {
                let fraction = Double(index) / Double(last)
                keys.append((squeezeAt + 1.02 * fraction, index))
            }
            for index in 1...last {
                let fraction = Double(index) / Double(last)
                keys.append((releaseAt + 1.16 * fraction, last - index))
            }
        }
        return keys
    }

    public static func cue(elapsed: TimeInterval) -> Cue {
        let elapsed = max(0, elapsed)
        if elapsed < prepareSeconds {
            return Cue(phase: .prepare, round: 0, secondsLeft: Int(ceil(prepareSeconds - elapsed)), progress: 0)
        }
        let practice = elapsed - prepareSeconds
        if practice >= exerciseSeconds {
            return Cue(phase: .finished, round: rounds, secondsLeft: 0, progress: 1)
        }
        let round = Int(practice / cycleSeconds) + 1
        let position = practice.truncatingRemainder(dividingBy: cycleSeconds)
        let squeezing = position < squeezeSeconds
        let endsAt = squeezing ? squeezeSeconds : cycleSeconds
        return Cue(phase: squeezing ? .squeeze : .release, round: round,
                   secondsLeft: Int(ceil(endsAt - position)), progress: practice / exerciseSeconds)
    }
}
