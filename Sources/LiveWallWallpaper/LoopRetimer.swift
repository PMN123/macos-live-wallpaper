// LiveWallWallpaper — sample retiming for gapless looping.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: the ptsOffset / lastEnqueuedEnd logic and offsetTimingForLoop in
// PhospheneExtension/VideoRenderer.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// The display layer's timeline never restarts while one video loops: each new pass
// through the file is shifted to start where the previous one ended, so presentation
// and decode timestamps keep increasing and no flush (which would blank or stall the
// decoder) is needed at the loop boundary. Kept free of AVFoundation state so the
// scratch harness can drive it with real samples.

import CoreMedia

struct LoopRetimer {
    /// Offset added to the current pass's sample times.
    private(set) var offset: CMTime = .zero
    /// Latest presentation end (PTS + duration) enqueued so far, on the shifted timeline.
    /// A max, not the last sample's: B-frames arrive out of presentation order.
    private(set) var lastEnd: CMTime = .zero
    /// Highest decode timestamp enqueued so far, on the shifted timeline.
    private(set) var lastDecode: CMTime = .invalid
    /// Length of one pass, learned when the first pass ends.
    private(set) var passDuration: CMTime = .invalid
    /// Earliest presentation time seen in the first pass (which always runs at offset
    /// zero), normally zero.
    private var firstPassMinPTS: CMTime = .invalid
    /// Set at a loop boundary: the next sample fixes the new pass's offset.
    private var passPending = false

    /// Start over on a fresh timeline (a new video, or a decoder reset).
    mutating func reset() {
        self = LoopRetimer()
    }

    /// Where to start a new reader so playback continues at timeline `time` (deep-pause
    /// wake), and the offset that maps that pass back onto the timeline. Near a loop
    /// boundary the clock can still be in the previous pass while the current offset
    /// already belongs to the next one; that case steps back one pass.
    func resumePoint(forTimelineTime time: CMTime) -> (clipTime: CMTime, offset: CMTime) {
        guard time.isNumeric else { return (.zero, offset) }
        var clip = CMTimeSubtract(time, offset)
        var passOffset = offset
        if clip < .zero, passDuration.isNumeric, passDuration > .zero {
            clip = CMTimeAdd(clip, passDuration)
            passOffset = CMTimeSubtract(offset, passDuration)
        }
        if clip < .zero { clip = .zero }
        return (clip, passOffset)
    }

    /// Continue the timeline after the readers were rebuilt mid-pass (deep-pause wake):
    /// keep what is known about the clip; the decoder was flushed, so decode order
    /// restarts.
    mutating func resume(atTimelineTime time: CMTime, offset passOffset: CMTime) {
        offset = passOffset
        lastEnd = time
        lastDecode = .invalid
        passPending = false
    }

    /// The current reader ran out; the next sample starts a new pass.
    mutating func beginNextPass() {
        if !passDuration.isValid, lastEnd.isValid, lastEnd > .zero {
            let start = firstPassMinPTS.isValid ? firstPassMinPTS : .zero
            passDuration = CMTimeSubtract(lastEnd, start)
        }
        passPending = true
    }

    /// Shift `sample` onto the continuous timeline and record its times. The first pass
    /// is returned unchanged (offset zero); later passes get a timing-only copy that
    /// shares the sample data.
    mutating func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        if passPending {
            passPending = false
            // Start the new pass where the previous one ended, then make sure its first
            // decode timestamp still lands after the last one enqueued.
            let start = firstPassMinPTS.isValid ? firstPassMinPTS : .zero
            var newOffset = CMTimeSubtract(lastEnd, start)
            let dts = CMSampleBufferGetDecodeTimeStamp(sample)
            let decode = dts.isValid ? dts : CMSampleBufferGetPresentationTimeStamp(sample)
            if decode.isValid, lastDecode.isValid {
                let shiftedDTS = CMTimeAdd(decode, newOffset)
                if shiftedDTS <= lastDecode {
                    let tick = CMTime(value: 1, timescale: max(decode.timescale, 600))
                    newOffset = CMTimeAdd(newOffset, CMTimeAdd(CMTimeSubtract(lastDecode, shiftedDTS), tick))
                }
            }
            offset = newOffset
        }

        let adjusted = offset == .zero ? sample : Self.shifted(sample, by: offset)
        record(adjusted)
        return adjusted
    }

    /// Record an already-timed sample (the first frame of a pipeline, enqueued as is).
    mutating func record(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)
        // Containers sometimes emit padding samples with invalid PTS; skip those so NaN
        // never poisons the offset.
        if pts.isValid {
            let end = (dur.isValid && dur > .zero) ? CMTimeAdd(pts, dur) : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
            if end > lastEnd { lastEnd = end }
            // Until the first pass ends (it always runs at offset zero), learn where the
            // clip starts. The pipeline's first frame arrives here through record() alone.
            if !passDuration.isValid, !firstPassMinPTS.isValid || pts < firstPassMinPTS {
                firstPassMinPTS = pts
            }
        }
        let decode = dts.isValid ? dts : pts
        if decode.isValid, !lastDecode.isValid || decode > lastDecode {
            lastDecode = decode
        }
    }

    /// Where in the clip a timeline time falls, for snapshots: the current pass's
    /// offset removed and wrapped into one pass. Approximate at a loop boundary, where
    /// the next pass's samples are enqueued ahead of the frame on screen.
    func clipTime(forTimelineTime time: CMTime) -> CMTime {
        guard time.isNumeric else { return .zero }
        let t = CMTimeSubtract(time, offset)
        guard passDuration.isNumeric, passDuration > .zero else {
            return t > .zero ? t : .zero
        }
        var seconds = t.seconds.truncatingRemainder(dividingBy: passDuration.seconds)
        if seconds < 0 { seconds += passDuration.seconds }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A copy of `sample` with every timing entry moved by `offset`.
    static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else {
            return sample
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return sample
        }
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var adjusted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &adjusted
        )
        guard status == noErr, let adjusted else { return sample }
        return adjusted
    }
}
