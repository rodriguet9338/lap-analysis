// XRKBytes.swift - little-endian loads over [UInt8] for the XRK parser.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// This file is an independent Swift port; see libxrk's LICENSE for the notice.
//
// Every caller checks `offset + width <= end` before calling these. The loads
// still go through Array subscripts, so a missed check traps instead of
// reading out of bounds.

import Foundation

@inline(__always)
func xrkU16(_ b: [UInt8], _ o: Int) -> UInt16 {
    return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}

@inline(__always)
func xrkI16(_ b: [UInt8], _ o: Int) -> Int16 {
    return Int16(bitPattern: xrkU16(b, o))
}

@inline(__always)
func xrkU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    let b0: UInt32 = UInt32(b[o])
    let b1: UInt32 = UInt32(b[o + 1]) << 8
    let b2: UInt32 = UInt32(b[o + 2]) << 16
    let b3: UInt32 = UInt32(b[o + 3]) << 24
    return b0 | b1 | b2 | b3
}

@inline(__always)
func xrkI32(_ b: [UInt8], _ o: Int) -> Int32 {
    return Int32(bitPattern: xrkU32(b, o))
}

@inline(__always)
func xrkU64(_ b: [UInt8], _ o: Int) -> UInt64 {
    let lo: UInt64 = UInt64(xrkU32(b, o))
    let hi: UInt64 = UInt64(xrkU32(b, o + 4))
    return lo | (hi << 32)
}

@inline(__always)
func xrkF32(_ b: [UInt8], _ o: Int) -> Float {
    return Float(bitPattern: xrkU32(b, o))
}

/// Append a little-endian Int32 to a byte buffer.
@inline(__always)
func xrkAppendI32(_ v: Int32, to out: inout [UInt8]) {
    let u: UInt32 = UInt32(bitPattern: v)
    out.append(UInt8(truncatingIfNeeded: u))
    out.append(UInt8(truncatingIfNeeded: u >> 8))
    out.append(UInt8(truncatingIfNeeded: u >> 16))
    out.append(UInt8(truncatingIfNeeded: u >> 24))
}

/// Null-terminated string, decoded as UTF-8 with replacement characters
/// (libxrk's Rust backend uses `String::from_utf8_lossy`).
func xrkNullTermString(_ b: [UInt8], _ start: Int, _ end: Int) -> String {
    let lo: Int = max(0, min(start, b.count))
    let hi: Int = max(lo, min(end, b.count))
    var stop: Int = lo
    while stop < hi && b[stop] != 0 {
        stop += 1
    }
    return String(decoding: b[lo..<stop], as: UTF8.self)
}

/// Pack up to four ASCII characters into a little-endian token (libxrk `tokdec`).
func xrkToken(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    var shift: UInt32 = 0
    for byte in s.utf8 {
        if shift >= 32 { break }
        result |= UInt32(byte) << shift
        shift += 8
    }
    return result
}

/// Convert a Double to Int64 the way Rust's `as i64` does for in-range finite
/// values (truncation toward zero); nil for NaN/inf/out-of-range instead of
/// trapping.
func xrkInt64(_ d: Double) -> Int64? {
    guard d.isFinite else { return nil }
    guard d > -9.2e18 && d < 9.2e18 else { return nil }
    return Int64(d)
}
