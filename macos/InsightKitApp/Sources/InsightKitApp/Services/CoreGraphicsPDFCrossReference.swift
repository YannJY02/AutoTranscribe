import Foundation

/// Repairs only unused slots in the final classic xref table emitted by our PDF exporter.
/// Object bytes are never rewritten. This is not a repair API for arbitrary PDF files.
enum CoreGraphicsPDFCrossReference {
    enum RepairError: Error {
        case unsupportedFormat
        case malformedCrossReference
        case malformedObject
        case referencedUnusedEntry
    }

    private struct Entry {
        let offset: Int
        let generation: Int
        let inUse: Bool
        let recordStart: Int
    }

    private enum Value {
        case integer(Int)
        case reference(Int)
        case name(String)
        case dictionary([String: Value])
        case other
    }

    static func repairUnusedEntries(in data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.starts(with: Array("%PDF-".utf8)) else { throw RepairError.unsupportedFormat }
        let (xrefOffset, suffixStart) = try finalCrossReference(in: bytes)
        var table = Reader(bytes: bytes, position: xrefOffset, limit: suffixStart)
        try table.expect("xref")
        guard try table.integer() == 0 else { throw RepairError.unsupportedFormat }
        let count = try table.integer()
        table.skipWhitespace()
        guard count > 0, count <= (table.limit - table.position) / 20 else {
            throw RepairError.malformedCrossReference
        }

        var entries: [Entry] = []
        var unused = Set<Int>()
        for number in 0..<count {
            let start = table.position
            let offset = try decimal(bytes, start: start, length: 10)
            let generation = try decimal(bytes, start: start + 11, length: 5)
            let state = bytes[start + 17]
            let ending = Array(bytes[(start + 18)..<(start + 20)])
            guard bytes[start + 10] == 32, bytes[start + 16] == 32,
                  generation <= 65_535, state == 110 || state == 102,
                  ending == [32, 10] || ending == [32, 13] || ending == [13, 10]
            else { throw RepairError.malformedCrossReference }
            if state == 110 {
                guard offset < xrefOffset else { throw RepairError.malformedCrossReference }
                if offset == 0 {
                    guard number != 0, generation == 0 else { throw RepairError.unsupportedFormat }
                    unused.insert(number)
                }
            } else if offset >= count {
                throw RepairError.malformedCrossReference
            }
            entries.append(Entry(offset: offset, generation: generation, inUse: state == 110, recordStart: start))
            table.position += 20
        }
        guard !entries[0].inUse, entries[0].generation == 65_535 else {
            throw RepairError.malformedCrossReference
        }
        // Clean output needs no object parsing or restrictions on unrelated PDF features.
        guard !unused.isEmpty else { return data }

        guard entries.allSatisfy({ $0.inUse ? $0.generation == 0 : $0.generation == 65_535 && $0.offset == 0 }) else {
            throw RepairError.unsupportedFormat
        }
        try table.expect("trailer")
        guard case let .dictionary(trailer) = try table.value(),
              case let .integer(size)? = trailer["Size"], size == count,
              case .reference? = trailer["Root"],
              trailer["Prev"] == nil, trailer["XRefStm"] == nil, trailer["Encrypt"] == nil
        else { throw RepairError.unsupportedFormat }
        table.skipWhitespace()
        guard table.position == suffixStart else { throw RepairError.malformedCrossReference }

        let objects = entries.indices.filter { entries[$0].inUse && entries[$0].offset > 0 }
            .sorted { entries[$0].offset < entries[$1].offset }
        guard let first = objects.first,
              Set(objects.map { entries[$0].offset }).count == objects.count
        else { throw RepairError.malformedCrossReference }
        var prefix = Reader(bytes: bytes, position: 0, limit: entries[first].offset)
        prefix.skipWhitespace()
        guard prefix.position == prefix.limit else { throw RepairError.malformedObject }
        var references = table.references

        for (index, number) in objects.enumerated() {
            let end = index + 1 < objects.count ? entries[objects[index + 1]].offset : xrefOffset
            var object = Reader(bytes: bytes, position: entries[number].offset, limit: end)
            guard try object.integer() == number, try object.integer() == 0 else {
                throw RepairError.malformedObject
            }
            try object.expect("obj")
            let value = try object.value()
            if object.consume("stream") {
                guard case let .dictionary(dictionary) = value,
                      case let .integer(length)? = dictionary["Length"], length >= 0
                else { throw RepairError.unsupportedFormat }
                if case let .name(type)? = dictionary["Type"], type == "ObjStm" || type == "XRef" {
                    throw RepairError.unsupportedFormat
                }
                // Length is measured from the mandatory end-of-line after `stream`.
                try object.streamNewline()
                guard length <= object.limit - object.position else { throw RepairError.malformedObject }
                object.position += length
                try object.expect("endstream")
            }
            try object.expect("endobj")
            object.skipWhitespace()
            guard object.position == end else { throw RepairError.malformedObject }
            references.formUnion(object.references)
        }
        guard references.isDisjoint(with: unused) else { throw RepairError.referencedUnusedEntry }
        guard references.isSubset(of: Set(objects)) else { throw RepairError.malformedObject }

        var repaired = Data(bytes)
        let retired = Array("0000000000 65535 f".utf8)
        for number in unused {
            let start = entries[number].recordStart
            repaired.replaceSubrange(start..<(start + retired.count), with: retired)
        }
        return repaired
    }

    private static func finalCrossReference(in bytes: [UInt8]) throws -> (Int, Int) {
        var end = bytes.count
        while end > 0 && whitespace(bytes[end - 1]) { end -= 1 }
        let eof = Array("%%EOF".utf8)
        guard end >= eof.count, Array(bytes[(end - eof.count)..<end]) == eof else {
            throw RepairError.malformedCrossReference
        }
        end -= eof.count
        guard end > 0, whitespace(bytes[end - 1]) else { throw RepairError.malformedCrossReference }
        while end > 0 && whitespace(bytes[end - 1]) { end -= 1 }
        let numberEnd = end
        while end > 0 && (48...57).contains(bytes[end - 1]) { end -= 1 }
        let offset = try decimal(bytes, start: end, length: numberEnd - end)
        guard end > 0, whitespace(bytes[end - 1]) else { throw RepairError.malformedCrossReference }
        while end > 0 && whitespace(bytes[end - 1]) { end -= 1 }
        let keyword = Array("startxref".utf8)
        guard end >= keyword.count, Array(bytes[(end - keyword.count)..<end]) == keyword else {
            throw RepairError.malformedCrossReference
        }
        let start = end - keyword.count
        guard start > 0, whitespace(bytes[start - 1]), offset > 0, offset < start else {
            throw RepairError.malformedCrossReference
        }
        return (offset, start)
    }

    private static func decimal(_ bytes: [UInt8], start: Int, length: Int) throws -> Int {
        guard length > 0, start >= 0, start <= bytes.count, length <= bytes.count - start else {
            throw RepairError.malformedCrossReference
        }
        var value = 0
        for byte in bytes[start..<(start + length)] {
            guard (48...57).contains(byte), value <= (Int.max - Int(byte - 48)) / 10 else {
                throw RepairError.malformedCrossReference
            }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    private static func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
    private static func delimiter(_ byte: UInt8) -> Bool { whitespace(byte) || [40, 41, 60, 62, 91, 93, 47, 37].contains(byte) }

    /// The exporter uses ordinary objects, direct stream lengths and shallow PDF values.
    /// Strings and stream bytes are opaque; only syntactic indirect references are collected.
    private struct Reader {
        let bytes: [UInt8]
        var position: Int
        let limit: Int
        var references = Set<Int>()

        mutating func skipWhitespace() {
            while position < limit {
                if whitespace(bytes[position]) { position += 1 }
                else if bytes[position] == 37 {
                    while position < limit && bytes[position] != 10 && bytes[position] != 13 { position += 1 }
                } else { break }
            }
        }

        mutating func atom() throws -> String {
            skipWhitespace()
            let start = position
            while position < limit && !delimiter(bytes[position]) { position += 1 }
            guard position > start else { throw RepairError.malformedObject }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        mutating func integer() throws -> Int {
            let word = try atom()
            guard let number = Int(word), !word.isEmpty, word.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw RepairError.malformedObject
            }
            return number
        }

        mutating func expect(_ keyword: String) throws {
            guard try atom() == keyword else { throw RepairError.malformedObject }
        }

        mutating func consume(_ keyword: String) -> Bool {
            let saved = position
            if (try? atom()) == keyword { return true }
            position = saved
            return false
        }

        mutating func streamNewline() throws {
            guard position < limit else { throw RepairError.malformedObject }
            if bytes[position] == 13 {
                position += 1
                if position < limit && bytes[position] == 10 { position += 1 }
            } else if bytes[position] == 10 { position += 1 }
            else { throw RepairError.malformedObject }
        }

        mutating func value(depth: Int = 0) throws -> Value {
            guard depth < 64 else { throw RepairError.unsupportedFormat }
            skipWhitespace()
            guard position < limit else { throw RepairError.malformedObject }
            switch bytes[position] {
            case 40:
                try literalString()
                return .other
            case 47:
                return .name(try name())
            case 91:
                position += 1
                while true {
                    skipWhitespace()
                    guard position < limit else { throw RepairError.malformedObject }
                    if bytes[position] == 93 { position += 1; return .other }
                    _ = try value(depth: depth + 1)
                }
            case 60:
                position += 1
                guard position < limit else { throw RepairError.malformedObject }
                if bytes[position] != 60 {
                    while position < limit && bytes[position] != 62 {
                        guard whitespace(bytes[position]) || hex(bytes[position]) != nil else { throw RepairError.malformedObject }
                        position += 1
                    }
                    guard position < limit else { throw RepairError.malformedObject }
                    position += 1
                    return .other
                }
                position += 1
                var dictionary: [String: Value] = [:]
                while true {
                    skipWhitespace()
                    guard position < limit else { throw RepairError.malformedObject }
                    if bytes[position] == 62 {
                        guard position + 1 < limit, bytes[position + 1] == 62 else { throw RepairError.malformedObject }
                        position += 2
                        return .dictionary(dictionary)
                    }
                    let key = try name()
                    guard dictionary[key] == nil else { throw RepairError.unsupportedFormat }
                    dictionary[key] = try value(depth: depth + 1)
                }
            default:
                let word = try atom()
                if ["true", "false", "null"].contains(word) { return .other }
                if let number = Int(word) {
                    let saved = position
                    if let generation = try? integer(), consume("R") {
                        guard number > 0, generation == 0 else { throw RepairError.unsupportedFormat }
                        references.insert(number)
                        return .reference(number)
                    }
                    position = saved
                    return .integer(number)
                }
                guard word.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46].contains($0) }),
                      let number = Double(word), number.isFinite
                else { throw RepairError.malformedObject }
                return .other
            }
        }

        mutating func name() throws -> String {
            skipWhitespace()
            guard position < limit, bytes[position] == 47 else { throw RepairError.malformedObject }
            position += 1
            var decoded: [UInt8] = []
            while position < limit && !delimiter(bytes[position]) {
                if bytes[position] == 35 {
                    guard position + 2 < limit, let high = hex(bytes[position + 1]), let low = hex(bytes[position + 2]) else {
                        throw RepairError.malformedObject
                    }
                    decoded.append(high * 16 + low)
                    position += 3
                } else { decoded.append(bytes[position]); position += 1 }
            }
            return String(decoding: decoded, as: UTF8.self)
        }

        mutating func literalString() throws {
            position += 1
            var nesting = 1
            while position < limit {
                let byte = bytes[position]
                position += 1
                if byte == 92 {
                    guard position < limit else { throw RepairError.malformedObject }
                    if bytes[position] == 13 && position + 1 < limit && bytes[position + 1] == 10 { position += 1 }
                    position += 1
                } else if byte == 40 {
                    nesting += 1
                } else if byte == 41 {
                    nesting -= 1
                    if nesting == 0 { return }
                }
            }
            throw RepairError.malformedObject
        }

        private func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
    }
}
