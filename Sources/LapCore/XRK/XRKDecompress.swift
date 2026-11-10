// XRKDecompress.swift - XRZ (zlib-wrapped XRK) inflation with Apple's
// Compression framework.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of `decompress_if_zlib` (crates/libxrk/src/lib.rs).
//
// COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), so the 2-byte zlib header is
// skipped and the Adler-32 trailer is ignored. Logger files are often cut
// short mid-stream; like libxrk we keep whatever inflated before the cut.

import Foundation
import Compression

enum XRKZlib {

    /// zlib magic: 0x78 followed by 0x01, 0x9C or 0xDA.
    static func looksCompressed(_ b: [UInt8]) -> Bool {
        guard b.count >= 2 else { return false }
        return b[0] == 0x78 && (b[1] == 0x01 || b[1] == 0x9C || b[1] == 0xDA)
    }

    /// Inflate everything that can be inflated. Returns an empty array when
    /// nothing at all could be decoded.
    static func inflate(_ input: [UInt8]) -> [UInt8] {
        guard input.count > 2 else { return [] }
        let result: (bytes: [UInt8], complete: Bool) = inflateWithCompression(input)
        if result.complete {
            return result.bytes
        }
        // Truncated or damaged stream. Compression may hold back the
        // unfinished last block; recover it the way zlib does.
        let partial: [UInt8] = XRKInflater.inflatePartial(input, start: 2,
                                                          capacityHint: max(result.bytes.count, input.count * 2))
        return partial.count > result.bytes.count ? partial : result.bytes
    }

    /// Streaming decode with Compression. `complete` is true when the
    /// DEFLATE end-of-stream was reached.
    static func inflateWithCompression(_ input: [UInt8]) -> (bytes: [UInt8], complete: Bool) {
        var output: [UInt8] = []
        var complete: Bool = false
        output.reserveCapacity(min(input.count, Int.max / 4) * 3)

        let chunkSize: Int = 1 << 20
        let dst: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dst.deallocate() }
        let stream: UnsafeMutablePointer<compression_stream> = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        let initStatus: compression_status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else { return ([], false) }
        defer { compression_stream_destroy(stream) }

        input.withUnsafeBufferPointer { (src: UnsafeBufferPointer<UInt8>) -> Void in
            guard let base = src.baseAddress, src.count > 2 else { return }
            stream.pointee.src_ptr = base + 2
            stream.pointee.src_size = src.count - 2
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = chunkSize
            // Decode without FINALIZE first so a truncated stream simply
            // stops making progress; then one FINALIZE call to flush.
            var finalize: Bool = false

            while true {
                let srcBefore: Int = stream.pointee.src_size
                let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status: compression_status = compression_stream_process(stream, flags)
                let produced: Int = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer<UInt8>(start: dst, count: produced))
                }
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunkSize

                if status == COMPRESSION_STATUS_END {
                    complete = true
                    break
                }
                if status != COMPRESSION_STATUS_OK {
                    break // corrupt or truncated: keep the partial output
                }
                if produced == 0 && stream.pointee.src_size == srcBefore {
                    if finalize { break }
                    finalize = true
                }
            }
        }
        return (output, complete)
    }
}
