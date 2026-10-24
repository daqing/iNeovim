import Foundation

nonisolated enum MsgPackError: LocalizedError {
    case invalidMarker(UInt8)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidMarker(let marker):
            "Invalid msgpack marker byte 0x\(String(marker, radix: 16))"
        case .invalidUTF8:
            "Invalid UTF-8 in msgpack string"
        }
    }
}

nonisolated struct MsgPackDecoder {
    private var buffer = Data()

    var bufferedByteCount: Int { buffer.count }

    mutating func feed(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Returns the next complete value, or nil when the buffer does not yet hold
    /// a full object; consumed bytes are removed only on success.
    mutating func nextValue() throws -> MsgPackValue? {
        var index = buffer.startIndex
        guard let value = try readValue(at: &index, in: buffer) else { return nil }
        buffer.removeSubrange(buffer.startIndex..<index)
        return value
    }

    private func readValue(at index: inout Data.Index, in data: Data) throws -> MsgPackValue? {
        guard let marker = readByte(at: &index, in: data) else { return nil }

        switch marker {
        case 0x00...0x7f:
            return .uint(UInt64(marker))
        case 0x80...0x8f:
            return try readMap(count: Int(marker & 0x0f), at: &index, in: data)
        case 0x90...0x9f:
            return try readArray(count: Int(marker & 0x0f), at: &index, in: data)
        case 0xa0...0xbf:
            return try readString(count: Int(marker & 0x1f), at: &index, in: data)
        case 0xc0:
            return .nil
        case 0xc1:
            throw MsgPackError.invalidMarker(marker)
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)
        case 0xc4, 0xc5, 0xc6:
            guard let count = readLength(marker, at: &index, in: data) else { return nil }
            guard let bytes = readBytes(Int(count), at: &index, in: data) else { return nil }
            return .binary(bytes)
        case 0xc7, 0xc8, 0xc9:
            guard let count = readLength(marker, at: &index, in: data) else { return nil }
            return try readExt(count: Int(count), at: &index, in: data)
        case 0xca:
            guard let bits = readUnsigned(4, at: &index, in: data) else { return nil }
            return .float(Double(Float(bitPattern: UInt32(bits))))
        case 0xcb:
            guard let bits = readUnsigned(8, at: &index, in: data) else { return nil }
            return .float(Double(bitPattern: bits))
        case 0xcc, 0xcd, 0xce, 0xcf:
            guard let value = readLength(marker, at: &index, in: data) else { return nil }
            return .uint(value)
        case 0xd0, 0xd1, 0xd2, 0xd3:
            let byteCount = 1 << Int(marker - 0xd0)
            guard let value = readSigned(byteCount, at: &index, in: data) else { return nil }
            return .int(value)
        case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8:
            let count = 1 << Int(marker - 0xd4)
            return try readExt(count: count, at: &index, in: data)
        case 0xd9, 0xda, 0xdb:
            guard let count = readLength(marker, at: &index, in: data) else { return nil }
            return try readString(count: Int(count), at: &index, in: data)
        case 0xdc, 0xdd:
            guard let count = readLength(marker, at: &index, in: data) else { return nil }
            return try readArray(count: Int(count), at: &index, in: data)
        case 0xde, 0xdf:
            guard let count = readLength(marker, at: &index, in: data) else { return nil }
            return try readMap(count: Int(count), at: &index, in: data)
        case 0xe0...0xff:
            return .int(Int64(Int8(bitPattern: marker)))
        default:
            throw MsgPackError.invalidMarker(marker)
        }
    }

    private func readArray(count: Int, at index: inout Data.Index, in data: Data) throws -> MsgPackValue? {
        var elements = [MsgPackValue]()
        for _ in 0..<count {
            guard let element = try readValue(at: &index, in: data) else { return nil }
            elements.append(element)
        }
        return .array(elements)
    }

    private func readMap(count: Int, at index: inout Data.Index, in data: Data) throws -> MsgPackValue? {
        var entries = [MsgPackValue: MsgPackValue]()
        entries.reserveCapacity(min(count, 1024))
        for _ in 0..<count {
            guard let key = try readValue(at: &index, in: data) else { return nil }
            guard let value = try readValue(at: &index, in: data) else { return nil }
            entries[key] = value
        }
        return .map(MsgPackValueMap(entries))
    }

    private func readString(count: Int, at index: inout Data.Index, in data: Data) throws -> MsgPackValue? {
        guard let bytes = readBytes(count, at: &index, in: data) else { return nil }
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw MsgPackError.invalidUTF8
        }
        return .string(string)
    }

    private func readExt(count: Int, at index: inout Data.Index, in data: Data) throws -> MsgPackValue? {
        guard let typeByte = readByte(at: &index, in: data) else { return nil }
        guard let bytes = readBytes(count, at: &index, in: data) else { return nil }
        return .ext(type: Int8(bitPattern: typeByte), data: bytes)
    }

    /// Length field for the given marker; also used for uint8/16/32/64 markers.
    private func readLength(_ marker: UInt8, at index: inout Data.Index, in data: Data) -> UInt64? {
        switch marker {
        case 0xc4, 0xc7, 0xcc, 0xd9:
            guard let byte = readByte(at: &index, in: data) else { return nil }
            return UInt64(byte)
        case 0xc5, 0xc8, 0xcd, 0xda, 0xdc, 0xde:
            return readUnsigned(2, at: &index, in: data)
        case 0xc6, 0xc9, 0xce, 0xdb, 0xdd, 0xdf:
            return readUnsigned(4, at: &index, in: data)
        case 0xcf:
            return readUnsigned(8, at: &index, in: data)
        default:
            return nil
        }
    }

    private func readByte(at index: inout Data.Index, in data: Data) -> UInt8? {
        guard index < data.endIndex else { return nil }
        defer { index += 1 }
        return data[index]
    }

    private func readBytes(_ count: Int, at index: inout Data.Index, in data: Data) -> Data? {
        guard count <= data.distance(from: index, to: data.endIndex) else { return nil }
        defer { index += count }
        return data.subdata(in: index..<index + count)
    }

    private func readUnsigned(_ byteCount: Int, at index: inout Data.Index, in data: Data) -> UInt64? {
        guard let bytes = readBytes(byteCount, at: &index, in: data) else { return nil }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func readSigned(_ byteCount: Int, at index: inout Data.Index, in data: Data) -> Int64? {
        guard let unsigned = readUnsigned(byteCount, at: &index, in: data) else { return nil }
        let shift = 64 - byteCount * 8
        return (Int64(bitPattern: unsigned) << UInt64(shift)) >> UInt64(shift)
    }
}
