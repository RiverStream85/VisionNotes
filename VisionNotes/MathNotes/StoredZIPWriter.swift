import Foundation

/// A small deterministic ZIP writer using the standard "stored" method (no compression).
/// It avoids a third-party dependency and is sufficient for editable text, PDFs and images.
enum StoredZIPWriter {
    private static let maximumArchiveBytes = 250 * 1_024 * 1_024

    struct Entry: Sendable {
        let path: String
        let data: Data
        let modificationDate: Date
    }

    static func write(entries: [Entry], to outputURL: URL) throws {
        let sorted = entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var archive = Data()
        var centralDirectory = Data()

        for entry in sorted {
            try Task.checkCancellation()
            guard let name = sanitizedPath(entry.path).data(using: .utf8),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw MathNoteError.archiveTooLarge
            }
            let crc = CRC32.checksum(entry.data)
            let (time, date) = dosTimestamp(entry.modificationDate)
            let offset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(time)
            archive.appendLE(date)
            archive.appendLE(crc)
            archive.appendLE(size)
            archive.appendLE(size)
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(entry.data)

            centralDirectory.appendLE(UInt32(0x02014b50))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(time)
            centralDirectory.appendLE(date)
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(UInt16(name.count))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0))
            centralDirectory.appendLE(offset)
            centralDirectory.append(name)

            if archive.count + centralDirectory.count > maximumArchiveBytes {
                throw MathNoteError.archiveTooLarge
            }
        }

        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(sorted.count))
        archive.appendLE(UInt16(sorted.count))
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        guard archive.count <= maximumArchiveBytes else { throw MathNoteError.archiveTooLarge }
        try archive.write(to: outputURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func entries(in directory: URL, excludingNames: Set<String> = []) throws -> [Entry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Entry] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true, !excludingNames.contains(url.lastPathComponent) else { continue }
            let path = String(url.path.dropFirst(directory.path.count + 1))
            guard !path.lowercased().contains("providerkeys"), !path.contains("..") else { continue }
            result.append(
                Entry(
                    path: path,
                    data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                    modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                )
            )
        }
        return result
    }

    private static func sanitizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        let year = min(max((components.year ?? 1980) - 1980, 0), 127)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
