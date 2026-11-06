import Foundation

/// The phone name Samsung puts in its Bluetooth announcement.
///
/// Quick Share's Wi-Fi record often has no name. The same phone repeats the
/// name under Bluetooth service `FEF3`, next to the 4-character id that is
/// also inside the Wi-Fi service name.
public enum QuickShareBLE {

    public struct Sighting: Equatable {
        public var endpointID: String
        public var name: String?
    }

    /// The 4-character id inside a Quick Share Bonjour service name.
    public static func endpointID(fromServiceName name: String) -> String? {
        guard let raw = Data.fromUrlSafeBase64(name), raw.count == 10 else { return nil }
        let bytes = [UInt8](raw)
        guard bytes[5] == 0xFC, bytes[6] == 0x9F, bytes[7] == 0x5E else { return nil }
        let id = Data(bytes[1..<5])
        guard let text = String(bytes: id, encoding: .utf8), text.count == 4 else { return nil }
        return text
    }

    /// Reads one `FEF3` service-data value.
    public static func parse(serviceData: Data) -> Sighting? {
        let bytes = [UInt8](serviceData)
        if String(bytes: bytes, encoding: .ascii) == "QCAAABACAAADAAAAAAAAAAA" { return nil }
        guard let record = endpointRecord(bytes) else { return nil }
        let named = displayName(in: record.info) ?? lengthPrefixedName(in: bytes, excluding: record.id)
        return Sighting(endpointID: record.id, name: named)
    }

    public static func isDeviceName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "'’-.()"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private struct Record {
        var id: String
        var info: Data
    }

    private static func endpointRecord(_ bytes: [UInt8]) -> Record? {
        guard let flags = bytes.first else { return nil }
        if flags & 0x02 != 0 {
            guard bytes.count >= 2 else { return nil }
            let length = Int(bytes[1])
            guard bytes.count >= 2 + length else { return nil }
            return readRecord(Array(bytes[2..<(2 + length)]), fast: true)
        }
        guard bytes.count >= 8 else { return nil }
        let length = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard length > 0, bytes.count >= 8 + length else { return nil }
        return readRecord(Array(bytes[8..<(8 + length)]), fast: false)
    }

    private static func readRecord(_ record: [UInt8], fast: Bool) -> Record? {
        guard let first = record.first, first & 0xE0 == 0x20 else { return nil }
        var index = 1
        if !fast {
            guard record.count >= index + 3 else { return nil }
            index += 3
        }
        guard record.count >= index + 5 else { return nil }
        let idData = Data(record[index..<(index + 4)])
        guard let id = String(bytes: idData, encoding: .utf8), id.count == 4 else { return nil }
        index += 4
        let infoLength = Int(record[index])
        index += 1
        guard record.count >= index + infoLength else { return nil }
        return Record(id: id, info: Data(record[index..<(index + infoLength)]))
    }

    private static func displayName(in info: Data) -> String? {
        if info.count >= 17, let parsed = try? EndpointInfo(serialized: info),
           let name = parsed.name, isDeviceName(name) {
            return name
        }
        if let text = String(bytes: info, encoding: .utf8), isDeviceName(text) {
            return text
        }
        return nil
    }

    /// A length-prefixed name sitting somewhere else in the same announcement.
    private static func lengthPrefixedName(in bytes: [UInt8], excluding endpointID: String) -> String? {
        var best: String?
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            let start = index + 1
            if length >= 2, start + length <= bytes.count,
               let text = String(bytes: bytes[start..<(start + length)], encoding: .utf8),
               text != endpointID, isDeviceName(text),
               best == nil || text.count > best!.count {
                best = text
            }
            index += 1
        }
        return best
    }
}
