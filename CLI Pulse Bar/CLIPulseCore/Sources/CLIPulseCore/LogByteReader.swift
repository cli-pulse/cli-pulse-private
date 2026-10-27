#if os(macOS)
import CZstd
import Foundation

/// A session log's content, read front to back a chunk at a time: a plain
/// file as it is, and a zstd-compressed one (`.zst`) decoded as it is read.
///
/// WHY (1.59.1, N1)
/// ----------------
/// The Codex CLI archives a finished session as `rollout-*.jsonl.zst` and
/// deletes the `.jsonl`. Until 1.59.1 the scanner read only `.jsonl`, so once
/// a session was archived its usage disappeared from This Mac, Projects,
/// Sessions and the cloud. For anyone on a current Codex CLI, every session
/// that has ended is in a `.zst` file, so most of their Codex usage was
/// missing.
///
/// HOW
/// ---
/// The archive is decoded in memory as it is read, with zstd's own decoder
/// (the vendored `CZstd` target), and handed to the same line reader as a
/// plain log. Nothing decoded is written to disk. Memory stays bounded: one
/// compressed and one decoded buffer of zstd's recommended streaming sizes
/// (about 128 KB each), plus the decoder's window, which the frame header
/// sets and which is capped at 128 MB here (`windowLogMax`, 27; Codex's
/// archives use 2 MB). A whole archive is never held at once, and one that
/// decodes to more than `maxDecodedBytes` is refused as `tooLarge`.
///
/// A corrupt or truncated archive is an error (`Failure`), never a short
/// read: a caller that gets no error has the whole content.
final class LogByteReader {
    enum Failure: Error, Equatable {
        /// The decoder rejected the data (not zstd, corrupt, or a window
        /// beyond the limit).
        case corrupt
        /// The file ended inside a frame.
        case truncated
        /// The content is longer than the limit it was opened with.
        case tooLarge
    }

    /// The largest window a frame may ask for, as a power of two: 2^27,
    /// 128 MB, zstd's own default, set explicitly so it cannot drift.
    static let windowLogMax: Int32 = 27

    /// The most content one archive may decode to: 4 GiB, far above any
    /// session log seen (a few hundred MB at most), so a malformed or
    /// hostile file cannot keep the scan decoding forever.
    static let defaultMaxDecodedBytes: Int64 = 4 << 30

    /// Whether `url` names a zstd-compressed log.
    static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zst"
    }

    private let handle: FileHandle?
    private let decoder: ZstdDecoder?
    /// Content already in memory (`init(data:)`), and how far it is read.
    private let memory: Data?
    private var memoryPosition = 0
    private var closed = false

    convenience init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, maxDecodedBytes: Self.defaultMaxDecodedBytes)
    }

    init(fileURL: URL, maxDecodedBytes: Int64) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        self.handle = handle
        memory = nil
        if Self.isCompressed(fileURL) {
            guard let decoder = ZstdDecoder(maxDecodedBytes: maxDecodedBytes) else {
                try? handle.close()
                throw Failure.corrupt
            }
            self.decoder = decoder
        } else {
            decoder = nil
        }
    }

    /// Content already decoded, read the same way: for a check that decodes
    /// with another decoder (`CodexArchivedLogsLocalCheckTests`).
    init(data: Data) {
        handle = nil
        decoder = nil
        memory = data
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle?.close()
    }

    /// Up to `count` bytes of content. Empty only at the end of it.
    func read(upToCount count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        if let memory {
            let end = min(memory.count, memoryPosition + count)
            defer { memoryPosition = end }
            return memory.subdata(in: memory.startIndex + memoryPosition..<memory.startIndex + end)
        }
        guard let handle else { return Data() }
        guard let decoder else { return try handle.read(upToCount: count) ?? Data() }
        return try decoder.read(upToCount: count, from: handle)
    }

    /// Moves `count` bytes into the content: a seek for a plain file, a read
    /// that throws the bytes away for a compressed one.
    func skip(_ count: Int64) throws {
        guard count > 0 else { return }
        if let handle, decoder == nil {
            try handle.seek(toOffset: try handle.offset() + UInt64(count))
            return
        }
        var left = count
        while left > 0 {
            let chunk = try read(upToCount: Int(min(left, 256 * 1024)))
            if chunk.isEmpty { return }
            left -= Int64(chunk.count)
        }
    }
}

/// zstd's streaming decoder over a file handle, with fixed buffers.
private final class ZstdDecoder {
    private let context: OpaquePointer
    private let inputCapacity: Int
    private let outputCapacity: Int
    private let input: UnsafeMutableRawPointer
    private let output: UnsafeMutableRawPointer
    private var inputSize = 0
    private var inputPosition = 0
    private var sourceEnded = false
    /// Whether the last call that moved data ended a frame: at the end of the
    /// file, anything else means it was cut off mid-frame. False before any
    /// data, so an empty file is a truncated one too.
    private var atFrameEnd = false
    private let maxDecodedBytes: Int64
    private var decodedBytes: Int64 = 0

    init?(maxDecodedBytes: Int64) {
        guard let context = ZSTD_createDCtx() else { return nil }
        guard ZSTD_isError(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, LogByteReader.windowLogMax)) == 0 else {
            ZSTD_freeDCtx(context)
            return nil
        }
        self.context = context
        self.maxDecodedBytes = maxDecodedBytes
        inputCapacity = max(1, ZSTD_DStreamInSize())
        outputCapacity = max(1, ZSTD_DStreamOutSize())
        input = UnsafeMutableRawPointer.allocate(byteCount: inputCapacity, alignment: 16)
        output = UnsafeMutableRawPointer.allocate(byteCount: outputCapacity, alignment: 16)
    }

    deinit {
        ZSTD_freeDCtx(context)
        input.deallocate()
        output.deallocate()
    }

    func read(upToCount count: Int, from handle: FileHandle) throws -> Data {
        let room = min(count, outputCapacity)
        while true {
            if inputPosition == inputSize, !sourceEnded {
                let chunk = try handle.read(upToCount: inputCapacity) ?? Data()
                if chunk.isEmpty {
                    sourceEnded = true
                } else {
                    chunk.copyBytes(to: input.assumingMemoryBound(to: UInt8.self), count: chunk.count)
                    inputSize = chunk.count
                    inputPosition = 0
                }
            }
            var inBuffer = ZSTD_inBuffer(src: UnsafeRawPointer(input), size: inputSize, pos: inputPosition)
            var outBuffer = ZSTD_outBuffer(dst: output, size: room, pos: 0)
            let hint = ZSTD_decompressStream(context, &outBuffer, &inBuffer)
            if ZSTD_isError(hint) != 0 { throw LogByteReader.Failure.corrupt }
            let consumed = inBuffer.pos - inputPosition
            inputPosition = inBuffer.pos
            if consumed > 0 || outBuffer.pos > 0 { atFrameEnd = hint == 0 }
            if outBuffer.pos > 0 {
                decodedBytes += Int64(outBuffer.pos)
                if decodedBytes > maxDecodedBytes { throw LogByteReader.Failure.tooLarge }
                return Data(bytes: output, count: outBuffer.pos)
            }
            if inputPosition == inputSize, sourceEnded {
                if !atFrameEnd { throw LogByteReader.Failure.truncated }
                return Data()
            }
            // Input left, room for output, and nothing moved: the decoder is
            // stuck. Never spin on it.
            if consumed == 0, inputPosition < inputSize { throw LogByteReader.Failure.corrupt }
        }
    }
}
#endif
