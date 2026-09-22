import Foundation

// =====================================================================================
// Rewrite the captured init segment's `dec3` box from the real E-AC-3 bitstream
// =====================================================================================
//
// For an 8-channel E-AC-3 JOC source (5.1 bed in the independent substream, the two height
// channels plus the JOC metadata in a DEPENDENT substream) FFmpeg's `handle_eac3()` writes a
// `dec3` that says `num_dep_sub = 1, chan_loc = 0` and carries no JOC extension. tvOS cannot map
// a dependent substream it has not been told the channels of, so it decodes the 5.1 core and the
// receiver reports multichannel PCM instead of Dolby Atmos. FFmpegBuild ships prebuilt
// xcframeworks, so the muxer is not patchable from here.
//
// The init segment is captured as `Data` on its way out of the muxer, which is the last point
// before any client sees it, so the correction happens there: re-derive the box from the audio
// bitstream the muxer just wrote (`EAC3Bitstream`), re-encode it (`EC3SpecificBox`), and splice
// it back in with every ancestor box length reconciled (`MP4BoxTree`).
//
// This is deliberately conservative. It runs ONLY for a stream-copied E-AC-3 track, only when
// both the existing box and the bitstream parse cleanly, only when the two agree about the bed
// (`fscod`/`acmod`/`lfeon`; `bsid` is excluded on purpose, see the gate below), and only when the
// re-encoded payload actually differs. Any other outcome leaves the segment byte-for-byte
// untouched.
// =====================================================================================

enum InitSegmentDec3Rewrite {

    /// The `dec3` box's path inside a fragmented-MP4 init segment. `MP4BoxTree.find` backtracks
    /// over the `trak` boxes, so naming `ec-3` is what selects the audio track.
    static let dec3Path = ["moov", "trak", "mdia", "minf", "stbl", "stsd", "ec-3", "dec3"]

    /// Escape hatch, mirroring `MP4SegmentMuxer.nalChainSanitizerDisabled`: set to measure the
    /// unpatched box on a rig, or to rule this code out of a playback regression, without a build.
    static let disabled = ProcessInfo.processInfo.environment["AETHER_DISABLE_DEC3_REWRITE"] != nil

    /// Why a rewrite did not happen, for the log and for tests.
    enum Skip: Error, Equatable {
        case disabledByEnvironment
        case notStreamCopiedEAC3
        case noDec3Box
        case unparseableDec3
        case noParsableSyncFrames
        /// The bitstream and the muxer's box disagree about the independent substream's own
        /// parameters, so the header reader is out of step with reality and must not be trusted
        /// to rewrite anything.
        case bedMismatch(existing: String, parsed: String)
        /// Nothing to fix: the re-derived payload is identical to the one already there.
        case alreadyCorrect
    }

    struct Rewrite: Equatable {
        var bytes: [UInt8]
        var beforePayload: [UInt8]
        var afterPayload: [UInt8]
        var before: EC3SpecificBox
        var after: EC3SpecificBox
        /// The dependent substreams' raw 16-bit `chanmap` values the decision was made from.
        /// Logged because the chanmap -> chan_loc bit order is the one part of this that only a
        /// real receiver can confirm.
        var chanmaps: [UInt16]
    }

    /// Attempt the rewrite.
    ///
    /// - Parameters:
    ///   - initBytes: the captured `ftyp` + `moov` init segment.
    ///   - audioBitstream: raw bytes of one muxed E-AC-3 packet (an independent syncframe
    ///     immediately followed by its dependent syncframe(s)).
    ///   - isStreamCopiedEAC3: false for a bridged/encoded track, which has no objects to
    ///     describe and must be left exactly as the muxer wrote it.
    ///   - jocDetectedByEngine: the engine's own JOC verdict (`AVCodecParameters.profile == 30`),
    ///     used only as a fallback when the `addbsi` walk found no extension.
    static func rewrite(
        initBytes: [UInt8],
        audioBitstream: [UInt8],
        isStreamCopiedEAC3: Bool,
        jocDetectedByEngine: Bool
    ) -> Result<Rewrite, Skip> {
        guard !disabled else { return .failure(.disabledByEnvironment) }
        guard isStreamCopiedEAC3 else { return .failure(.notStreamCopiedEAC3) }

        guard let chain = MP4BoxTree.find(path: dec3Path, in: initBytes), let dec3 = chain.last else {
            return .failure(.noDec3Box)
        }
        let existingPayload = Array(initBytes[dec3.payloadRange])
        guard let existing = EC3SpecificBox.parse(payload: existingPayload) else {
            return .failure(.unparseableDec3)
        }

        let frames = EAC3Bitstream.parseSyncFrames(audioBitstream)
        guard let derived = EC3SpecificBox.derived(
            fromSyncFrames: frames,
            dataRate: existing.dataRate,
            jocDetectedByEngine: jocDetectedByEngine
        ) else {
            return .failure(.noParsableSyncFrames)
        }

        // Sanity gate. The bed parameters come from the independent syncframe header's very first
        // fields, the ones both this reader and FFmpeg's parser agree on; if they do not match
        // what the muxer wrote, the packet we were handed is not the packet the box describes (or
        // the walk drifted), and the safe answer is to change nothing.
        guard derived.substreams.count == existing.substreams.count else {
            return .failure(.bedMismatch(existing: bedDescription(existing), parsed: bedDescription(derived)))
        }
        // `bsid` is deliberately NOT part of the gate. It is one of the fields a wrong box can get
        // wrong (an E-AC-3 syncframe always carries bsid 16, and a `dec3` claiming an AC-3-era
        // value is itself a defect), so it has to be correctable rather than a reason to bail.
        for (e, d) in zip(existing.substreams, derived.substreams) {
            guard e.fscod == d.fscod, e.acmod == d.acmod, e.lfeon == d.lfeon else {
                return .failure(.bedMismatch(existing: bedDescription(existing), parsed: bedDescription(derived)))
            }
        }

        let newPayload = derived.encodePayload()
        guard newPayload != existingPayload else { return .failure(.alreadyCorrect) }
        guard let patched = MP4BoxTree.replacingPayload(of: chain, in: initBytes, with: newPayload) else {
            return .failure(.noDec3Box)
        }

        return .success(Rewrite(
            bytes: patched,
            beforePayload: existingPayload,
            afterPayload: newPayload,
            before: existing,
            after: derived,
            chanmaps: frames.compactMap { $0.streamType == .dependent ? $0.chanmap : nil }
        ))
    }

    /// Compact, greppable description of the independent substreams, for the log and the
    /// mismatch diagnostic.
    static func bedDescription(_ box: EC3SpecificBox) -> String {
        box.substreams
            .map { "fscod=\($0.fscod) bsid=\($0.bsid) acmod=\($0.acmod) lfeon=\($0.lfeon ? 1 : 0) "
                 + "num_dep_sub=\($0.numDepSub) chan_loc=0x\(String(format: "%03X", $0.chanLoc))" }
            .joined(separator: " | ")
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// The single line emitted when a rewrite lands.
    static func logLine(_ r: Rewrite) -> String {
        let maps = r.chanmaps.isEmpty
            ? "none"
            : r.chanmaps.map { "0x" + String(format: "%04X", $0) }.joined(separator: ",")
        return "[InitSegmentDec3Rewrite] dec3 rewritten from the E-AC-3 bitstream: "
            + "[\(hex(r.beforePayload))] -> [\(hex(r.afterPayload))]; "
            + "\(bedDescription(r.after)); "
            + "dependent chanmap=\(maps); "
            + "JOC extension "
            + (r.after.ec3ExtensionTypeA
               ? "present (complexity_index_type_a=\(r.after.complexityIndexTypeA))"
               : "absent")
            + "; box grew by \(r.afterPayload.count - r.beforePayload.count) B"
    }
}
