//  DsyncJSON.swift
//  Aerio
//
//  Dispatcharr Sync, pure: an ordered JSON value with the same semantics
//  the Android port gets from kotlinx.serialization's JsonElement. Member
//  order is kept (a re-emitted value round-trips byte for byte), numbers
//  keep the literal the writer sent (1 and 1.0 stay distinct, as in
//  JsonPrimitive.content), and the compact encoder writes what
//  JsonObject.toString() writes, so byte sizes match the other platform.
//
//  Pure Foundation only (no UIKit, no SwiftData, no singletons) so
//  Scripts/dsync-tests/run.sh compiles it on its own.

import Foundation

/// One JSON value. `.number` holds the literal text ("10", "1.0", "1e3").
enum DsyncJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([DsyncJSON])
    case object(DsyncObject)

    // ---- builders (JsonPrimitive(x) on Android) ----

    static func int(_ v: Int) -> DsyncJSON { .number(String(v)) }
    static func long(_ v: Int64) -> DsyncJSON { .number(String(v)) }
    /// Kotlin's Double.toString spelling for the common cases ("1.0", "1.5").
    static func double(_ v: Double) -> DsyncJSON { .number(DsyncJSON.kotlinDouble(v)) }

    static func kotlinDouble(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e7 { return String(Int64(v)) + ".0" }
        return "\(v)"
    }

    // ---- accessors (asInt, asLong, asStr, asBool, asDouble on Android) ----

    var isPrimitive: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    /// JsonPrimitive.content: the string itself, or the literal.
    var content: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        case .array, .object: return DsyncJSONEncoder.encode(self)
        }
    }

    /// Kotlin `asInt()`: a non-string primitive whose content parses as Int32.
    var asInt: Int? {
        switch self {
        case .number(let n): return Int32(n).map { Int($0) }
        default: return nil
        }
    }

    var asLong: Int64? {
        switch self {
        case .number(let n): return Int64(n)
        default: return nil
        }
    }

    var asStr: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var asDouble: Double? {
        if case .number(let n) = self { return Double(n) }
        return nil
    }

    var asArray: [DsyncJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var asObject: DsyncObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Compact JSON, as kotlinx JsonElement.toString().
    var compact: String { DsyncJSONEncoder.encode(self) }
}

/// An ordered JSON object. Setting an existing member keeps its position
/// (LinkedHashMap.put); equality ignores order (JsonObject equality).
struct DsyncObject: Equatable, Sendable, Sequence {
    private(set) var keys: [String] = []
    private var storage: [String: DsyncJSON] = [:]

    init() {}

    init(_ pairs: [(String, DsyncJSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    subscript(key: String) -> DsyncJSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    var values: [DsyncJSON] { keys.compactMap { storage[$0] } }
    var entries: [(String, DsyncJSON)] { keys.map { ($0, storage[$0]!) } }

    func contains(_ key: String) -> Bool { storage[key] != nil }

    func filterKeys(_ keep: (String) -> Bool) -> DsyncObject {
        DsyncObject(entries.filter { keep($0.0) })
    }

    /// Kotlin `base.with(pairs)`: a copy with [pairs] put over it.
    func with(_ pairs: (String, DsyncJSON)...) -> DsyncObject {
        var o = self
        for (k, v) in pairs { o[k] = v }
        return o
    }

    func makeIterator() -> IndexingIterator<[(String, DsyncJSON)]> { entries.makeIterator() }

    static func == (a: DsyncObject, b: DsyncObject) -> Bool { a.storage == b.storage }
}

extension Optional where Wrapped == DsyncObject {
    /// `base.with(...)` on a nullable base (Android's private helper).
    func with(_ pairs: (String, DsyncJSON)...) -> DsyncObject {
        var o = self ?? DsyncObject()
        for (k, v) in pairs { o[k] = v }
        return o
    }
}

// MARK: - Encoder

enum DsyncJSONEncoder {
    static func encode(_ v: DsyncJSON) -> String {
        var out = ""
        write(v, into: &out)
        return out
    }

    static func encode(_ o: DsyncObject) -> String { encode(.object(o)) }

    /// UTF-8 size of the compact form (DsyncEnvelopeCodec.byteSize).
    static func byteSize(_ o: DsyncObject) -> Int { encode(o).utf8.count }

    private static func write(_ v: DsyncJSON, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," }
                write(e, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, (k, e)) in o.entries.enumerated() {
                if i > 0 { out += "," }
                writeString(k, into: &out)
                out += ":"
                write(e, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Parser

/// Strict JSON parser that keeps member order and number literals.
enum DsyncJSONParser {
    static let maxDepth = 64

    static func parse(_ text: String) -> DsyncJSON? {
        var p = Cursor(Array(text.utf8))
        p.skipWS()
        guard let v = p.value(depth: 0) else { return nil }
        p.skipWS()
        return p.atEnd ? v : nil
    }

    static func parse(_ data: Data) -> DsyncJSON? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(s)
    }

    static func parseObject(_ text: String) -> DsyncObject? { parse(text)?.asObject }

    private struct Cursor {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        var atEnd: Bool { i >= b.count }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        mutating func lit(_ s: String) -> Bool {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { return false }
            i += u.count
            return true
        }

        mutating func value(depth: Int) -> DsyncJSON? {
            guard depth <= DsyncJSONParser.maxDepth, i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: "{"): return object(depth: depth + 1)
            case UInt8(ascii: "["): return array(depth: depth + 1)
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "t"): return lit("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return lit("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return lit("null") ? .null : nil
            default: return number()
            }
        }

        mutating func object(depth: Int) -> DsyncJSON? {
            i += 1
            var o = DsyncObject()
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: "\""), let k = string() else { return nil }
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipWS()
                guard let v = value(depth: depth) else { return nil }
                o[k] = v
                skipWS()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                return nil
            }
        }

        mutating func array(depth: Int) -> DsyncJSON? {
            i += 1
            var a: [DsyncJSON] = []
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipWS()
                guard let v = value(depth: depth) else { return nil }
                a.append(v)
                skipWS()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                return nil
            }
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= b.count, let s = String(bytes: b[i..<(i + 4)], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func string() -> String? {
            i += 1
            var bytes: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(bytes: bytes, encoding: .utf8)
                }
                if c < 0x20 { return nil }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { return nil }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): bytes.append(0x22)
                    case UInt8(ascii: "\\"): bytes.append(0x5C)
                    case UInt8(ascii: "/"): bytes.append(0x2F)
                    case UInt8(ascii: "b"): bytes.append(0x08)
                    case UInt8(ascii: "f"): bytes.append(0x0C)
                    case UInt8(ascii: "n"): bytes.append(0x0A)
                    case UInt8(ascii: "r"): bytes.append(0x0D)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var cp = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(cp), i + 1 < b.count,
                           b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            guard let lo = hex4(), (0xDC00...0xDFFF).contains(lo) else { return nil }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        }
                        guard let sc = Unicode.Scalar(cp) else { return nil }
                        bytes.append(contentsOf: Array(String(Character(sc)).utf8))
                    default: return nil
                    }
                } else {
                    bytes.append(c)
                    i += 1
                }
            }
            return nil
        }

        mutating func number() -> DsyncJSON? {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            while i < b.count, (0x30...0x39).contains(b[i]) { i += 1; digits += 1 }
            guard digits > 0 else { return nil }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                var f = 0
                while i < b.count, (0x30...0x39).contains(b[i]) { i += 1; f += 1 }
                guard f > 0 else { return nil }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                var e = 0
                while i < b.count, (0x30...0x39).contains(b[i]) { i += 1; e += 1 }
                guard e > 0 else { return nil }
            }
            return String(bytes: b[start..<i], encoding: .ascii).map { .number($0) }
        }
    }
}

// MARK: - Kotlin collection semantics

extension Array {
    /// Kotlin sortedBy / sortedByDescending: a STABLE sort.
    func stableSorted<K: Comparable>(by key: (Element) -> K, descending: Bool = false) -> [Element] {
        enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            if ka != kb { return descending ? ka > kb : ka < kb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Kotlin distinctBy: first occurrence wins, order kept.
    func distinctBy<K: Hashable>(_ key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }

    /// Kotlin groupBy: groups in first-appearance order.
    func groupedOrdered<K: Hashable>(by key: (Element) -> K) -> [(K, [Element])] {
        var order: [K] = []
        var map: [K: [Element]] = [:]
        for e in self {
            let k = key(e)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }

    /// Kotlin maxBy: the FIRST element with the largest key.
    func maxByFirst<K: Comparable>(_ key: (Element) -> K) -> Element? {
        var best: Element?
        var bestKey: K?
        for e in self {
            let k = key(e)
            if bestKey == nil || k > bestKey! { best = e; bestKey = k }
        }
        return best
    }
}

extension Array where Element: Hashable {
    /// Kotlin distinct().
    func distinctOrdered() -> [Element] { distinctBy { $0 } }
}

/// A tiny LinkedHashMap: insertion order kept, re-put keeps the position.
struct DsyncOrderedMap<K: Hashable, V> {
    private(set) var keys: [K] = []
    private var map: [K: V] = [:]

    subscript(key: K) -> V? {
        get { map[key] }
        set {
            if let newValue {
                if map[key] == nil { keys.append(key) }
                map[key] = newValue
            } else if map.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var values: [V] { keys.map { map[$0]! } }
    var entries: [(K, V)] { keys.map { ($0, map[$0]!) } }
    var isEmpty: Bool { keys.isEmpty }
}
