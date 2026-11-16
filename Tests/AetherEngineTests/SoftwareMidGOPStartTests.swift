import Foundation
import Testing
@testable import AetherEngine

// =====================================================================================
// Software path: a load at a start position inside a GOP
//
// `load(startPosition:)` seeks the demuxer back to the keyframe at or before the start, so the
// first samples it reads are up to one GOP early. The demux loop used to read a lead-in longer
// than the 2 s anchor tolerance as a mid-stream join and anchored the clock on the keyframe,
// while the video decoder and renderer kept hiding every frame before the start. Sound and
// clock ran from the keyframe; the picture waited until the clock reached the start (Lumen,
// tvOS Simulator: anchor 26.53 s for a start at 35.16 s, then 12 s with no frame).
//
// AE#724 fixed the rule (`SWClockAnchorPolicy` re-anchors only on a sample AHEAD of the
// anchor). `SWClockAnchorPolicyTests` pins the rule; these pin what the viewer gets from it, by
// running the real host against `LongGOPFixture` (keyframes at 0 s and 10 s), starting 8.5 s
// into the first GOP, the shape of that report.
// =====================================================================================
@Suite("Software host: a start inside a GOP begins sound, clock and picture together", .serialized)
struct SoftwareMidGOPStartTests {

    /// 8.5 s past the keyframe at 0 s, 1.5 s before the next one.
    static let start = 8.5

    /// Generous for a 34-frame decode of a 32x32 picture; the old failure never presents at all
    /// while paused, and presents only after ~4.5 s of clock while playing.
    static let firstFrameDeadline: TimeInterval = 5

    @MainActor
    private func loadedHost() async throws -> SoftwarePlaybackHost {
        let host = SoftwarePlaybackHost()
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: LongGOPFixture.data))
        try await host.load(demuxer: demuxer, startPosition: Self.start, audioSourceStreamIndex: nil)
        return host
    }

    /// Waits for the first decoded frame to reach the renderer and returns the raw clock at that
    /// moment, or nil when none arrived in time.
    @MainActor
    private func clockAtFirstFrame(_ host: SoftwarePlaybackHost) async throws -> Double? {
        let deadline = Date().addingTimeInterval(Self.firstFrameDeadline)
        while host.framesEnqueued == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard host.framesEnqueued > 0 else { return nil }
        return host.clockSecondsForTesting
    }

    /// Lumen's return from the Home Screen: reload at the playhead, then hold it paused. The #104
    /// path keeps the loops reading at the stopped clock until a picture is in, so the frame at the
    /// start must arrive without Play and the clock must stand on it, not on the keyframe.
    @MainActor
    @Test("a paused load inside a GOP shows the picture at the start, with the clock on it")
    func pausedLoadPresentsTheStart() async throws {
        let host = try await loadedHost()
        defer { host.stop() }
        host.play()
        host.pause()

        let clock = try #require(try await clockAtFirstFrame(host),
                                 "no picture while paused: the clock went back to the keyframe")
        // The stopped clock is moved onto the first presented frame, which is the first frame at
        // or after the start.
        #expect(clock >= Self.start - 0.001)
        #expect(clock < Self.start + LongGOPFixture.frameIntervalSeconds + 0.001)
        #expect(host.clockRateForTesting == 0)
    }

    /// A resume that plays straight away: the clock must start on the start position and stay
    /// there for the picture, not run up from the keyframe ahead of it.
    @MainActor
    @Test("a playing load inside a GOP runs its clock from the start, not from the keyframe")
    func playingLoadRunsFromTheStart() async throws {
        let host = try await loadedHost()
        defer { host.stop() }
        host.play()

        let clock = try #require(try await clockAtFirstFrame(host),
                                 "no picture within \(Self.firstFrameDeadline) s of Play")
        #expect(clock >= Self.start - 0.001)
        // The lead-in decodes in a few milliseconds here; a clock that ran from the keyframe would
        // read ~4.5 s at this point instead.
        #expect(clock < Self.start + 1.0)
    }
}
