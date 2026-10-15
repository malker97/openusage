import Foundation

/// Reads a few top-level string or number fields of one JSON object line without decoding the rest.
/// Session logs carry whole files and command output in nested fields, so walking the bytes once —
/// skipping nested values wholesale — is far cheaper than building every line's object tree just to
/// read its ids and timestamp. A nested field with a requested name is never mistaken for a top-level one.
enum JSONTopLevelScalars {
    /// The raw text of each requested top-level field whose value is a string or a number. Strings
    /// containing escape sequences, `null`, booleans, objects, and arrays are left out, as is anything
    /// after the line stops being well-formed. The first occurrence of a repeated key wins.
    static func values(in line: Data, keys: [String]) -> [String: String] {
        let wanted = keys.map { Array($0.utf8) }
        return line.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            return reader.topLevelValues(wanted: wanted, names: keys)
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        private static let quote = UInt8(ascii: "\"")
        private static let backslash = UInt8(ascii: "\\")

        mutating func topLevelValues(wanted: [[UInt8]], names: [String]) -> [String: String] {
            var found: [String: String] = [:]
            skipWhitespace()
            guard consume("{") else { return found }
            while found.count < wanted.count {
                skipWhitespace()
                guard let key = string() else { break }
                skipWhitespace()
                guard consume(":") else { break }
                skipWhitespace()

                let keyBytes = bytes[key.range]
                let match = key.escaped ? nil : wanted.firstIndex(where: { $0.elementsEqual(keyBytes) })
                let valueStart = index
                if let match, found[names[match]] == nil, let text = scalarText() {
                    found[names[match]] = text
                }
                if index == valueStart {
                    guard skipValue() else { break }
                }

                skipWhitespace()
                guard consume(",") else { break }
            }
            return found
        }

        /// A string or number at the cursor, consumed. Escaped strings are consumed but return nil;
        /// any other value type is left in place for `skipValue`.
        private mutating func scalarText() -> String? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if byte == Self.quote {
                guard let value = string(), !value.escaped else { return nil }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[value.range]), as: UTF8.self)
            }
            guard byte == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
                return nil
            }
            let start = index
            skipBareValue()
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        }

        /// The string at the cursor, consumed: its content range (quotes excluded) and whether it
        /// contained an escape sequence. Nil when the cursor isn't at a complete string.
        private mutating func string() -> (range: Range<Int>, escaped: Bool)? {
            guard index < bytes.count, bytes[index] == Self.quote else { return nil }
            index += 1
            let start = index
            var escaped = false
            while index < bytes.count {
                switch bytes[index] {
                case Self.backslash:
                    escaped = true
                    index += 2
                case Self.quote:
                    let range = start..<index
                    index += 1
                    return (range, escaped)
                default:
                    index += 1
                }
            }
            return nil
        }

        /// Skip one complete value of any type. False when the line ends inside it.
        private mutating func skipValue() -> Bool {
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case Self.quote:
                return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case Self.quote:
                        guard string() != nil else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                skipBareValue()
                return true
            }
        }

        /// Numbers, `true`, `false`, and `null` run until the next delimiter.
        private mutating func skipBareValue() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    return
                default:
                    index += 1
                }
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    index += 1
                default:
                    return
                }
            }
        }

        private mutating func consume(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }
    }
}
