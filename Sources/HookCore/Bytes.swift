// Byte formatting primitives for the hook.
//
// Hand-rolled rather than taken from Foundation so the hook binary stays free
// of it: see the note in `JSONScan.swift` for why that matters.

import Darwin

public func appendInt(_ value: Int, to out: inout [UInt8]) {
    if value == 0 { out.append(UInt8(ascii: "0")); return }
    var v = value
    if v < 0 { out.append(UInt8(ascii: "-")); v = -v }
    var digits: [UInt8] = []
    while v > 0 {
        digits.append(UInt8(ascii: "0") + UInt8(v % 10))
        v /= 10
    }
    out.append(contentsOf: digits.reversed())
}

/// Appends a zero-padded integer, used for fractional seconds.
public func appendPadded(_ value: Int, width: Int, to out: inout [UInt8]) {
    var digits: [UInt8] = []
    var v = value
    while v > 0 {
        digits.append(UInt8(ascii: "0") + UInt8(v % 10))
        v /= 10
    }
    while digits.count < width { digits.append(UInt8(ascii: "0")) }
    out.append(contentsOf: digits.reversed())
}

/// Appends a JSON string literal with the escaping the format requires.
public func appendJSONString(_ value: [UInt8], to out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for byte in value {
        switch byte {
        case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
        case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
        case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
        case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
        case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
        case 0x00...0x1F:
            out.append(contentsOf: Array("\\u00".utf8))
            let hex = Array("0123456789abcdef".utf8)
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        default: out.append(byte)
        }
    }
    out.append(UInt8(ascii: "\""))
}

public func bytes(of string: String) -> [UInt8] { Array(string.utf8) }

public func string(from bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
