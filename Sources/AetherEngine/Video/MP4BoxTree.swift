import Foundation

// =====================================================================================
// Minimal ISO BMFF box walker
// =====================================================================================
//
// Enough of ISO/IEC 14496-12 to find a box by path inside a fragmented-MP4 INIT segment and
// replace its payload, reconciling the `size` field of the box itself and of every ancestor.
//
// This exists so `InitSegmentDec3Rewrite` never has to name a byte offset. The `dec3` box is
// eight levels down (`moov > trak > mdia > minf > stbl > stsd > ec-3 > dec3`) and its position
// moves with the video track's `hvcC`, the `dvcC`/`dvvC` record, the AE#458 `mdhd` language and
// anything else the muxer writes before it, so an offset learned from one measurement is wrong
// on the next source.
//
// Scope, deliberately: init segments only. No `moof`/`mdat`, and therefore no `stco`/`co64`
// chunk offsets or `sidx` references to fix up when a box changes size -- an `empty_moov` init
// has an empty sample table and no media data, which is the entire reason a size-changing edit
// is safe here at all.
// =====================================================================================

/// One box located inside a buffer. Offsets are absolute in the buffer the walk started from.
struct MP4Box: Equatable {
    /// FourCC, e.g. `moov`, `stsd`, `dec3`.
    let type: String
    /// Offset of the box's 4-byte `size` field.
    let start: Int
    /// Offset of the first payload byte (`start + 8` for every box this walker accepts).
    let payloadStart: Int
    /// One past the box's last byte.
    let end: Int

    var size: Int { end - start }
    var payloadRange: Range<Int> { payloadStart..<end }
}

enum MP4BoxTree {

    /// How many payload bytes sit between a container box's header and its first child box.
    ///
    /// Most containers are pure (`0`). Two on the path to `dec3` are not, and both are fixed by
    /// ISO/IEC 14496-12:
    ///
    ///  - `stsd` is a FullBox: `version`+`flags` (4) then `entry_count` (4) = 8.
    ///  - An audio sample entry is `SampleEntry` (6 reserved + 2 `data_reference_index`) followed
    ///    by `AudioSampleEntry`'s version-0 fields (8 reserved + 2 `channelcount` +
    ///    2 `samplesize` + 2 `pre_defined` + 2 reserved + 4 `samplerate`) = 28. The codec
    ///    configuration boxes (`dec3`, `dac3`, `esds`, ...) are that entry's children.
    ///
    /// `nil` means "not a container this walker descends into", which makes an unknown leaf box
    /// safe rather than a source of garbage children.
    static func childPayloadOffset(forBoxType type: String) -> Int? {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "moof", "traf", "mvex", "edts", "dinf", "udta":
            return 0
        case "stsd":
            return 8
        case "ec-3", "ac-3", "ac-4", "mp4a", "mlpa", "enca", "fLaC", "Opus", "alac":
            return 28
        // A VisualSampleEntry's fixed part is longer: `SampleEntry` (8) plus 2 pre_defined +
        // 2 reserved + 12 pre_defined + 2 width + 2 height + 4 horizresolution + 4 vertresolution
        // + 4 reserved + 2 frame_count + 32 compressorname + 2 depth + 2 pre_defined = 78. Listed
        // so a walk into the video track reads real children rather than garbage; the `dec3`
        // search never needs it, but a wrong constant here would turn a harmless miss into one.
        case "avc1", "hvc1", "hev1", "dvh1", "dvhe", "encv":
            return 78
        default:
            return nil
        }
    }

    /// Parse the sibling boxes laid out across `range`.
    ///
    /// Stops at the first malformed or out-of-range header and returns what it has, so a
    /// truncated init yields the boxes that are whole. A 64-bit `largesize` box (`size == 1`) is
    /// treated as the end of the walk: an init segment never contains one, and refusing is safer
    /// than mis-patching a size field that is not where this code thinks it is.
    static func boxes(in bytes: [UInt8], range: Range<Int>) -> [MP4Box] {
        var out: [MP4Box] = []
        var offset = range.lowerBound
        let end = min(range.upperBound, bytes.count)
        while offset + 8 <= end {
            let size = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                     | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            guard let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) else { break }
            // size == 0 means "to the end of the enclosing container"; size == 1 means a 64-bit
            // largesize follows, which this walker refuses.
            guard size != 1 else { break }
            let boxSize = size == 0 ? (end - offset) : size
            guard boxSize >= 8, offset + boxSize <= end else { break }
            out.append(MP4Box(type: type, start: offset, payloadStart: offset + 8, end: offset + boxSize))
            offset += boxSize
        }
        return out
    }

    /// Find a box by fourCC path, descending only through boxes `childPayloadOffset` recognises.
    ///
    /// Returns the whole chain, outermost first, ending with the requested box -- the chain IS
    /// the list of size fields `replacingPayload` has to reconcile.
    ///
    /// The search BACKTRACKS over same-typed siblings rather than committing to the first match,
    /// which is what makes `moov > trak > ... > ec-3 > dec3` land on the audio track: a
    /// fragmented init has two `trak` boxes and the video one comes first, so a first-match walk
    /// would descend into it, fail at `ec-3`, and wrongly report that the init has no `dec3`.
    /// The path therefore identifies the track by what it contains, with no index or handler
    /// lookup to keep in sync.
    static func find(path: [String], in bytes: [UInt8], range: Range<Int>? = nil) -> [MP4Box]? {
        guard !path.isEmpty else { return nil }
        let searchRange = range ?? 0..<bytes.count
        for candidate in boxes(in: bytes, range: searchRange) where candidate.type == path[0] {
            if path.count == 1 { return [candidate] }
            guard let prefix = childPayloadOffset(forBoxType: candidate.type),
                  candidate.payloadStart + prefix <= candidate.end
            else { continue }
            let childRange = (candidate.payloadStart + prefix)..<candidate.end
            if let rest = find(path: Array(path.dropFirst()), in: bytes, range: childRange) {
                return [candidate] + rest
            }
        }
        return nil
    }

    /// Replace the payload of `chain.last!` and patch the `size` field of every box in `chain`.
    ///
    /// The delta may be positive or negative. Every ancestor's header precedes the target box's
    /// first byte, so their offsets survive the splice untouched and each one grows or shrinks by
    /// exactly the delta. Returns `nil` if the chain is empty, is not properly nested, or a
    /// patched size would not fit the 32-bit field.
    static func replacingPayload(
        of chain: [MP4Box],
        in bytes: [UInt8],
        with newPayload: [UInt8]
    ) -> [UInt8]? {
        guard let target = chain.last else { return nil }
        guard target.payloadStart >= 0, target.end <= bytes.count, target.payloadStart <= target.end else {
            return nil
        }
        // Proper nesting: each box must contain the next, and every ancestor's size field must sit
        // before the spliced region so patching it in place is valid.
        for (outer, inner) in zip(chain, chain.dropFirst()) {
            guard outer.start < inner.start, inner.end <= outer.end else { return nil }
        }

        let delta = newPayload.count - (target.end - target.payloadStart)
        var out = Array(bytes[0..<target.payloadStart]) + newPayload + Array(bytes[target.end..<bytes.count])

        for box in chain {
            let newSize = box.size + delta
            guard newSize >= 8, newSize <= 0xFFFF_FFFF else { return nil }
            let v = UInt32(newSize)
            out[box.start]     = UInt8((v >> 24) & 0xFF)
            out[box.start + 1] = UInt8((v >> 16) & 0xFF)
            out[box.start + 2] = UInt8((v >> 8) & 0xFF)
            out[box.start + 3] = UInt8(v & 0xFF)
        }
        return out
    }
}
