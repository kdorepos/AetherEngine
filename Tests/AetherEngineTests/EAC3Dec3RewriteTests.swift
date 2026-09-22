import Testing
import Foundation
@testable import AetherEngine

/// FFmpeg's `movenc.c: handle_eac3()` writes a `dec3` box that describes an 8-channel E-AC-3 JOC
/// source as a bare 5.1 bed: `chan_loc = 0` for the dependent substream and no JOC extension at
/// all (jellyfin/jellyfin-ffmpeg#584). tvOS then cannot map the dependent substream and the
/// receiver reports multichannel PCM instead of Dolby Atmos. FFmpegBuild ships prebuilt
/// xcframeworks, so the fix re-derives the box from the bitstream in Swift and rewrites the
/// captured init segment.
///
/// These cover the three pure pieces of that: the `EC3SpecificBox` codec, the chanmap ->
/// chan_loc mapping, and the MP4 box-length walker, plus the end-to-end decision.
///
/// The byte sequences marked "measured" are real, taken from `aetherctl serve` against the source
/// in `docs/atmos-engine-patch.md` ("28 Years Later", MKV, 8-channel E-AC-3 JOC) and from
/// "Dune: Part Two" (6-channel E-AC-3 JOC, whose box FFmpeg already gets right). Keeping the real
/// bytes here is the point: the bit packing below was derived from the spec, and these are the
/// independent check that the derivation matches what a real muxer and a real encoder produce.
@Suite("E-AC-3 dec3 rewrite")
struct EAC3Dec3RewriteTests {

    // =================================================================================
    // Measured fixtures
    // =================================================================================

    /// Measured. "28 Years Later" as FFmpeg writes it: `data_rate = 640`, one independent
    /// substream (`fscod 0`, `bsid 6` -- the AC-3 core of a Blu-ray-style DD+ track -- `bsmod 0`,
    /// `acmod 7`, `lfeon 1`), `num_dep_sub = 1`, `chan_loc = 0x000`, no JOC extension.
    static let dec3Before: [UInt8] = [0x14, 0x00, 0x0C, 0x0F, 0x02, 0x00]

    /// What this code produces for the same source: `chan_loc = 0x040` (the Lvh/Rvh pair the
    /// dependent substream's `chanmap` declares) plus the two ETSI TS 103 420 extension bytes.
    static let dec3After: [UInt8] = [0x14, 0x00, 0x0C, 0x0F, 0x02, 0x40, 0x01, 0x10]

    /// Measured. "Dune: Part Two": `data_rate = 1024`, `bsid = 16` (a real E-AC-3 independent
    /// substream), `num_dep_sub = 0` -- so the substream entry is the 3-byte form -- and the JOC
    /// extension already present, because this source carries JOC in the INDEPENDENT substream
    /// where `handle_eac3()` does look for it.
    static let dec3Dune: [UInt8] = [0x20, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10]

    /// Measured. First 24 bytes of the AC-3 core syncframe of "28 Years Later": `bsid 6` (Annex D
    /// alternate bit stream syntax), 640 kbps, `acmod 7` + `lfeon 1` = 5.1, frame length 2560 B.
    static let ac3CoreHeader: [UInt8] = [
        0x0B, 0x77, 0x5B, 0x17, 0x24, 0x30, 0xE1, 0xFF, 0xFC, 0xE2, 0x69, 0xC0,
        0x00, 0x03, 0xE9, 0x55, 0xE1, 0x86, 0x18, 0x61, 0xFF, 0x3A, 0xBE, 0x7C,
    ]

    /// Measured. First 24 bytes of the E-AC-3 DEPENDENT syncframe that follows it: `strmtyp 1`,
    /// `substreamid 0`, `bsid 16`, `acmod 5`, `lfeon 0`, frame length 3584 B, custom
    /// `chanmap = 0xA010`, and an `addbsi` carrying `flag_ec3_extension_type_a = 1` with
    /// `complexity_index_type_a = 16`.
    static let eac3DependentHeader: [UInt8] = [
        0x0B, 0x77, 0x46, 0xFF, 0x3A, 0x87, 0xFF, 0xFA, 0x01, 0x02, 0x08, 0x08,
        0x80, 0x0D, 0x00, 0x00, 0x00, 0x14, 0x02, 0x00, 0xC3, 0x0C, 0x30, 0xFF,
    ]

    /// One muxed packet's worth of bitstream: the two real headers, each zero-padded out to the
    /// frame length its own header declares, so the syncframe walk has to step by the right
    /// number of bytes to find the second frame at all.
    static func onePacket() -> [UInt8] {
        var out = ac3CoreHeader
        out += [UInt8](repeating: 0, count: 2560 - ac3CoreHeader.count)
        out += eac3DependentHeader
        out += [UInt8](repeating: 0, count: 3584 - eac3DependentHeader.count)
        return out
    }

    // =================================================================================
    // Bit reader / writer
    // =================================================================================

    @Test("bit reader is MSB-first across byte boundaries and refuses to overrun")
    func bitReader() {
        var r = EAC3BitReader([0b1010_1100, 0b0011_0101])
        #expect(r.read(3) == 0b101)
        #expect(r.read(7) == 0b0_1100_00)
        #expect(r.read(6) == 0b11_0101)
        #expect(r.read(1) == nil)          // exhausted
        #expect(r.bitsRemaining == 0)

        var overrun = EAC3BitReader([0xFF])
        #expect(overrun.read(9) == nil)
        #expect(overrun.bitsRemaining == 8) // cursor did not move
        #expect(overrun.skip(9) == false)
    }

    @Test("bit writer mirrors the reader and zero-pads the final byte")
    func bitWriter() {
        var w = EAC3BitWriter()
        w.write(0b101, bits: 3)
        w.write(0b0110000, bits: 7)
        #expect(w.finish() == [0b1010_1100, 0b0000_0000])

        // Round-trip the measured box: what the writer emits, the reader must read back.
        var rt = EAC3BitWriter()
        rt.write(640, bits: 13)
        rt.write(0, bits: 3)
        var back = EAC3BitReader(rt.finish())
        #expect(back.read(13) == 640)
        #expect(back.read(3) == 0)
    }

    // =================================================================================
    // chanmap -> chan_loc (ETSI TS 102 366 F.6.2.3 / Table F.6.1)
    // =================================================================================

    @Test("chanmap maps to chan_loc in spec bit order")
    func chanmapMapping() {
        // The nine chan_loc bits, each from its own chanmap transmission bit. `chanmap` is read
        // MSB-first, so transmission bit t is integer bit 15 - t.
        let pairs: [(chanLocBit: Int, chanmapTransmissionBit: Int, name: String)] = [
            (0, 5, "Lc/Rc"), (1, 6, "Lrs/Rrs"), (2, 7, "Cs"), (3, 8, "Ts"),
            (4, 9, "Lsd/Rsd"), (5, 10, "Lw/Rw"), (6, 11, "Lvh/Rvh"), (7, 12, "Cvh"),
            (8, 13, "LFE2"),
        ]
        for p in pairs {
            let chanmap = UInt16(1) << UInt16(15 - p.chanmapTransmissionBit)
            #expect(EAC3Bitstream.chanLoc(fromChanmap: chanmap) == UInt32(1) << UInt32(p.chanLocBit),
                    "\(p.name) should land on chan_loc bit \(p.chanLocBit)")
        }

        // Bed channels and the two LFEs have no chan_loc representation and must drop out:
        // transmission bits 0 L, 1 C, 2 R, 3 Ls, 4 Rs, 14 LFE, 15 reserved.
        for t in [0, 1, 2, 3, 4, 14, 15] {
            #expect(EAC3Bitstream.chanLoc(fromChanmap: UInt16(1) << UInt16(15 - t)) == 0)
        }

        // Measured: the real dependent substream declares L (tx 0), R (tx 2) and the Lvh/Rvh pair
        // (tx 11). Only the height pair survives, so chan_loc is 0x040 and not 0.
        #expect(EAC3Bitstream.chanLoc(fromChanmap: 0xA010) == 0x040)
        #expect(EAC3Bitstream.chanLoc(fromChanmap: 0) == 0)
        // All nine mappable bits at once.
        #expect(EAC3Bitstream.chanLoc(fromChanmap: 0b0000_0111_1111_1100) == 0x1FF)
    }

    // =================================================================================
    // EC3SpecificBox
    // =================================================================================

    @Test("dec3 builds the 28 Years Later payload from synthetic fields")
    func buildDec3FromFields() {
        let box = EC3SpecificBox(
            dataRate: 640,
            substreams: [EC3Substream(fscod: 0, bsid: 6, asvc: 0, bsmod: 0, acmod: 7,
                                      lfeon: true, numDepSub: 1, chanLoc: 0x040)],
            ec3ExtensionTypeA: true,
            complexityIndexTypeA: 16
        )
        // Hand-computed from ETSI TS 102 366 F.6:
        //   data_rate 640      -> 0 0010 1000 0000
        //   num_ind_sub 0      -> 000                      => 0x14 0x00
        //   fscod 0 (00) bsid 6 (00110) reserved 0         => 0x0C
        //   asvc 0 bsmod 0 (000) acmod 7 (111) lfeon 1     => 0x0F
        //   reserved 000 num_dep_sub 1 (0001) + chan_loc'  => 0x02
        //   chan_loc 0x040 = 0 0100 0000, low 8 bits       => 0x40
        //   reserved 0000000 + flag 1                      => 0x01
        //   complexity_index_type_a 16                     => 0x10
        #expect(box.encodePayload() == Self.dec3After)
    }

    @Test("dec3 parses the measured before-payload")
    func parseDec3Before() throws {
        let box = try #require(EC3SpecificBox.parse(payload: Self.dec3Before))
        #expect(box.dataRate == 640)
        #expect(box.substreams.count == 1)
        let s = box.substreams[0]
        #expect(s.fscod == 0)
        #expect(s.bsid == 6)
        #expect(s.bsmod == 0)
        #expect(s.acmod == 7)
        #expect(s.lfeon)
        #expect(s.numDepSub == 1)
        #expect(s.chanLoc == 0x000)
        #expect(box.ec3ExtensionTypeA == false)
        // Round-trip: re-encoding an unchanged parse must reproduce the muxer's bytes exactly,
        // which is what lets the rewrite decide "nothing changed" by byte comparison.
        #expect(box.encodePayload() == Self.dec3Before)
    }

    @Test("dec3 parses and round-trips the Dune payload, whose substream entry is the 3-byte form")
    func parseDec3Dune() throws {
        let box = try #require(EC3SpecificBox.parse(payload: Self.dec3Dune))
        #expect(box.dataRate == 1024)
        #expect(box.substreams[0].bsid == 16)
        #expect(box.substreams[0].acmod == 7)
        #expect(box.substreams[0].lfeon)
        #expect(box.substreams[0].numDepSub == 0)
        #expect(box.ec3ExtensionTypeA)
        #expect(box.complexityIndexTypeA == 16)
        #expect(box.encodePayload() == Self.dec3Dune)
    }

    @Test("dec3 omits the extension bytes when there is no JOC")
    func buildDec3WithoutJOC() {
        let box = EC3SpecificBox(
            dataRate: 640,
            substreams: [EC3Substream(fscod: 0, bsid: 16, asvc: 0, bsmod: 0, acmod: 7,
                                      lfeon: true, numDepSub: 0, chanLoc: 0)],
            ec3ExtensionTypeA: false,
            complexityIndexTypeA: 0
        )
        #expect(box.encodePayload() == [0x14, 0x00, 0x20, 0x0F, 0x00])
    }

    @Test("dec3 rejects a truncated payload rather than guessing")
    func parseDec3Truncated() {
        #expect(EC3SpecificBox.parse(payload: []) == nil)
        #expect(EC3SpecificBox.parse(payload: [0x14, 0x00, 0x0C]) == nil)
    }

    // =================================================================================
    // Syncframe reader
    // =================================================================================

    @Test("reads the measured AC-3 core syncframe header")
    func parseAC3Core() throws {
        let f = try #require(EAC3Bitstream.parseSyncFrame(Self.ac3CoreHeader))
        #expect(f.isAC3)
        #expect(f.streamType == .independent)
        #expect(f.substreamID == 0)
        #expect(f.fscod == 0)
        #expect(f.bsid == 6)
        #expect(f.bsmod == 0)
        #expect(f.acmod == 7)
        #expect(f.lfeon)
        #expect(f.chanmap == nil)
        #expect(f.frameSizeBytes == 2560)   // 640 kbps at 48 kHz
        #expect(f.ec3ExtensionTypeA == false)
    }

    @Test("reads the measured E-AC-3 dependent syncframe header, chanmap and JOC extension")
    func parseEAC3Dependent() throws {
        let f = try #require(EAC3Bitstream.parseSyncFrame(Self.eac3DependentHeader))
        #expect(f.isAC3 == false)
        #expect(f.streamType == .dependent)
        #expect(f.substreamID == 0)
        #expect(f.fscod == 0)
        #expect(f.bsid == 16)
        #expect(f.acmod == 5)
        #expect(f.lfeon == false)
        #expect(f.frameSizeBytes == 3584)
        #expect(f.chanmap == 0xA010)
        #expect(f.ec3ExtensionTypeA)
        #expect(f.complexityIndexTypeA == 16)
    }

    @Test("walks a whole packet, stepping by each frame's declared length")
    func parseWholePacket() {
        let frames = EAC3Bitstream.parseSyncFrames(Self.onePacket())
        #expect(frames.count == 2)
        #expect(frames.first?.isAC3 == true)
        #expect(frames.last?.streamType == .dependent)
        #expect(frames.last?.chanmap == 0xA010)
    }

    @Test("a buffer with no syncword yields nothing")
    func parseNoSync() {
        #expect(EAC3Bitstream.parseSyncFrame([0xDE, 0xAD, 0xBE, 0xEF, 0x00]) == nil)
        #expect(EAC3Bitstream.parseSyncFrames([]).isEmpty)
    }

    @Test("derives the corrected box from the real packet")
    func derivedFromPacket() throws {
        let frames = EAC3Bitstream.parseSyncFrames(Self.onePacket())
        let box = try #require(EC3SpecificBox.derived(
            fromSyncFrames: frames, dataRate: 640, jocDetectedByEngine: true))
        #expect(box.substreams.count == 1)
        #expect(box.substreams[0].numDepSub == 1)
        #expect(box.substreams[0].chanLoc == 0x040)
        #expect(box.ec3ExtensionTypeA)
        #expect(box.complexityIndexTypeA == 16)
        #expect(box.encodePayload() == Self.dec3After)
    }

    @Test("the engine's JOC verdict is the fallback when addbsi carries no extension")
    func derivedFallsBackToEngineJOC() throws {
        // Only the AC-3 core, which has no JOC bits of its own.
        let frames = EAC3Bitstream.parseSyncFrames(Self.ac3CoreHeader)
        let withEngine = try #require(EC3SpecificBox.derived(
            fromSyncFrames: frames, dataRate: 640, jocDetectedByEngine: true))
        #expect(withEngine.ec3ExtensionTypeA)
        #expect(withEngine.complexityIndexTypeA == EC3SpecificBox.defaultJOCComplexityIndex)

        let without = try #require(EC3SpecificBox.derived(
            fromSyncFrames: frames, dataRate: 640, jocDetectedByEngine: false))
        #expect(without.ec3ExtensionTypeA == false)
    }

    // =================================================================================
    // MP4 box walker
    // =================================================================================

    static func be(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }
    /// `stsd` is a FullBox with an `entry_count`, so its children start 8 payload bytes in.
    static func stsd(_ entries: [UInt8]) -> [UInt8] { box("stsd", be(0) + be(1) + entries) }
    /// An audio sample entry's children start 28 payload bytes in; a visual one's start 78 in.
    static func audioSampleEntry(_ type: String, _ children: [UInt8]) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 28) + children)
    }
    static func videoSampleEntry(_ type: String, _ children: [UInt8]) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 78) + children)
    }
    static func track(_ sampleEntry: [UInt8]) -> [UInt8] {
        box("trak", box("mdia", box("minf", box("stbl", stsd(sampleEntry)))))
    }

    /// A two-track fragmented init in the muxer's own order: video first, then audio. `dec3` is
    /// eight levels down inside the SECOND track.
    static func synthInit(dec3Payload: [UInt8]) -> [UInt8] {
        let video = track(videoSampleEntry("hvc1", box("hvcC", [0x01, 0x02, 0x03])))
        let audio = track(audioSampleEntry("ec-3", box("dec3", dec3Payload)))
        return box("ftyp", Array("isom".utf8)) + box("moov", video + audio)
    }

    @Test("the walker finds dec3 in the audio track, past the video track that comes first")
    func walkerFindsDec3() throws {
        let bytes = Self.synthInit(dec3Payload: Self.dec3Before)
        let chain = try #require(MP4BoxTree.find(path: InitSegmentDec3Rewrite.dec3Path, in: bytes))
        #expect(chain.map(\.type) == InitSegmentDec3Rewrite.dec3Path)
        #expect(Array(bytes[chain[chain.count - 1].payloadRange]) == Self.dec3Before)
        // The chain really is the audio track: the video one has no `ec-3`.
        #expect(MP4BoxTree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd", "hvc1", "hvcC"],
                                in: bytes) != nil)
        #expect(MP4BoxTree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd", "ec-3", "dac3"],
                                in: bytes) == nil)
    }

    @Test("replacing a payload grows every ancestor by the delta and nothing else")
    func walkerPatchesNestedLengths() throws {
        let before = Self.synthInit(dec3Payload: Self.dec3Before)
        let chain = try #require(MP4BoxTree.find(path: InitSegmentDec3Rewrite.dec3Path, in: before))
        let after = try #require(MP4BoxTree.replacingPayload(of: chain, in: before, with: Self.dec3After))

        #expect(after.count == before.count + 2)
        // Every one of the eight boxes on the chain is +2, and their offsets are unchanged
        // because each ancestor's header precedes the spliced bytes.
        func size(_ b: [UInt8], at offset: Int) -> Int {
            (Int(b[offset]) << 24) | (Int(b[offset + 1]) << 16) | (Int(b[offset + 2]) << 8) | Int(b[offset + 3])
        }
        for boxOnChain in chain {
            #expect(size(after, at: boxOnChain.start) == boxOnChain.size + 2,
                    "\(boxOnChain.type) should have grown by 2")
        }
        // `ftyp` and the video track are outside the chain and must be byte-identical.
        let ftypEnd = 8 + 4
        #expect(Array(after[0..<ftypEnd]) == Array(before[0..<ftypEnd]))
        let videoTrak = try #require(MP4BoxTree.find(path: ["moov", "trak"], in: before)?.last)
        #expect(Array(after[videoTrak.start..<videoTrak.end]) == Array(before[videoTrak.start..<videoTrak.end]))
        // Re-walking the patched bytes finds the new payload, which only holds if every length
        // downstream of the splice is self-consistent.
        let recheck = try #require(MP4BoxTree.find(path: InitSegmentDec3Rewrite.dec3Path, in: after))
        #expect(Array(after[recheck[recheck.count - 1].payloadRange]) == Self.dec3After)
    }

    @Test("a shrinking replacement patches the same lengths downward")
    func walkerHandlesNegativeDelta() throws {
        let before = Self.synthInit(dec3Payload: Self.dec3After)
        let chain = try #require(MP4BoxTree.find(path: InitSegmentDec3Rewrite.dec3Path, in: before))
        let after = try #require(MP4BoxTree.replacingPayload(of: chain, in: before, with: Self.dec3Before))
        #expect(after.count == before.count - 2)
        let recheck = try #require(MP4BoxTree.find(path: InitSegmentDec3Rewrite.dec3Path, in: after))
        #expect(Array(after[recheck[recheck.count - 1].payloadRange]) == Self.dec3Before)
    }

    @Test("the walker refuses a 64-bit largesize box instead of mis-patching it")
    func walkerRefusesLargesize() {
        // size == 1 means a 64-bit largesize follows; the 32-bit patch would corrupt it.
        let largesize = Self.be(1) + Array("moov".utf8) + [UInt8](repeating: 0, count: 16)
        #expect(MP4BoxTree.boxes(in: largesize, range: 0..<largesize.count).isEmpty)
        #expect(MP4BoxTree.find(path: ["moov"], in: largesize) == nil)
    }

    @Test("the walker stops cleanly on a truncated or nonsense buffer")
    func walkerTolerance() {
        #expect(MP4BoxTree.find(path: ["moov"], in: []) == nil)
        #expect(MP4BoxTree.find(path: ["moov"], in: [0, 1, 2, 3, 4]) == nil)
        // A box claiming more bytes than the buffer holds is not reported.
        let overlong = Self.be(999) + Array("moov".utf8)
        #expect(MP4BoxTree.boxes(in: overlong, range: 0..<overlong.count).isEmpty)
    }

    // =================================================================================
    // End to end
    // =================================================================================

    @Test("the rewrite corrects chan_loc and appends the JOC extension")
    func rewriteEndToEnd() throws {
        let before = Self.synthInit(dec3Payload: Self.dec3Before)
        let result = InitSegmentDec3Rewrite.rewrite(
            initBytes: before,
            audioBitstream: Self.onePacket(),
            isStreamCopiedEAC3: true,
            jocDetectedByEngine: true
        )
        let rewrite = try #require(try? result.get())
        #expect(rewrite.beforePayload == Self.dec3Before)
        #expect(rewrite.afterPayload == Self.dec3After)
        #expect(rewrite.chanmaps == [0xA010])
        #expect(rewrite.bytes.count == before.count + 2)
        #expect(rewrite.after.substreams[0].chanLoc == 0x040)
        #expect(rewrite.after.ec3ExtensionTypeA)
        // The log line is the only record on a rig, so it has to carry both payloads.
        let line = InitSegmentDec3Rewrite.logLine(rewrite)
        #expect(line.contains("14 00 0C 0F 02 00"))
        #expect(line.contains("14 00 0C 0F 02 40 01 10"))
        #expect(line.contains("chan_loc=0x040"))
    }

    @Test("a bridged (non stream-copied) track is never touched")
    func rewriteSkipsBridgedAudio() {
        let before = Self.synthInit(dec3Payload: Self.dec3Before)
        let result = InitSegmentDec3Rewrite.rewrite(
            initBytes: before, audioBitstream: Self.onePacket(),
            isStreamCopiedEAC3: false, jocDetectedByEngine: true)
        #expect(result == .failure(.notStreamCopiedEAC3))
    }

    @Test("a box that is already right is left alone")
    func rewriteSkipsCorrectBox() {
        // Feed the corrected payload back in: the re-derived bytes are identical, so there is
        // nothing to do. This is the arm that keeps "Dune: Part Two" byte-identical.
        let already = Self.synthInit(dec3Payload: Self.dec3After)
        let result = InitSegmentDec3Rewrite.rewrite(
            initBytes: already, audioBitstream: Self.onePacket(),
            isStreamCopiedEAC3: true, jocDetectedByEngine: true)
        #expect(result == .failure(.alreadyCorrect))
    }

    @Test("an init with no dec3, and a bitstream that does not parse, both leave the segment alone")
    func rewriteSkipsUnusableInput() {
        let noDec3 = Self.box("ftyp", Array("isom".utf8))
        #expect(InitSegmentDec3Rewrite.rewrite(
            initBytes: noDec3, audioBitstream: Self.onePacket(),
            isStreamCopiedEAC3: true, jocDetectedByEngine: true) == .failure(.noDec3Box))

        let before = Self.synthInit(dec3Payload: Self.dec3Before)
        #expect(InitSegmentDec3Rewrite.rewrite(
            initBytes: before, audioBitstream: [0xDE, 0xAD, 0xBE, 0xEF],
            isStreamCopiedEAC3: true, jocDetectedByEngine: true) == .failure(.noParsableSyncFrames))
    }

    @Test("a bitstream that disagrees with the box about the bed is refused, not applied")
    func rewriteRefusesBedMismatch() throws {
        // A `dec3` claiming acmod 2 (stereo) while the bitstream says acmod 7 means the reader is
        // out of step with what the muxer described; changing anything then would be a guess.
        let mismatched = EC3SpecificBox(
            dataRate: 640,
            substreams: [EC3Substream(fscod: 0, bsid: 6, asvc: 0, bsmod: 0, acmod: 2,
                                      lfeon: true, numDepSub: 1, chanLoc: 0)],
            ec3ExtensionTypeA: false, complexityIndexTypeA: 0
        ).encodePayload()
        let result = InitSegmentDec3Rewrite.rewrite(
            initBytes: Self.synthInit(dec3Payload: mismatched),
            audioBitstream: Self.onePacket(),
            isStreamCopiedEAC3: true, jocDetectedByEngine: true)
        guard case .failure(.bedMismatch) = result else {
            Issue.record("expected a bedMismatch refusal, got \(result)")
            return
        }
    }
}
