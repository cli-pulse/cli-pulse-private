import Foundation

#if os(macOS)

/// zstd frames for tests, written without a compressor.
///
/// The app links zstd's decoder only. A zstd frame may hold its content in
/// "raw" blocks (RFC 8878 §3.1.1.2: block type 0, the bytes as they are), and
/// any zstd decoder reads such a frame, so tests can turn any log into a valid
/// `.jsonl.zst` here. What real compression adds (entropy-coded blocks, a
/// checksum) is covered by the fixture that the zstd CLI compressed
/// (`Fixtures/codex-archived/`).
enum ZstdTestFrames {
    /// One frame holding `content` in raw blocks of at most `blockSize` bytes
    /// (128 KB, the format's largest). No content size, no checksum.
    static func raw(_ content: Data, blockSize: Int = 128 * 1024) -> Data {
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD]) // magic number, little-endian 0xFD2FB528
        frame.append(0x00) // frame header descriptor: no content size, no checksum, no dictionary
        frame.append(0x38) // window descriptor: exponent 7, mantissa 0 → 2^17 = 128 KB
        var offset = content.startIndex
        repeat {
            let end = min(content.endIndex, offset + blockSize)
            let size = end - offset
            let last: UInt32 = end == content.endIndex ? 1 : 0
            let header = last | (0 << 1) | (UInt32(size) << 3) // last-block flag, raw type, size
            frame.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)])
            frame.append(content[offset..<end])
            offset = end
        } while offset < content.endIndex
        return frame
    }

    /// Writes `content` to `url` as a raw-block `.zst`.
    static func write(_ content: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try raw(content).write(to: url)
    }
}

#endif
