import Foundation

/// A per-route delay line.
///
/// This is the *only* ring buffer in AudioSplit, and it exists solely to delay
/// one route's audio for lip-sync correction. It is never used to bridge two
/// devices — the aggregate device does that, on one clock, in one IOProc. If a
/// ring buffer ever appears between two IOProcs, the design has gone wrong.
///
/// Plain old data so it can live in preallocated memory the realtime thread
/// reads. Storage is sized for the maximum delay up front and never reallocates;
/// changing the delay only changes how far behind the write head we read.
public struct DelayLine {
    /// Interleaved storage, `capacityFrames * channels` floats.
    var storage: UnsafeMutablePointer<Float>
    var capacityFrames: Int32
    var channels: Int32
    var writeIndex: Int32
    /// Largest delay the storage can express, in frames.
    var maximumDelayFrames: Int32
}

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

/// Write a block into the delay line and read it back `delayFrames` later.
///
/// Realtime safe: no allocation, no locks, no ARC. The copy is split into
/// contiguous runs rather than taking a modulo per sample.
///
/// With `delayFrames == 0` the read head sits exactly on the block just written,
/// so a zero delay is a pass-through rather than a special case.
@inline(__always)
func delayLineProcess(
    _ line: UnsafeMutablePointer<DelayLine>,
    source: UnsafePointer<Float>,
    sourceChannels: Int,
    destination: UnsafeMutablePointer<Float>,
    frames: Int,
    delayFrames: Int
) {
    let capacity = Int(line.pointee.capacityFrames)
    let channels = Int(line.pointee.channels)
    guard capacity > 0, channels > 0, frames > 0 else { return }

    let storage = line.pointee.storage
    let writeIndex = Int(line.pointee.writeIndex)
    let copyChannels = min(channels, sourceChannels)

    // Write the incoming block, wrapping once at most.
    var written = 0
    while written < frames {
        let position = (writeIndex + written) % capacity
        let run = min(frames - written, capacity - position)
        for frame in 0 ..< run {
            let slot = (position + frame) * channels
            let input = (written + frame) * sourceChannels
            for channel in 0 ..< copyChannels {
                storage[slot + channel] = source[input + channel]
            }
            // A delay line narrower than the source simply drops the extra
            // channels; wider is zero-filled rather than left stale.
            for channel in copyChannels ..< channels {
                storage[slot + channel] = 0
            }
        }
        written += run
    }

    // Read from `delayFrames` behind the head.
    let clampedDelay = min(max(delayFrames, 0), Int(line.pointee.maximumDelayFrames))
    let readStart = ((writeIndex - clampedDelay) % capacity + capacity) % capacity
    var read = 0
    while read < frames {
        let position = (readStart + read) % capacity
        let run = min(frames - read, capacity - position)
        for frame in 0 ..< run {
            let slot = (position + frame) * channels
            let output = (read + frame) * channels
            for channel in 0 ..< channels {
                destination[output + channel] = storage[slot + channel]
            }
        }
        read += run
    }

    line.pointee.writeIndex = Int32((writeIndex + frames) % capacity)
}
