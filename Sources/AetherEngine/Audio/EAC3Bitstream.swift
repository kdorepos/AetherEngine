import Foundation

// =====================================================================================
// E-AC-3 (Enhanced AC-3 / Dolby Digital Plus) bitstream reader
// =====================================================================================
//
// Why this file exists
// --------------------
// The engine stream-copies E-AC-3 JOC ("Dolby Atmos") audio and lets FFmpeg's
// `libavformat/movenc.c: handle_eac3()` build the fMP4 `dec3` sample-entry box from a parsed
// packet (see `MP4SegmentMuxer`'s `+delay_moov` machinery). For an 8-channel source -- a 5.1
// bed in the INDEPENDENT substream plus a DEPENDENT substream carrying the two height
// channels -- that box comes out wrong in two ways:
//
//   1. `chan_loc` is 0. It is supposed to describe which channels the dependent substream
//      adds (ETSI TS 102 366 F.6.2.3), and FFmpeg derives it from the dependent substream's
//      `chanmap` with a shift/mask that does not match the spec's bit order.
//   2. The JOC extension (`flag_ec3_extension_type_a` + `complexity_index_type_a`, ETSI TS
//      103 420) is missing entirely, because `handle_eac3()` latches
//      `complexity_index_type_a` from the INDEPENDENT substream header before its
//      dependent-substream loop, and JOC puts those bits in the DEPENDENT substream's
//      `addbsi` (cf. jellyfin/jellyfin-ffmpeg#584).
//
// tvOS therefore cannot map the dependent substream, decodes only the 5.1 core, and the
// receiver reports multichannel PCM instead of Atmos. FFmpegBuild ships prebuilt
// xcframeworks with no C sources, so `handle_eac3()` is not patchable from here; the fix is
// to re-derive the fields from the bitstream in Swift and rewrite the captured init segment's
// `dec3` payload (see `InitSegmentDec3Rewrite`).
//
// Everything in this file is PURE: bytes in, values out. No FFmpeg, no I/O, no global state,
// so every field and every bit offset is unit-testable against the spec.
//
// Specs used
// ----------
//   ETSI TS 102 366 (AC-3 / E-AC-3), Annex E.1.2.2   -- E-AC-3 syncframe bit stream information
//   ETSI TS 102 366, Annex F.6                       -- EC3SpecificBox (`dec3`) syntax
//   ETSI TS 102 366, Annex F.6.2.3 / Table F.6.1     -- chan_loc bit assignments
//   ETSI TS 103 420 (JOC carriage in E-AC-3)         -- addbsi / dec3 extension bytes
// =====================================================================================

// MARK: - Bit reader

/// Big-endian (MSB-first) bit reader over a byte buffer.
///
/// Every field in an E-AC-3 syncframe and in an `EC3SpecificBox` is packed MSB-first with no
/// alignment, so all reads go through this. Returns `nil` on overrun rather than trapping: the
/// input is remote media, and a truncated or malformed frame must degrade to "leave the segment
/// alone", never to a crash in the muxer callback.
struct EAC3BitReader {
    private let bytes: [UInt8]
    /// Absolute bit position, counted from the MSB of `bytes[0]`.
    private(set) var bitPosition: Int

    init(_ bytes: [UInt8], startingAtBit bit: Int = 0) {
        self.bytes = bytes
        self.bitPosition = bit
    }

    /// Bits still unread. Used by the `addbsi` walk to refuse a field the frame cannot contain.
    var bitsRemaining: Int { max(0, bytes.count * 8 - bitPosition) }

    /// Read `count` bits (0...32) MSB-first, advancing the cursor. `nil` if the buffer runs out,
    /// in which case the cursor is left where it was so a caller can report a clean failure.
    mutating func read(_ count: Int) -> UInt32? {
        guard count >= 0, count <= 32 else { return nil }
        guard count > 0 else { return 0 }
        guard bitsRemaining >= count else { return nil }
        var value: UInt32 = 0
        var remaining = count
        var position = bitPosition
        while remaining > 0 {
            let byteIndex = position >> 3
            let bitInByte = position & 7
            // How many bits are left in this byte, capped by what is still wanted.
            let take = min(8 - bitInByte, remaining)
            let byte = UInt32(bytes[byteIndex])
            // Drop the bits below the window, then mask off the bits above it.
            let shifted = byte >> UInt32(8 - bitInByte - take)
            let masked = shifted & ((1 << UInt32(take)) - 1)
            value = (value << UInt32(take)) | masked
            position += take
            remaining -= take
        }
        bitPosition = position
        return value
    }

    /// Read one bit as a Bool. `nil` on overrun, same contract as `read`.
    mutating func readFlag() -> Bool? {
        guard let v = read(1) else { return nil }
        return v == 1
    }

    /// Advance without reading. `false` (and no movement) if that would run past the end.
    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, bitsRemaining >= count else { return false }
        bitPosition += count
        return true
    }
}

// MARK: - Bit writer

/// Big-endian (MSB-first) bit writer, the mirror of `EAC3BitReader`.
///
/// `finish()` zero-pads to the next byte boundary, which is what FFmpeg's `flush_put_bits` does
/// when it writes the same box -- so a rebuilt `dec3` whose fields are unchanged is byte-identical
/// to the one the muxer produced, and the "did anything actually change?" comparison in
/// `InitSegmentDec3Rewrite` is exact rather than approximate.
struct EAC3BitWriter {
    private var bytes: [UInt8] = []
    /// Bits of `partial` that are already filled, 0...7.
    private var partialBits: Int = 0
    private var partial: UInt8 = 0

    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0, bits <= 32 else { return }
        var remaining = bits
        while remaining > 0 {
            remaining -= 1
            let bit = UInt8((value >> UInt32(remaining)) & 1)
            partial = (partial << 1) | bit
            partialBits += 1
            if partialBits == 8 {
                bytes.append(partial)
                partial = 0
                partialBits = 0
            }
        }
    }

    mutating func write(_ flag: Bool) { write(flag ? 1 : 0, bits: 1) }

    /// Flush, zero-padding the final partial byte.
    mutating func finish() -> [UInt8] {
        if partialBits > 0 {
            bytes.append(partial << UInt8(8 - partialBits))
            partial = 0
            partialBits = 0
        }
        return bytes
    }
}

// MARK: - Syncframe

/// One parsed E-AC-3 syncframe's bit stream information (ETSI TS 102 366 E.1.2.2).
///
/// Only the fields the `dec3` box and the JOC extension need are kept; everything else is walked
/// past so the cursor lands on `addbsi` at the right bit.
struct EAC3SyncFrame: Equatable {
    /// `strmtyp`: 0 = independent, 1 = dependent, 2 = AC-3 converted, 3 = reserved.
    enum StreamType: UInt32, Equatable {
        case independent = 0
        case dependent = 1
        case ac3Converted = 2
        case reserved = 3
    }

    /// True when this syncframe is a legacy AC-3 frame (`bsid <= 10`), not an E-AC-3 one.
    ///
    /// A Blu-ray-style Dolby Digital Plus track is exactly this: an AC-3 5.1 CORE syncframe
    /// (`bsid = 6`, the alternate bit stream syntax of ETSI TS 102 366 Annex D) immediately
    /// followed by an E-AC-3 DEPENDENT syncframe carrying the extra channels and, for Atmos, the
    /// JOC extension. "28 Years Later" is precisely that, which is why the reader has to speak
    /// both syntaxes: they are different headers behind the same syncword, told apart only by
    /// peeking at `bsid`.
    var isAC3: Bool = false
    var streamType: StreamType
    var substreamID: UInt32
    /// Frame size in BYTES, i.e. `(frmsiz + 1) * 2`. The walk to the next syncframe uses this.
    var frameSizeBytes: Int
    var fscod: UInt32
    var bsid: UInt32
    var bsmod: UInt32
    var acmod: UInt32
    var lfeon: Bool
    /// The dependent substream's custom channel map, present only when `chanmape` is 1.
    /// Read MSB-first, so the spec's "bit 0" (the L channel) is the UInt16's bit 15.
    var chanmap: UInt16?
    /// `addbsi[0] & 1` -- ETSI TS 103 420's `flag_ec3_extension_type_a`. True means this
    /// substream carries JOC.
    var ec3ExtensionTypeA: Bool
    /// `addbsi[1]` -- the object count Dolby's HLS `CHANNELS="<n>/JOC"` also reports. Only
    /// meaningful when `ec3ExtensionTypeA` is true.
    var complexityIndexTypeA: UInt32?

    static let syncword: UInt16 = 0x0B77
}

/// AC-3 frame sizes in 16-bit words, indexed by `frmsizecod` then by `fscod`
/// (0 = 48 kHz, 1 = 44.1 kHz, 2 = 32 kHz). ETSI TS 102 366 Table 5.18.
///
/// Needed only to step from an AC-3 core syncframe to the dependent E-AC-3 syncframe behind it:
/// unlike E-AC-3, an AC-3 header states its size as a table index, not as a byte count.
enum AC3FrameSizeTable {
    static let words: [[Int]] = [
        [64, 69, 96],       [64, 70, 96],
        [80, 87, 120],      [80, 88, 120],
        [96, 104, 144],     [96, 105, 144],
        [112, 121, 168],    [112, 122, 168],
        [128, 139, 192],    [128, 140, 192],
        [160, 174, 240],    [160, 175, 240],
        [192, 208, 288],    [192, 209, 288],
        [224, 243, 336],    [224, 244, 336],
        [256, 278, 384],    [256, 279, 384],
        [320, 348, 480],    [320, 349, 480],
        [384, 417, 576],    [384, 418, 576],
        [448, 487, 672],    [448, 488, 672],
        [512, 557, 768],    [512, 558, 768],
        [640, 696, 960],    [640, 697, 960],
        [768, 835, 1152],   [768, 836, 1152],
        [896, 975, 1344],   [896, 976, 1344],
        [1024, 1114, 1536], [1024, 1115, 1536],
        [1152, 1253, 1728], [1152, 1254, 1728],
        [1280, 1393, 1920], [1280, 1394, 1920],
    ]

    /// Frame size in BYTES, or nil for a reserved `frmsizecod` / `fscod`.
    static func frameSizeBytes(frmsizecod: UInt32, fscod: UInt32) -> Int? {
        guard frmsizecod < UInt32(words.count), fscod < 3 else { return nil }
        return words[Int(frmsizecod)][Int(fscod)] * 2
    }
}

enum EAC3Bitstream {

    /// `numblkscod` -> number of audio blocks in the frame. Needed by the per-block mixing
    /// metadata loop, which is the one place the frame's block count changes the header's length.
    static func audioBlocks(numblkscod: UInt32) -> Int {
        switch numblkscod {
        case 0: return 1
        case 1: return 2
        case 2: return 3
        default: return 6
        }
    }

    /// Parse the bit stream information of the syncframe starting at `offset`.
    ///
    /// Returns `nil` when the syncword is absent, the frame is truncated, or any field runs past
    /// the buffer. The caller treats that as "cannot re-derive the box" and leaves the init
    /// segment untouched.
    ///
    /// The walk follows E.1.2.2 literally, including the parts we do not keep, because `addbsi`
    /// sits at the very end of the bit stream information and its position depends on every
    /// conditional before it. Divergence note: FFmpeg's `ff_ac3_parse_header` gates the
    /// `ltrtcmixlev`/`lorocmixlev` pair on `acmod > AC3_CHMODE_3F1R` where the spec says
    /// `acmod > 0x2`; the two agree for every acmod this engine ever stream-copies (2, 6, 7) and
    /// we follow the spec.
    static func parseSyncFrame(_ bytes: [UInt8], offset: Int = 0) -> EAC3SyncFrame? {
        guard offset >= 0, offset + 5 <= bytes.count else { return nil }
        guard (UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])) == EAC3SyncFrame.syncword else {
            return nil
        }

        var r = EAC3BitReader(bytes, startingAtBit: (offset + 2) * 8)

        // Both syntaxes hide behind the same syncword. `bsid` is the 5 least significant bits of
        // the 29 that follow it in EITHER layout, so peek those without consuming them and branch:
        // `bsid <= 10` is AC-3 (ETSI TS 102 366 clause 5.3), 11...16 is E-AC-3 (Annex E). This is
        // the same disambiguation FFmpeg's `ff_ac3_parse_header` performs.
        var peek = r
        guard let peeked = peek.read(29) else { return nil }
        if (peeked & 0x1F) <= 10 {
            return parseAC3SyncFrame(bytes, reader: &r)
        }

        guard let strmtypRaw = r.read(2),
              let strmtyp = EAC3SyncFrame.StreamType(rawValue: strmtypRaw),
              let substreamid = r.read(3),
              let frmsiz = r.read(11),
              let fscod = r.read(2)
        else { return nil }

        // fscod == 3 escapes into fscod2 and forces six audio blocks; otherwise numblkscod is read.
        let numblkscod: UInt32
        if fscod == 3 {
            guard r.skip(2) else { return nil }   // fscod2
            numblkscod = 3
        } else {
            guard let n = r.read(2) else { return nil }
            numblkscod = n
        }
        let numblks = audioBlocks(numblkscod: numblkscod)

        guard let acmod = r.read(3),
              let lfeon = r.readFlag(),
              let bsid = r.read(5)
        else { return nil }

        // dialnorm / compr, twice in the 1+1 (acmod == 0) dual-mono case.
        let programCount = (acmod == 0) ? 2 : 1
        for _ in 0..<programCount {
            guard r.skip(5) else { return nil }               // dialnorm
            guard let compre = r.readFlag() else { return nil }
            if compre { guard r.skip(8) else { return nil } }  // compr
        }

        // The dependent substream's custom channel map: the ONLY statement in the bitstream of
        // which channels this substream adds on top of the independent one's bed.
        var chanmap: UInt16?
        if strmtyp == .dependent {
            guard let chanmape = r.readFlag() else { return nil }
            if chanmape {
                guard let m = r.read(16) else { return nil }
                chanmap = UInt16(truncatingIfNeeded: m)
            }
        }

        // ---- mixing metadata -------------------------------------------------------------
        guard let mixmdate = r.readFlag() else { return nil }
        if mixmdate {
            if acmod > 0x2 { guard r.skip(2) else { return nil } }                  // dmixmod
            if (acmod & 0x1) != 0 && acmod > 0x2 { guard r.skip(6) else { return nil } }  // ltrtcmixlev + lorocmixlev
            if (acmod & 0x4) != 0 { guard r.skip(6) else { return nil } }           // ltrtsurmixlev + lorosurmixlev
            if lfeon {
                guard let lfemixlevcode = r.readFlag() else { return nil }
                if lfemixlevcode { guard r.skip(5) else { return nil } }            // lfemixlev
            }
            if strmtyp == .independent {
                guard let pgmscle = r.readFlag() else { return nil }
                if pgmscle { guard r.skip(6) else { return nil } }                  // pgmscl
                if acmod == 0x0 {
                    guard let pgmscl2e = r.readFlag() else { return nil }
                    if pgmscl2e { guard r.skip(6) else { return nil } }             // pgmscl2
                }
                guard let extpgmscle = r.readFlag() else { return nil }
                if extpgmscle { guard r.skip(6) else { return nil } }               // extpgmscl
                guard let mixdef = r.read(2) else { return nil }
                switch mixdef {
                case 0x1:
                    guard r.skip(5) else { return nil }   // premixcmpsel + drcsrc + premixcmpscl
                case 0x2:
                    guard r.skip(12) else { return nil }  // mixdata
                case 0x3:
                    guard let mixdeflen = r.read(5) else { return nil }
                    guard r.skip(8 * (Int(mixdeflen) + 2)) else { return nil }       // mixdata
                default:
                    break                                  // mixdef == 0: nothing
                }
                if acmod < 0x2 {
                    guard let paninfoe = r.readFlag() else { return nil }
                    if paninfoe { guard r.skip(14) else { return nil } }             // panmean + paninfo
                    if acmod == 0x0 {
                        guard let paninfo2e = r.readFlag() else { return nil }
                        if paninfo2e { guard r.skip(14) else { return nil } }        // panmean2 + paninfo2
                    }
                }
                guard let frmmixcfginfoe = r.readFlag() else { return nil }
                if frmmixcfginfoe {
                    if numblkscod == 0x0 {
                        guard r.skip(5) else { return nil }                          // blkmixcfginfo[0]
                    } else {
                        for _ in 0..<numblks {
                            guard let blkmixcfginfoe = r.readFlag() else { return nil }
                            if blkmixcfginfoe { guard r.skip(5) else { return nil } }
                        }
                    }
                }
            }
        }

        // ---- informational metadata ------------------------------------------------------
        var bsmod: UInt32 = 0
        guard let infomdate = r.readFlag() else { return nil }
        if infomdate {
            guard let m = r.read(3) else { return nil }
            bsmod = m
            guard r.skip(2) else { return nil }                    // copyrightb + origbs
            if acmod == 0x2 { guard r.skip(4) else { return nil } } // dsurmod + dheadphonmod
            if acmod >= 0x6 { guard r.skip(2) else { return nil } } // dsurexmod
            guard let audprodie = r.readFlag() else { return nil }
            if audprodie { guard r.skip(8) else { return nil } }    // mixlevel + roomtyp + adconvtyp
            if acmod == 0x0 {
                guard let audprodi2e = r.readFlag() else { return nil }
                if audprodi2e { guard r.skip(8) else { return nil } }
            }
            if fscod < 0x3 { guard r.skip(1) else { return nil } }  // sourcefscod
        }

        if strmtyp == .independent && numblkscod != 0x3 {
            guard r.skip(1) else { return nil }                     // convsync
        }
        if strmtyp == .ac3Converted {
            var blkid = true
            if numblkscod != 0x3 {
                guard let b = r.readFlag() else { return nil }
                blkid = b
            }
            if blkid { guard r.skip(6) else { return nil } }        // frmsizecod
        }

        // ---- additional bit stream information (where JOC lives) ---------------------------
        //
        // ETSI TS 103 420: a DD+ JOC substream sets `addbsi[0]`'s least significant bit
        // (`flag_ec3_extension_type_a`) and puts the object count in `addbsi[1]`
        // (`complexity_index_type_a`). This is the exact layout the `dec3` extension bytes
        // repeat, which is why the two bytes can be copied across verbatim.
        var extensionTypeA = false
        var complexity: UInt32?
        guard let addbsie = r.readFlag() else { return nil }
        if addbsie {
            guard let addbsil = r.read(6) else { return nil }
            let byteCount = Int(addbsil) + 1
            guard r.bitsRemaining >= byteCount * 8 else { return nil }
            for i in 0..<byteCount {
                guard let byte = r.read(8) else { return nil }
                if i == 0 {
                    extensionTypeA = (byte & 0x01) == 1
                } else if i == 1 {
                    complexity = byte
                }
            }
        }

        return EAC3SyncFrame(
            isAC3: false,
            streamType: strmtyp,
            substreamID: substreamid,
            frameSizeBytes: (Int(frmsiz) + 1) * 2,
            fscod: fscod,
            bsid: bsid,
            bsmod: bsmod,
            acmod: acmod,
            lfeon: lfeon,
            chanmap: chanmap,
            ec3ExtensionTypeA: extensionTypeA,
            complexityIndexTypeA: extensionTypeA ? (complexity ?? nil) : nil
        )
    }

    /// Parse a legacy AC-3 syncframe (ETSI TS 102 366 clause 5.3), `reader` positioned just after
    /// the syncword.
    ///
    /// An AC-3 core frame is reported as an INDEPENDENT substream with `substreamid` 0, which is
    /// how `handle_eac3()` also files it: in the Blu-ray-style hybrid track it is substream 0's
    /// bed, and the E-AC-3 dependent frame that follows hangs off it.
    ///
    /// `bsid == 6` selects Annex D's alternate bit stream syntax, whose `xbsi1`/`xbsi2` fields
    /// replace the time codes. Getting that branch wrong moves `addbsi` and would silently lose
    /// the JOC flag, so it is walked explicitly rather than skipped.
    static func parseAC3SyncFrame(_ bytes: [UInt8], reader r: inout EAC3BitReader) -> EAC3SyncFrame? {
        guard r.skip(16) else { return nil }                       // crc1
        guard let fscod = r.read(2), let frmsizecod = r.read(6) else { return nil }
        guard let frameSize = AC3FrameSizeTable.frameSizeBytes(frmsizecod: frmsizecod, fscod: fscod) else {
            return nil
        }
        guard let bsid = r.read(5), let bsmod = r.read(3), let acmod = r.read(3) else { return nil }
        if (acmod & 0x1) != 0 && acmod != 0x1 { guard r.skip(2) else { return nil } }   // cmixlev
        if (acmod & 0x4) != 0 { guard r.skip(2) else { return nil } }                   // surmixlev
        if acmod == 0x2 { guard r.skip(2) else { return nil } }                         // dsurmod
        guard let lfeon = r.readFlag() else { return nil }

        guard r.skip(5) else { return nil }                        // dialnorm
        guard let compre = r.readFlag() else { return nil }
        if compre { guard r.skip(8) else { return nil } }          // compr
        guard let langcode = r.readFlag() else { return nil }
        if langcode { guard r.skip(8) else { return nil } }        // langcod
        guard let audprodie = r.readFlag() else { return nil }
        if audprodie { guard r.skip(7) else { return nil } }       // mixlevel + roomtyp
        if acmod == 0x0 {
            guard r.skip(5) else { return nil }                    // dialnorm2
            guard let compr2e = r.readFlag() else { return nil }
            if compr2e { guard r.skip(8) else { return nil } }
            guard let langcod2e = r.readFlag() else { return nil }
            if langcod2e { guard r.skip(8) else { return nil } }
            guard let audprodi2e = r.readFlag() else { return nil }
            if audprodi2e { guard r.skip(7) else { return nil } }
        }
        guard r.skip(2) else { return nil }                        // copyrightb + origbs

        if bsid == 6 {
            guard let xbsi1e = r.readFlag() else { return nil }
            // dmixmod(2) + ltrtcmixlev(3) + ltrtsurmixlev(3) + lorocmixlev(3) + lorosurmixlev(3)
            if xbsi1e { guard r.skip(14) else { return nil } }
            guard let xbsi2e = r.readFlag() else { return nil }
            // dsurexmod(2) + dheadphonmod(2) + adconvtyp(1) + xbsi2(8) + encinfo(1)
            if xbsi2e { guard r.skip(14) else { return nil } }
        } else {
            guard let timecod1e = r.readFlag() else { return nil }
            if timecod1e { guard r.skip(14) else { return nil } }
            guard let timecod2e = r.readFlag() else { return nil }
            if timecod2e { guard r.skip(14) else { return nil } }
        }

        var extensionTypeA = false
        var complexity: UInt32?
        guard let addbsie = r.readFlag() else { return nil }
        if addbsie {
            guard let addbsil = r.read(6) else { return nil }
            let byteCount = Int(addbsil) + 1
            guard r.bitsRemaining >= byteCount * 8 else { return nil }
            for i in 0..<byteCount {
                guard let byte = r.read(8) else { return nil }
                if i == 0 { extensionTypeA = (byte & 0x01) == 1 }
                else if i == 1 { complexity = byte }
            }
        }

        return EAC3SyncFrame(
            isAC3: true,
            streamType: .independent,
            substreamID: 0,
            frameSizeBytes: frameSize,
            fscod: fscod,
            bsid: bsid,
            bsmod: bsmod,
            acmod: acmod,
            lfeon: lfeon,
            chanmap: nil,
            ec3ExtensionTypeA: extensionTypeA,
            complexityIndexTypeA: extensionTypeA ? complexity : nil
        )
    }

    /// Walk up to `limit` consecutive syncframes from the start of `bytes`.
    ///
    /// One E-AC-3 *packet* is one "frame" made of an independent syncframe immediately followed by
    /// its dependent syncframe(s), so a single packet is normally enough to see both. The walk is
    /// bounded by `limit` and by the buffer, and stops (returning what it has) at the first frame
    /// that does not parse -- a partially readable packet still yields the substreams before the
    /// bad one.
    static func parseSyncFrames(_ bytes: [UInt8], limit: Int = 8) -> [EAC3SyncFrame] {
        var frames: [EAC3SyncFrame] = []
        var offset = 0
        while frames.count < limit, offset + 5 <= bytes.count {
            guard let frame = parseSyncFrame(bytes, offset: offset), frame.frameSizeBytes > 0 else { break }
            frames.append(frame)
            offset += frame.frameSizeBytes
        }
        return frames
    }

    // MARK: - chanmap -> chan_loc

    /// Map a dependent substream's 16-bit `chanmap` to the 9-bit `chan_loc` of the `dec3` box.
    ///
    /// ETSI TS 102 366 numbers both tables in TRANSMISSION order (its "bit 0" is the first bit on
    /// the wire, i.e. the MSB of the 16-bit field this reader returns):
    ///
    ///   chanmap tx-bit:  0 L | 1 C | 2 R | 3 Ls | 4 Rs | 5 Lc/Rc | 6 Lrs/Rrs | 7 Cs | 8 Ts
    ///                  | 9 Lsd/Rsd | 10 Lw/Rw | 11 Lvh/Rvh | 12 Cvh | 13 LFE2 | 14 LFE | 15 reserved
    ///
    ///   chan_loc bit:    0 Lc/Rc | 1 Lrs/Rrs | 2 Cs | 3 Ts | 4 Lsd/Rsd | 5 Lw/Rw
    ///                  | 6 Lvh/Rvh | 7 Cvh | 8 LFE2
    ///
    /// `chan_loc` covers exactly chanmap transmission bits 5...13, in the same order, so
    /// `chan_loc` bit k is chanmap transmission bit (k + 5) -- which, as a UInt16 read MSB-first,
    /// is integer bit `15 - (k + 5)` = `10 - k`. The five bed channels (L/C/R/Ls/Rs) and the two
    /// LFEs have no `chan_loc` representation and are dropped, which is correct: the bed is
    /// already described by the independent substream's `acmod`/`lfeon`.
    ///
    /// A 5.1.2 source's dependent substream carries the height pair only, so `chanmap` has the
    /// Lvh/Rvh bit alone and this returns `1 << 6` = `0x040`.
    static func chanLoc(fromChanmap chanmap: UInt16) -> UInt32 {
        var loc: UInt32 = 0
        for locBit in 0...8 {
            let chanmapIntegerBit = 10 - locBit
            if (chanmap >> UInt16(chanmapIntegerBit)) & 1 == 1 {
                loc |= (1 << UInt32(locBit))
            }
        }
        return loc
    }
}
