// XRKTables.swift - static lookup tables for the XRK parser: units, sample
// decoders, channel functions, logger models, float16.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of crates/libxrk/src/tables.rs and decoders.rs.

import Foundation

enum XRKTables {

    /// unit_type_byte (low 7 bits) -> (unit string, decimal places).
    static func unitMap(_ unitType: UInt8) -> (String, Int) {
        switch unitType & 0x7F {
        case 1: return ("%", 2)
        case 3: return ("g", 2)
        case 4: return ("deg", 1)
        case 5: return ("deg/s", 1)
        case 6: return ("", 0)
        case 8: return ("m", 0)
        case 9: return ("Hz", 0)
        case 11: return ("#", 0)
        case 12: return ("mm", 0)
        case 14: return ("bar", 2)
        case 15: return ("rpm", 0)
        case 16: return ("km/h", 0)
        case 17: return ("C", 1)
        case 18: return ("ms", 0)
        case 19: return ("Nm", 0)
        case 20: return ("km/h", 0)
        case 21: return ("mV", 1)
        case 22: return ("l", 1)
        case 24: return ("l/s", 0)
        case 26: return ("time?", 0)
        case 27: return ("A", 0)
        case 28: return ("%", 2)
        case 30: return ("lambda", 2)
        case 31: return ("gear", 0)
        case 33: return ("%", 2)
        case 43: return ("kg", 3)
        default: return ("", 0)
        }
    }

    /// Display unit; the high bit of unit_type_byte turns "mV" into "V".
    static func resolveUnit(_ unitType: UInt8) -> String {
        let base: String = unitMap(unitType).0
        if (unitType & 0x80) != 0 && base == "mV" {
            return "V"
        }
        return base
    }

    enum SampleKind {
        case int32
        case uint16
        case int16
        case float32
        case uint8
        case gear16
        case float16
    }

    struct DecoderInfo {
        let kind: SampleKind
        let interpolate: Bool
        let byteSize: Int
    }

    /// CHS byte [20] -> sample decoder (libxrk `_decoders` / `decoder_info`).
    static func decoderInfo(_ decoderType: UInt8) -> DecoderInfo? {
        switch decoderType {
        case 0, 3, 8, 12, 22, 24, 26, 27, 31, 32, 33, 37, 38, 39:
            return DecoderInfo(kind: .int32, interpolate: false, byteSize: 4)
        case 1:
            return DecoderInfo(kind: .uint16, interpolate: true, byteSize: 2)
        case 4, 11:
            return DecoderInfo(kind: .int16, interpolate: false, byteSize: 2)
        case 6:
            return DecoderInfo(kind: .float32, interpolate: true, byteSize: 4)
        case 13:
            return DecoderInfo(kind: .uint8, interpolate: false, byteSize: 1)
        case 15:
            return DecoderInfo(kind: .gear16, interpolate: false, byteSize: 2)
        case 20:
            return DecoderInfo(kind: .float16, interpolate: true, byteSize: 2)
        default:
            return nil
        }
    }

    /// Channels decoded as uint64 with gear bit extraction regardless of byte [20].
    static func isManualDecoder(_ name: String) -> Bool {
        return name == "Calculated_Gear" || name == "PreCalcGear"
    }

    /// Decoder 15: ASCII gear characters -> gear number, anything else unchanged.
    static func gearLookup(_ v: UInt16) -> UInt16 {
        switch v {
        case 0x4E: return 0
        case 0x31: return 1
        case 0x32: return 2
        case 0x33: return 3
        case 0x34: return 4
        case 0x35: return 5
        case 0x36: return 6
        default: return v
        }
    }

    /// IEEE 754 binary16 -> Float. Written out by hand because `Float16` is
    /// unavailable on Intel macOS.
    static func halfToFloat(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32((bits >> 15) & 1)
        let exp: UInt32 = UInt32((bits >> 10) & 0x1F)
        let mantissa: UInt32 = UInt32(bits & 0x3FF)
        if exp == 0 {
            if mantissa == 0 {
                return Float(bitPattern: sign << 31)
            }
            var m: UInt32 = mantissa
            var e: Int32 = -14
            while (m & 0x400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x3FF
            let f32Exp: UInt32 = UInt32(e + 127) & 0xFF
            return Float(bitPattern: (sign << 31) | (f32Exp << 23) | (m << 13))
        } else if exp == 31 {
            return Float(bitPattern: (sign << 31) | (UInt32(0xFF) << 23) | (mantissa << 13))
        } else {
            let f32Exp: UInt32 = exp + 112 // exp - 15 + 127
            return Float(bitPattern: (sign << 31) | (f32Exp << 23) | (mantissa << 13))
        }
    }

    /// Channel function name from CHS bytes [13], [12], [14:16]. Not part of
    /// the `Session` model today; kept for parity with libxrk's channel metadata.
    static func resolveFunction(displayFormat: UInt8, unitType: UInt8, configFlags: UInt16) -> String {
        if displayFormat == 0 && unitType == 0x11 && configFlags == 1 {
            return "Device Temperature"
        }
        switch (displayFormat, unitType) {
        case (0, 0x01): return "Percent"
        case (0, 0x03): return "Acceleration"
        case (0, 0x04): return "Angle"
        case (0, 0x05): return "Angular Rate"
        case (0, 0x0b): return "Number"
        case (0, 0x0c): return "Distance"
        case (0, 0x0e): return "Pressure"
        case (0, 0x0f): return "Engine RPM"
        case (0, 0x10): return "Rear Wheel Speed"
        case (0, 0x11): return "Temperature"
        case (0, 0x12): return "Time"
        case (0, 0x15): return "Voltage"
        case (0, 0x91): return "Exhaust Temperature"
        case (0, 0x9a): return "Lap Time"
        case (1, 0x95): return "Battery Voltage"
        case (2, 0x9a): return "Total Odometer"
        case (3, 0x1a): return "Reset Odometer"
        case (5, 0x1a): return "Best Lap Time"
        case (5, 0x9a): return "Rolling Lap Time"
        case (6, 0x06), (6, 0x1f): return "Gear"
        case (9, 0x1e): return "Lambda"
        case (11, 0x91): return "Oil Temperature"
        case (13, 0x84): return "Steering Angle"
        case (14, 0x81): return "Percentage Throttle Load"
        case (16, 0x91), (144, 0x91): return "Water Temperature"
        case (17, 0x03), (145, 0x03): return "Inline Acceleration"
        case (17, 0x05): return "Roll Rate"
        case (17, 0x83), (145, 0x83): return "Lateral Acceleration"
        case (17, 0x85): return "Pitch Rate"
        case (18, 0x03): return "Vertical Acceleration"
        case (18, 0x05), (146, 0x05): return "Yaw Rate"
        case (21, 0x12): return "Master Clock"
        case (26, 0x21): return "Device Brightness"
        case (27, 0x92): return "Best Run Diff"
        case (28, 0x12): return "Prev Lap Diff"
        case (28, 0x92): return "Ref Lap Diff"
        case (35, 0x92): return "Best Today Diff"
        case (128, 0x10): return "Vehicle Speed"
        case (128, 0x91): return "Intake Air Temperature"
        case (128, 0x9a): return "Lap Time"
        case (129, 0x9a): return "GPS Time"
        case (130, 0x0e): return "Brake Circuit Pressure"
        case (169, 0x8c): return "LF Shock Position"
        default: return ""
        }
    }

    static func loggerModelName(_ modelID: UInt16) -> String? {
        switch modelID {
        case 649: return "MXP 1.3"
        case 793: return "MXm"
        default: return nil
        }
    }

    /// Internal channels libxrk never exposes.
    static func isHiddenChannel(_ name: String) -> Bool {
        return name == "StrtRec" || name == "Master Clk"
    }
}
