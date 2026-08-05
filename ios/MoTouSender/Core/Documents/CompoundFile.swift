import Foundation

/// Minimal, read-only OLE Compound Binary File reader used by the legacy
/// Word/PowerPoint/Excel extractors. It intentionally exposes streams only;
/// macros, embedded objects and any executable content are never evaluated.
struct CompoundFile {
    private static let signature = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let maximumChainSectors = 1_000_000

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: UInt64
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let rootMiniStream: Data
    private let entries: [DirectoryEntry]

    static func hasSignature(_ data: Data) -> Bool {
        data.count >= signature.count && data.prefix(signature.count) == signature
    }

    init(data: Data, format: String) throws {
        guard Self.hasSignature(data),
              data.uint16LE(at: 28) == 0xFFFE,
              let sectorShift = data.uint16LE(at: 30),
              let miniSectorShift = data.uint16LE(at: 32),
              let fatSectorCount = data.uint32LE(at: 44),
              let firstDirectorySector = data.uint32LE(at: 48),
              let miniStreamCutoff = data.uint32LE(at: 56),
              let firstMiniFatSector = data.uint32LE(at: 60),
              let miniFatSectorCount = data.uint32LE(at: 64),
              let firstDifatSector = data.uint32LE(at: 68),
              let difatSectorCount = data.uint32LE(at: 72) else {
            throw DocumentParsingError.invalidDocument(format)
        }
        let sectorSize = 1 << Int(sectorShift)
        let miniSectorSize = 1 << Int(miniSectorShift)
        guard (sectorSize == 512 || sectorSize == 4_096), miniSectorSize == 64 else {
            throw DocumentParsingError.invalidDocument(format)
        }

        self.data = data
        self.sectorSize = sectorSize
        self.miniSectorSize = miniSectorSize
        self.miniStreamCutoff = UInt64(miniStreamCutoff)

        var fatSectorIDs: [UInt32] = []
        for index in 0..<109 {
            guard let value = data.uint32LE(at: 76 + index * 4) else { break }
            if value != Self.freeSector { fatSectorIDs.append(value) }
        }
        var difatSector = firstDifatSector
        var seenDifat: Set<UInt32> = []
        let difatValuesPerSector = sectorSize / 4 - 1
        for difatIndex in 0..<Int(difatSectorCount) {
            if difatIndex.isMultiple(of: 256), Task.isCancelled {
                throw CancellationError()
            }
            guard difatSector != Self.endOfChain,
                  difatSector != Self.freeSector,
                  seenDifat.insert(difatSector).inserted,
                  let bytes = Self.sectorData(data, sectorSize: sectorSize, id: difatSector) else {
                throw DocumentParsingError.invalidDocument(format)
            }
            for index in 0..<difatValuesPerSector {
                guard let value = bytes.uint32LE(at: index * 4) else { break }
                if value != Self.freeSector { fatSectorIDs.append(value) }
            }
            difatSector = bytes.uint32LE(at: difatValuesPerSector * 4) ?? Self.endOfChain
        }
        if fatSectorIDs.count > Int(fatSectorCount) {
            fatSectorIDs.removeSubrange(Int(fatSectorCount)..<fatSectorIDs.count)
        }
        guard fatSectorIDs.count >= Int(fatSectorCount) else {
            throw DocumentParsingError.invalidDocument(format)
        }

        var fat: [UInt32] = []
        for (fatIndex, id) in fatSectorIDs.prefix(Int(fatSectorCount)).enumerated() {
            if fatIndex.isMultiple(of: 256), Task.isCancelled {
                throw CancellationError()
            }
            guard let bytes = Self.sectorData(data, sectorSize: sectorSize, id: id) else {
                throw DocumentParsingError.invalidDocument(format)
            }
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if let value = bytes.uint32LE(at: offset) { fat.append(value) }
            }
        }
        self.fat = fat

        let directoryData = try Self.readNormalChain(
            data: data,
            sectorSize: sectorSize,
            fat: fat,
            start: firstDirectorySector,
            byteLimit: nil,
            format: format
        )
        var entries: [DirectoryEntry] = []
        for (entryIndex, offset) in stride(
            from: 0,
            through: max(0, directoryData.count - 128),
            by: 128
        ).enumerated() {
            if entryIndex.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard offset + 128 <= directoryData.count,
                  let nameByteCount = directoryData.uint16LE(at: offset + 64),
                  let type = directoryData[safe: offset + 66],
                  let start = directoryData.uint32LE(at: offset + 116),
                  let size = directoryData.uint64LE(at: offset + 120) else { continue }
            let usableNameBytes = max(0, min(Int(nameByteCount) - 2, 64))
            let nameData = directoryData.subdata(in: offset..<(offset + usableNameBytes))
            let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
            if !name.isEmpty {
                entries.append(DirectoryEntry(name: name, type: type, startSector: start, size: size))
            }
        }
        self.entries = entries

        let root = entries.first(where: { $0.type == 5 })
        if let root, root.size > 0 {
            rootMiniStream = try Self.readNormalChain(
                data: data,
                sectorSize: sectorSize,
                fat: fat,
                start: root.startSector,
                byteLimit: root.size,
                format: format
            )
        } else {
            rootMiniStream = Data()
        }

        if miniFatSectorCount > 0,
           firstMiniFatSector != Self.endOfChain,
           firstMiniFatSector != Self.freeSector {
            let bytes = try Self.readNormalChain(
                data: data,
                sectorSize: sectorSize,
                fat: fat,
                start: firstMiniFatSector,
                byteLimit: UInt64(miniFatSectorCount) * UInt64(sectorSize),
                format: format
            )
            var values: [UInt32] = []
            for (valueIndex, offset) in stride(from: 0, to: bytes.count, by: 4).enumerated() {
                if valueIndex.isMultiple(of: 4_096), Task.isCancelled {
                    throw CancellationError()
                }
                if let value = bytes.uint32LE(at: offset) { values.append(value) }
            }
            miniFat = values
        } else {
            miniFat = []
        }
    }

    var streamNames: [String] {
        entries.filter { $0.type == 2 }.map(\.name)
    }

    func hasStream(named name: String) -> Bool {
        entry(named: name) != nil
    }

    func stream(named name: String, format: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        guard entry.size > 0 else { return Data() }
        if entry.size < miniStreamCutoff {
            return try readMiniChain(start: entry.startSector, byteLimit: entry.size, format: format)
        }
        return try Self.readNormalChain(
            data: data,
            sectorSize: sectorSize,
            fat: fat,
            start: entry.startSector,
            byteLimit: entry.size,
            format: format
        )
    }

    private func entry(named name: String) -> DirectoryEntry? {
        entries.first { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func readMiniChain(start: UInt32, byteLimit: UInt64, format: String) throws -> Data {
        var output = Data()
        var sector = start
        var seen: Set<UInt32> = []
        while sector != Self.endOfChain, sector != Self.freeSector, output.count < Int(byteLimit) {
            if seen.count.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard Int(sector) < miniFat.count,
                  seen.count < Self.maximumChainSectors,
                  seen.insert(sector).inserted else {
                throw DocumentParsingError.invalidDocument(format)
            }
            let offset = Int(sector) * miniSectorSize
            guard offset >= 0, offset + miniSectorSize <= rootMiniStream.count else {
                throw DocumentParsingError.invalidDocument(format)
            }
            output.append(rootMiniStream.subdata(in: offset..<(offset + miniSectorSize)))
            sector = miniFat[Int(sector)]
        }
        guard output.count >= Int(byteLimit) else {
            throw DocumentParsingError.invalidDocument(format)
        }
        return output.prefix(Int(byteLimit))
    }

    private static func readNormalChain(
        data: Data,
        sectorSize: Int,
        fat: [UInt32],
        start: UInt32,
        byteLimit: UInt64?,
        format: String
    ) throws -> Data {
        var output = Data()
        var sector = start
        var seen: Set<UInt32> = []
        while sector != endOfChain, sector != freeSector {
            if seen.count.isMultiple(of: 1_024), Task.isCancelled {
                throw CancellationError()
            }
            guard Int(sector) < fat.count,
                  seen.count < maximumChainSectors,
                  seen.insert(sector).inserted,
                  let bytes = sectorData(data, sectorSize: sectorSize, id: sector) else {
                throw DocumentParsingError.invalidDocument(format)
            }
            output.append(bytes)
            if let byteLimit, UInt64(output.count) >= byteLimit { break }
            sector = fat[Int(sector)]
        }
        if let byteLimit {
            guard UInt64(output.count) >= byteLimit else {
                throw DocumentParsingError.invalidDocument(format)
            }
            return output.prefix(Int(byteLimit))
        }
        return output
    }

    private static func sectorData(_ data: Data, sectorSize: Int, id: UInt32) -> Data? {
        let offset = (Int(id) + 1) * sectorSize
        guard offset >= sectorSize, offset + sectorSize <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + sectorSize))
    }
}

private struct DirectoryEntry {
    let name: String
    let type: UInt8
    let startSector: UInt32
    let size: UInt64
}

private extension Data {
    subscript(safe index: Int) -> UInt8? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }

    func uint64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { raw in
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(raw[offset + index]) << UInt64(index * 8)
            }
            return value
        }
    }
}
