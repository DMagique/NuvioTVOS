import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

struct PreciseSeekThumbnailTests {
    @Test("Precise previews decode past the keyframe on zero and absolute segment timelines")
    func relativeSegmentFrames() throws {
        let original = try #require(Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters))
        let first = try decode(original, offset: 0)
        let precise = try decode(original, offset: 1.25)
        #expect(first != precise)

        // Simulate a resident segment whose tfdt still uses the title's absolute axis.
        var shifted = original
        let marker = try #require(shifted.range(of: Data("tfdt".utf8)))
        #expect(shifted[marker.upperBound] == 1)
        var timestamp = UInt64(120 * 16384).bigEndian
        let start = marker.upperBound + 4
        withUnsafeBytes(of: &timestamp) { shifted.replaceSubrange(start..<(start + 8), with: $0) }
        #expect(try decode(shifted, offset: 0) == first)
        #expect(try decode(shifted, offset: 1.25) == precise)
    }

    @Test("Precise previews preserve playback starvation gating and resume at the requested scene")
    func preciseAPIYieldsAndResumes() async throws {
        let data = try #require(Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters))
        let starved = AtomicBool(true)
        let extractor = FrameExtractor(reader: DataIOReader(data: data), formatHint: "mp4",
                                       yieldWhile: { starved.get() })
        let yielded = await extractor.preciseThumbnail(at: 1.25, maxWidth: 32)
        #expect(yielded == nil)
        starved.set(false)
        let fast = await extractor.thumbnail(at: 1.25, maxWidth: 32)
        let precise = await extractor.preciseThumbnail(at: 1.25, maxWidth: 32)
        await extractor.shutdown()
        let image = try #require(precise)
        let pixels = try #require(image.dataProvider?.data) as Data
        let fastPixels = try #require(fast?.dataProvider?.data) as Data
        #expect(fastPixels != pixels, "The precise request must refine the fast keyframe cache")
        #expect(pixels == (try decode(data, offset: 1.25)))
    }

    private func decode(_ data: Data, offset: Double) throws -> Data {
        let context = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: "mp4", allowsHardwareDecode: false)
        defer { context.close() }
        try context.ensureOpen()
        let image = try #require(context.decodeFrame(
            at: offset, mode: .snapshot, targetWidth: 32,
            maxSize: CGSize(width: 32, height: 32), isCancelled: { false },
            relativeToFirstFrame: true))
        return try #require(image.dataProvider?.data) as Data
    }

    // Two seconds at 4 fps, red then blue, one MPEG-4 GOP in an fMP4 segment.
    private static let fixture = """
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAy1tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACL3Ry
        YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAEAAAAAAIAAAACAAAAAAActtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAA
        dmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAF2bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAA
        AAAAAAABAAAADHVybCAAAAABAAABNnN0YmwAAADqc3RzZAAAAAAAAAABAAAA2m1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAA
        IAAgAEgAAABIAAAAAAAAAAETTGF2YzYyLjI4LjEwMiBtcGVnNAAAAAAAAAAAAAAAAAAY//8AAABgZXNkcwAAAAADgICATwABAASA
        gIBBIBEAAAAAAw1AAAMNQAWAgIAvAAABsAEAAAG1iRMAAAEAAAABIADEjYgAJQEEBBRDAAABskxhdmM2Mi4yOC4xMDIGgICAAQIA
        AAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAMNQAADDUAAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6
        AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAChtdmV4AAAAIHRyZXgAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAAAAABidWR0
        YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEA
        AAAATGF2ZjYyLjEyLjEwMgAAAIhtb29mAAAAEG1maGQAAAAAAAAAAQAAAHB0cmFmAAAAHHRmaGQAAgA4AAAAAQAAEAAAAAAkAQEA
        AAAAABR0ZmR0AQAAAAAAAAAAAAAAAAAAOHRydW4AAAIFAAAACAAAAJACAAAAAAAAJAAAAAsAAAALAAAACwAAACAAAAALAAAACwAA
        AAsAAACObWRhdAAAAbMAEAcAAAG2EwKMKDbBZA8I22/fAADCRhQbYLIHhG237wAAAbZXgR0AAMJvAAABtlsBHQAAwm8AAAG2X4Ed
        AADCbwAAAbZpgIhjBUNsDwC0MbbfvwAAwgYwVDbA8AtDG237AAABtleBHQAAwm8AAAG2WwEdAADCbwAAAbZfgR0AAMJvAAAAQ21m
        cmEAAAArdGZyYQEAAAAAAAABAAAAAAAAAAEAAAAAAAAAAAAAAAAAAANJAQEBAAAAEG1mcm8AAAAAAAAAQw==
        """
}
