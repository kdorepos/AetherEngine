import Foundation
@testable import AetherEngine

// =====================================================================================
// LongGOPFixture: a 12 s Matroska file whose two video keyframes are 10 s apart
//
// The software path's mid-GOP start (a load at a position between two keyframes) needs a
// GOP long enough that the decode lead-in clearly exceeds both the 2 s anchor tolerance and
// the 4 s audio look-ahead. Real films with x264's default 250-frame GOP run 10.4 s at
// 23.976 fps; this file mirrors that shape at a size small enough to embed, so the test
// runs on CI without a fixture fetch.
//
// Video: H.264 baseline, 32x32, 4 fps, keyframes at exactly 0 s and 10 s, no B-frames.
// Audio: AAC-LC mono 8 kHz of digital silence (a test must not make sound), first packet
// at -0.128 s (the encoder's priming). Regenerate with:
//
//     ffmpeg -f lavfi -i "testsrc2=s=32x32:r=4:d=12" \
//       -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=8000:d=12" \
//       -map 0:v -map 1:a -c:v libx264 -preset ultrafast -profile:v baseline -crf 51 \
//       -g 40 -keyint_min 40 -sc_threshold 0 -x264-params "bframes=0" -pix_fmt yuv420p \
//       -c:a aac -b:a 8k -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
//       -f matroska long-gop.mkv
// =====================================================================================
enum LongGOPFixture {

    /// Presentation times of the video keyframes, in seconds.
    static let keyframeSeconds: [Double] = [0, 10]

    /// Frame interval of the video, in seconds.
    static let frameIntervalSeconds = 0.25

    static var data: Data { Data(base64Encoded: base64.joined())! }

    private static let base64 = [
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAN3xFNm3TAv4SijOaTTbuLU6uEFUmp",
        "ZlOsgaFNu4tTq4QWVK5rU6yBzE27jFOrhBJUw2dTrIIBtk27jFOrhBxTu2tTrIINsewBAAAAAAAAUwAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmp",
        "Zqa/hF2oElcq17GDD0JATYCETGF2ZldBhExhdmZEiYhAx7AAAAAAABZUrmtA5L+Ev143Bq4BAAAAAAAAgdeBAXPFiAAAAAAA",
        "AAABnIEAIrWcg3VuZIiBAIaPVl9NUEVHNC9JU08vQVZDg4EBI+ODhA7msoDgkLCBILqBIJqBAlWwhFW5gQFV7oEA7AEAAAAA",
        "AAACAABjoqYBQsAK/+EAFmdCwAraJbARAAADAAEAAAMACA8SJqABAAVozgGXIK4BAAAAAAAAS9eBAnPFiAAAAAAAAAACnIEA",
        "IrWcg3VuZIiBAIaFQV9BQUNWqoQHoSAAg4EC4ZGfgQG1iEC/QAAAAAAAYmSBIFXugQBjooUViFblABJUw2dApL+EukOy0XNz",
        "zmPAi2PFiAAAAAAAAAABZ8iZRaOHRU5DT0RFUkSHjExhdmMgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MTIuMDAw",
        "MDAwMDAwAHNzymPAi2PFiAAAAAAAAAACZ8iVRaOHRU5DT0RFUkSHiExhdmMgYWFjZ8ihRaOIRFVSQVRJT05Eh5MwMDowMDox",
        "Mi4xMjgwMDAwMDAAH0O2dUYCv4Qdgayk54EAo4iCAACAARggB6NCvoEAAIAAAAJTBgX//0/cRem95tlIt5Ys2CDZI+7veDI2",
        "NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1",
        "IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6",
        "MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFu",
        "Z2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBj",
        "aHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRl",
        "Y2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWln",
        "aHRwPTAga2V5aW50PTQwIGtleWludF9taW49MjEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0w",
        "IGNyZj01MS4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAF9l",
        "iIQ6DGCFY7Z6Yt9aN7NGESEoaihCbGLfejUAmh9pA9MLwTBfAb8PwKttu3ysXVTqmSoYYJEZIDT4JKBxug2Yx6GJVqKODGOI",
        "FgaYwZXwmvhS+CvgLxI8cDGD/i8XgKOIggCAgAEYIAejiIIBAIABGCAHo5iBAPoAAAAAEEGaIrzwn+AXGXqELHET5ICjiIIB",
        "gIABGCAHo4iCAgCAARggB6OYgQH0AAAAABBBmkGvPF+gdvToHD05j+FJo4iCAoCAARggB6OIggMAgAEYIAejk4EC7gAAAAAL",
        "QZpgSvPF7ufF8kCjiIIDgIABGCAHo4iCBACAARggB6OWgQPoAAAAAA5BmoBq8J6VoqhP8u3bcKOIggSAgAEYIAejiIIFAIAB",
        "GCAHo5yBBOIAAAAAFEGaoHrwlsG06bEn8m1a8TTp06dQo4iCBYCAARggB6OIggYAgAEYIAejlYEF3AAAAAANQZrAevP6nj5B",
        "9dQFqqOIggaAgAEYIAejiIIHAIABGCAHo5CBBtYAAAAACEGa4Hp8m91Ao4iCB4CAARggB6OIgggAgAEYIAejjYEH0AAAAAAF",
        "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",
        "8IEe",
    ]
}
