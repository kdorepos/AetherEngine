import Foundation

// =====================================================================================
// EC3SpecificBox (`dec3`) -- ETSI TS 102 366 Annex F.6, extended by ETSI TS 103 420
// =====================================================================================
//
// Payload syntax (all fields MSB-first, no alignment until the very end):
//
//   unsigned int(13) data_rate;                       // kbit/s
//   unsigned int(3)  num_ind_sub;                     // independent substream count MINUS ONE
//   for (i = 0; i < num_ind_sub + 1; i++) {
//       unsigned int(2) fscod;
//       unsigned int(5) bsid;
//       unsigned int(1) reserved;
//       unsigned int(1) asvc;
//       unsigned int(3) bsmod;
//       unsigned int(3) acmod;
//       unsigned int(1) lfeon;
//       unsigned int(3) reserved;
//       unsigned int(4) num_dep_sub;
//       if (num_dep_sub > 0) unsigned int(9) chan_loc;
//       else                 unsigned int(1) reserved;
//   }
//   // ETSI TS 103 420, present only for JOC:
//   unsigned int(7) reserved;
//   unsigned int(1) flag_ec3_extension_type_a;
//   unsigned int(8) complexity_index_type_a;
//
// So a single-independent-substream box is 2 + 4 = 6 payload bytes with a dependent substream
// (23 + 9 = 32 bits per substream), 2 + 3 = 5 without (23 + 1 = 24 bits), and two more bytes
// when the JOC extension is present. Those sizes are what FFmpeg's `mov_write_eac3_tag` emits,
// and they were confirmed byte for byte against a real init segment -- see
// docs/atmos-engine-patch.md.
// =====================================================================================

/// One independent substream's entry in an `EC3SpecificBox`.
struct EC3Substream: Equatable {
    var fscod: UInt32
    var bsid: UInt32
    /// `asvc` (associated service). Always 0 for the main service the engine stream-copies;
    /// preserved when parsed so a rebuild of an unchanged box is byte-identical.
    var asvc: UInt32 = 0
    var bsmod: UInt32
    var acmod: UInt32
    var lfeon: Bool
    /// How many DEPENDENT substreams hang off this independent one.
    var numDepSub: UInt32
    /// Which channels those dependent substreams add (ETSI TS 102 366 Table F.6.1). Only written
    /// when `numDepSub > 0`.
    var chanLoc: UInt32
}

/// A parsed / buildable `dec3` payload.
struct EC3SpecificBox: Equatable {
    /// Bitrate in kbit/s. Carried straight through from the muxer's box on a rewrite: FFmpeg
    /// derives it from real packet sizes and the sample rate, which is strictly better
    /// information than anything a header reader can reconstruct from one frame.
    var dataRate: UInt32
    var substreams: [EC3Substream]
    /// ETSI TS 103 420 `flag_ec3_extension_type_a`: this track carries JOC objects.
    var ec3ExtensionTypeA: Bool
    /// ETSI TS 103 420 `complexity_index_type_a`: the object count. Dolby's DD+ JOC encoders
    /// emit 16, which is also the first parameter of the `CHANNELS="16/JOC"` HLS attribute.
    var complexityIndexTypeA: UInt32

    static let defaultJOCComplexityIndex: UInt32 = 16

    // MARK: - Parse

    /// Decode a `dec3` PAYLOAD (the bytes after the 8-byte box header).
    ///
    /// Returns `nil` for a truncated or self-inconsistent box; the caller then leaves the init
    /// segment alone rather than guessing.
    static func parse(payload: [UInt8]) -> EC3SpecificBox? {
        var r = EAC3BitReader(payload)
        guard let dataRate = r.read(13), let numIndSubMinusOne = r.read(3) else { return nil }

        var substreams: [EC3Substream] = []
        for _ in 0...Int(numIndSubMinusOne) {
            guard let fscod = r.read(2),
                  let bsid = r.read(5),
                  r.skip(1),                       // reserved
                  let asvc = r.read(1),
                  let bsmod = r.read(3),
                  let acmod = r.read(3),
                  let lfeon = r.readFlag(),
                  r.skip(3),                       // reserved
                  let numDepSub = r.read(4)
            else { return nil }
            var chanLoc: UInt32 = 0
            if numDepSub > 0 {
                guard let loc = r.read(9) else { return nil }
                chanLoc = loc
            } else {
                guard r.skip(1) else { return nil } // reserved
            }
            substreams.append(EC3Substream(
                fscod: fscod, bsid: bsid, asvc: asvc, bsmod: bsmod,
                acmod: acmod, lfeon: lfeon, numDepSub: numDepSub, chanLoc: chanLoc))
        }

        // The extension is optional and only recognisable by there being two more whole bytes
        // left after the substream loop's byte alignment. Anything shorter is the plain box.
        var extensionTypeA = false
        var complexity: UInt32 = 0
        // Round the cursor up to the next byte boundary the way the writer's padding does.
        let consumedBytes = (r.bitPosition + 7) / 8
        if payload.count >= consumedBytes + 2 {
            let flagByte = payload[consumedBytes]
            extensionTypeA = (flagByte & 0x01) == 1
            complexity = UInt32(payload[consumedBytes + 1])
        }

        return EC3SpecificBox(
            dataRate: dataRate,
            substreams: substreams,
            ec3ExtensionTypeA: extensionTypeA,
            complexityIndexTypeA: extensionTypeA ? complexity : 0
        )
    }

    // MARK: - Build

    /// Encode the payload. Zero-pads to the next byte boundary exactly as `flush_put_bits` does,
    /// so re-encoding an unchanged parse round-trips to the same bytes.
    ///
    /// `num_ind_sub` is written as `substreams.count - 1` per the spec's off-by-one, and the
    /// array is clamped to the 3-bit field's eight entries.
    func encodePayload() -> [UInt8] {
        var w = EAC3BitWriter()
        let subs = Array(substreams.prefix(8))
        guard !subs.isEmpty else { return [] }
        w.write(dataRate, bits: 13)
        w.write(UInt32(subs.count - 1), bits: 3)
        for s in subs {
            w.write(s.fscod, bits: 2)
            w.write(s.bsid, bits: 5)
            w.write(0, bits: 1)                    // reserved
            w.write(s.asvc, bits: 1)
            w.write(s.bsmod, bits: 3)
            w.write(s.acmod, bits: 3)
            w.write(s.lfeon)
            w.write(0, bits: 3)                    // reserved
            w.write(s.numDepSub, bits: 4)
            if s.numDepSub > 0 {
                w.write(s.chanLoc, bits: 9)
            } else {
                w.write(0, bits: 1)                // reserved
            }
        }
        if ec3ExtensionTypeA {
            // The substream loop always lands on a byte boundary (32 or 24 bits each, plus the
            // 16-bit header), so these two fields are two whole bytes: 0x01 then the index.
            w.write(0, bits: 7)                    // reserved
            w.write(true)                          // flag_ec3_extension_type_a
            w.write(complexityIndexTypeA, bits: 8)
        }
        return w.finish()
    }

    // MARK: - Derivation from the bitstream

    /// Build the box the bitstream actually describes, keeping `dataRate` from the box FFmpeg
    /// wrote (see `dataRate`'s note).
    ///
    /// `frames` is one packet's worth of syncframes: the independent substream(s) first, each
    /// followed by its dependent substream(s). Substreams are keyed by `substreamid`, so a
    /// dependent frame is attributed to the independent substream of the same id -- which is how
    /// E-AC-3 associates them (ETSI TS 102 366 E.1.3.1), not by position.
    ///
    /// `jocDetectedByEngine` is the engine's own authoritative JOC signal (FFmpeg's decoder sets
    /// `AVCodecParameters.profile == 30` only after it has seen the extension). It is used as a
    /// fallback when the `addbsi` walk found no extension: a frame whose dependent substream was
    /// not in this packet, or whose header this reader could not fully walk, must not silently
    /// downgrade a genuinely-JOC track. In that case `complexity_index_type_a` takes
    /// `defaultJOCComplexityIndex` (16), what Dolby's DD+ JOC encoders emit.
    static func derived(
        fromSyncFrames frames: [EAC3SyncFrame],
        dataRate: UInt32,
        jocDetectedByEngine: Bool
    ) -> EC3SpecificBox? {
        let independents = frames.filter { $0.streamType == .independent }
        guard !independents.isEmpty else { return nil }

        var substreams: [EC3Substream] = []
        for ind in independents {
            let dependents = frames.filter { $0.streamType == .dependent && $0.substreamID == ind.substreamID }
            var chanLoc: UInt32 = 0
            for dep in dependents {
                if let map = dep.chanmap {
                    chanLoc |= EAC3Bitstream.chanLoc(fromChanmap: map)
                }
                // A dependent substream with chanmape == 0 declares no custom map; its channels
                // are implied by its own acmod and have no chan_loc representation, so nothing is
                // OR-ed in. That is the (correct) reason a 5.1-only dependent substream leaves
                // chan_loc at 0.
            }
            substreams.append(EC3Substream(
                fscod: ind.fscod,
                bsid: ind.bsid,
                asvc: 0,
                bsmod: ind.bsmod,
                acmod: ind.acmod,
                lfeon: ind.lfeon,
                numDepSub: UInt32(min(dependents.count, 15)),
                chanLoc: chanLoc))
        }

        // JOC can be signalled from either substream depending on the encoder; take whichever
        // frame declares it, and prefer a real parsed complexity index over the default.
        let declaring = frames.first(where: { $0.ec3ExtensionTypeA })
        let joc = declaring != nil || jocDetectedByEngine
        let complexity = declaring?.complexityIndexTypeA ?? defaultJOCComplexityIndex

        return EC3SpecificBox(
            dataRate: dataRate,
            substreams: substreams,
            ec3ExtensionTypeA: joc,
            complexityIndexTypeA: joc ? complexity : 0
        )
    }
}
