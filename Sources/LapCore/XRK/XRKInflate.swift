// XRKInflate.swift - small pure-Swift DEFLATE decoder (after zlib's puff.c),
// used only to recover a truncated .xrz stream.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// libxrk recovers truncated XRZ files with zlib's decompressobj(), which
// returns every byte decoded before the input ran out, including the
// unfinished final block. Apple's Compression framework does the main work;
// when its stream does not reach the end marker, this decoder re-runs the
// stream so the partial last block is recovered the same way zlib does it.
// The longer of the two outputs is used (both are prefixes of the same data).

import Foundation

final class XRKInflater {
    private let input: [UInt8]
    private var pos: Int
    private var bitBuf: UInt32 = 0
    private var bitCount: Int = 0
    private var failed: Bool = false
    private(set) var output: [UInt8] = []

    private struct Huffman {
        var counts: [Int] = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                          257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                          8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// `start` is the offset of the raw DEFLATE data (2 for a zlib stream).
    init(_ input: [UInt8], start: Int) {
        self.input = input
        self.pos = max(0, min(start, input.count))
    }

    /// Decode as much as possible; never throws, stops at the first error.
    static func inflatePartial(_ input: [UInt8], start: Int, capacityHint: Int) -> [UInt8] {
        let inf: XRKInflater = XRKInflater(input, start: start)
        inf.output.reserveCapacity(max(0, capacityHint))
        inf.run()
        return inf.output
    }

    private func run() {
        while !failed {
            let last: Int = bits(1)
            let blockType: Int = bits(2)
            if failed { return }
            switch blockType {
            case 0: stored()
            case 1: fixedBlock()
            case 2: dynamicBlock()
            default: failed = true
            }
            if last == 1 { return }
        }
    }

    /// Next `need` bits (LSB first); sets `failed` and returns 0 at end of input.
    @inline(__always)
    private func bits(_ need: Int) -> Int {
        while bitCount < need {
            if pos >= input.count {
                failed = true
                return 0
            }
            bitBuf |= UInt32(input[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
        let mask: UInt32 = (UInt32(1) << UInt32(need)) &- 1
        let value: UInt32 = bitBuf & mask
        bitBuf = need >= 32 ? 0 : (bitBuf >> UInt32(need))
        bitCount -= need
        return Int(value)
    }

    private func stored() {
        bitBuf = 0
        bitCount = 0
        if pos + 4 > input.count {
            failed = true
            return
        }
        let len: Int = Int(input[pos]) | (Int(input[pos + 1]) << 8)
        let nlen: Int = Int(input[pos + 2]) | (Int(input[pos + 3]) << 8)
        pos += 4
        if len != (~nlen & 0xFFFF) {
            failed = true
            return
        }
        let available: Int = min(len, input.count - pos)
        if available > 0 {
            output.append(contentsOf: input[pos..<(pos + available)])
            pos += available
        }
        if available < len {
            failed = true
        }
    }

    /// Build a canonical Huffman table; nil if over-subscribed.
    private static func construct(_ lengths: [Int]) -> Huffman? {
        var h: Huffman = Huffman()
        for l in lengths {
            if l < 0 || l > 15 { return nil }
            h.counts[l] += 1
        }
        if h.counts[0] == lengths.count {
            return h // no codes: decoding with it fails
        }
        var left: Int = 1
        var len: Int = 1
        while len <= 15 {
            left <<= 1
            left -= h.counts[len]
            if left < 0 { return nil }
            len += 1
        }
        var offs: [Int] = [Int](repeating: 0, count: 16)
        len = 1
        while len < 15 {
            offs[len + 1] = offs[len] + h.counts[len]
            len += 1
        }
        h.symbols = [Int](repeating: 0, count: lengths.count)
        var sym: Int = 0
        while sym < lengths.count {
            let l: Int = lengths[sym]
            if l != 0 {
                h.symbols[offs[l]] = sym
                offs[l] += 1
            }
            sym += 1
        }
        return h
    }

    /// Decode one symbol (canonical code, read MSB-first one bit at a time).
    private func decode(_ h: Huffman) -> Int {
        var code: Int = 0
        var first: Int = 0
        var index: Int = 0
        var len: Int = 1
        while len <= 15 {
            code |= bits(1)
            if failed { return -1 }
            let count: Int = h.counts[len]
            if code - count < first {
                let k: Int = index + (code - first)
                if k >= 0 && k < h.symbols.count {
                    return h.symbols[k]
                }
                failed = true
                return -1
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
            len += 1
        }
        failed = true
        return -1
    }

    private func codes(_ lencode: Huffman, _ distcode: Huffman) {
        while !failed {
            let sym: Int = decode(lencode)
            if failed { return }
            if sym < 256 {
                output.append(UInt8(truncatingIfNeeded: sym))
            } else if sym == 256 {
                return
            } else {
                let s: Int = sym - 257
                if s >= 29 {
                    failed = true
                    return
                }
                let length: Int = XRKInflater.lengthBase[s] + bits(XRKInflater.lengthExtra[s])
                if failed { return }
                let dsym: Int = decode(distcode)
                if failed { return }
                if dsym < 0 || dsym >= 30 {
                    failed = true
                    return
                }
                let dist: Int = XRKInflater.distBase[dsym] + bits(XRKInflater.distExtra[dsym])
                if failed { return }
                if dist > output.count {
                    failed = true
                    return
                }
                var k: Int = 0
                var from: Int = output.count - dist
                while k < length {
                    output.append(output[from])
                    from += 1
                    k += 1
                }
            }
        }
    }

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths: [Int] = [Int](repeating: 8, count: 288)
        var i: Int = 144
        while i < 256 { lengths[i] = 9; i += 1 }
        while i < 280 { lengths[i] = 7; i += 1 }
        let lit: Huffman = XRKInflater.construct(lengths) ?? Huffman()
        let dist: Huffman = XRKInflater.construct([Int](repeating: 5, count: 30)) ?? Huffman()
        return (lit, dist)
    }()

    private func fixedBlock() {
        let tables: (Huffman, Huffman) = XRKInflater.fixedTables
        codes(tables.0, tables.1)
    }

    private func dynamicBlock() {
        let nlen: Int = bits(5) + 257
        let ndist: Int = bits(5) + 1
        let ncode: Int = bits(4) + 4
        if failed { return }
        if nlen > 286 || ndist > 30 {
            failed = true
            return
        }
        var lengths: [Int] = [Int](repeating: 0, count: 19)
        var i: Int = 0
        while i < ncode {
            lengths[XRKInflater.codeLengthOrder[i]] = bits(3)
            i += 1
        }
        if failed { return }
        guard let lencode0 = XRKInflater.construct(lengths) else {
            failed = true
            return
        }
        var all: [Int] = []
        all.reserveCapacity(nlen + ndist)
        while all.count < nlen + ndist {
            let sym: Int = decode(lencode0)
            if failed { return }
            if sym < 16 {
                all.append(sym)
            } else {
                var value: Int = 0
                var repeatCount: Int = 0
                if sym == 16 {
                    guard let prev = all.last else {
                        failed = true
                        return
                    }
                    value = prev
                    repeatCount = 3 + bits(2)
                } else if sym == 17 {
                    repeatCount = 3 + bits(3)
                } else {
                    repeatCount = 11 + bits(7)
                }
                if failed { return }
                if all.count + repeatCount > nlen + ndist {
                    failed = true
                    return
                }
                var r: Int = 0
                while r < repeatCount {
                    all.append(value)
                    r += 1
                }
            }
        }
        if all[256] == 0 {
            failed = true
            return
        }
        guard let lencode = XRKInflater.construct(Array(all[0..<nlen])),
              let distcode = XRKInflater.construct(Array(all[nlen..<(nlen + ndist)])) else {
            failed = true
            return
        }
        codes(lencode, distcode)
    }
}
