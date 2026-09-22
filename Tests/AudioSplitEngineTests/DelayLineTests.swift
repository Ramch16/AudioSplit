import Foundation
import Testing

import AudioSplitShared
@testable import AudioSplitEngine

/// The delay line is the one piece of realtime DSP in AudioSplit, so it is
/// tested on its own rather than inferred from listening.
@Suite("DelayLine")
struct DelayLineTests {
    /// Build a mono delay line and run blocks through it, returning the output.
    private func run(
        blocks: [[Float]],
        delayFrames: Int,
        capacityFrames: Int = 64,
        maximumDelayFrames: Int? = nil
    ) -> [Float] {
        let channels = 1
        let storage = UnsafeMutablePointer<Float>.allocate(
            capacity: capacityFrames * channels
        )
        storage.initialize(repeating: 0, count: capacityFrames * channels)
        defer { storage.deallocate() }

        let line = UnsafeMutablePointer<DelayLine>.allocate(capacity: 1)
        line.initialize(to: DelayLine(
            storage: storage,
            capacityFrames: Int32(capacityFrames),
            channels: Int32(channels),
            writeIndex: 0,
            maximumDelayFrames: Int32(maximumDelayFrames ?? (capacityFrames - 16))
        ))
        defer { line.deallocate() }

        var output: [Float] = []
        for block in blocks {
            var destination = [Float](repeating: .nan, count: block.count)
            block.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer { sink in
                    delayLineProcess(
                        line,
                        source: source.baseAddress!,
                        sourceChannels: channels,
                        destination: sink.baseAddress!,
                        frames: block.count,
                        delayFrames: delayFrames
                    )
                }
            }
            output += destination
        }
        return output
    }

    @Test("zero delay passes audio straight through")
    func zeroDelayIsPassThrough() {
        let input: [Float] = (0 ..< 8).map(Float.init)
        #expect(run(blocks: [input], delayFrames: 0) == input)
    }

    @Test("a delay shifts the signal by exactly that many frames")
    func delaysByRequestedFrames() {
        let first: [Float] = [1, 2, 3, 4]
        let second: [Float] = [5, 6, 7, 8]

        let output = run(blocks: [first, second], delayFrames: 4)
        // The first block comes out as the silence the buffer started with; the
        // second block delivers the first block's audio.
        #expect(Array(output.prefix(4)) == [0, 0, 0, 0])
        #expect(Array(output.suffix(4)) == first)
    }

    @Test("a partial delay lines up across the block boundary")
    func delaysAcrossBlockBoundary() {
        let first: [Float] = [1, 2, 3, 4]
        let second: [Float] = [5, 6, 7, 8]

        let output = run(blocks: [first, second], delayFrames: 2)
        #expect(Array(output.prefix(4)) == [0, 0, 1, 2])
        #expect(Array(output.suffix(4)) == [3, 4, 5, 6])
    }

    @Test("audio survives wrapping around the end of the buffer")
    func wrapsWithoutCorruption() {
        // Ten blocks through a 16-frame buffer wraps several times.
        let blocks = (0 ..< 10).map { index in
            (0 ..< 6).map { Float(index * 6 + $0 + 1) }
        }
        let output = run(
            blocks: blocks,
            delayFrames: 6,
            capacityFrames: 16,
            maximumDelayFrames: 10
        )
        let flattened = blocks.flatMap(\.self)

        #expect(Array(output.prefix(6)) == [0, 0, 0, 0, 0, 0])
        // Everything after the first block is the input, shifted by one block.
        #expect(Array(output.dropFirst(6)) == Array(flattened.dropLast(6)))
    }

    @Test("a delay beyond the buffer is clamped instead of reading garbage")
    func clampsExcessiveDelay() {
        let first: [Float] = [1, 2, 3, 4]
        let second: [Float] = [5, 6, 7, 8]

        // Ask for far more delay than the line can hold.
        let output = run(
            blocks: [first, second],
            delayFrames: 10_000,
            capacityFrames: 16,
            maximumDelayFrames: 8
        )
        #expect(output.count == 8)
        #expect(!output.contains { $0.isNaN })
    }

    @Test("milliseconds convert to frames at the device's rate")
    func convertsMilliseconds() {
        #expect(DelayLimits.frames(forMilliseconds: 0, sampleRate: 48000) == 0)
        #expect(DelayLimits.frames(forMilliseconds: 100, sampleRate: 48000) == 4800)
        #expect(DelayLimits.frames(forMilliseconds: 500, sampleRate: 44100) == 22050)
        // Past the cap, clamped rather than extrapolated.
        #expect(DelayLimits.frames(forMilliseconds: 10_000, sampleRate: 48000) == 24000)
        #expect(DelayLimits.frames(forMilliseconds: -5, sampleRate: 48000) == 0)
    }

    @Test("capacity leaves room for a full block at maximum delay")
    func capacityIncludesBlockHeadroom() {
        let capacity = DelayLimits.capacityFrames(sampleRate: 48000, maximumBlockFrames: 4096)
        #expect(capacity == 24000 + 4096)
    }
}
