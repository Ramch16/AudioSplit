import Foundation

// Shared because the iPhone remote draws the same delay slider and must
// agree with the Mac on the cap. Pure arithmetic, no Core Audio.
public enum DelayLimits {
    /// Hard cap on delay. The buffer is sized for this at route creation.
    public static let maximumMilliseconds: Double = 500

    /// Frames needed for the cap at a given rate, plus a cycle of headroom so a
    /// maximum delay never collides with the block being written.
    public static func capacityFrames(sampleRate: Double, maximumBlockFrames: Int) -> Int {
        let delayFrames = Int((maximumMilliseconds / 1000 * sampleRate).rounded(.up))
        return delayFrames + max(maximumBlockFrames, 1)
    }

    public static func frames(forMilliseconds milliseconds: Double, sampleRate: Double) -> Int {
        let clamped = min(max(milliseconds, 0), maximumMilliseconds)
        return Int((clamped / 1000 * sampleRate).rounded())
    }
}
