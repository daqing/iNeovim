import Foundation

enum MsgPackEncoder {
    static func encode(_ value: MsgPackValue) -> Data {
        var data = Data()
        write(value, to: &data)
        return data
    }

    private static func write(_ value: MsgPackValue, to data: inout Data) {
        switch value {
        case .nil:
            data.append(0xc0)
        case .bool(let bool):
            data.append(bool ? 0xc3 : 0xc2)
        case .int(let int):
            writeInt(int, to: &data)
        case .uint(let uint):
            writeUInt(uint, to: &data)
        case .float(let double):
            data.append(0xcb)
            appendBigEndian(double.bitPattern, byteCount: 8, to: &data)
        case .string(let string):
            let bytes = Data(string.utf8)
            switch bytes.count {
            case 0...31:
                data.append(UInt8(0xa0 | bytes.count))
            case 32...0xff:
                data.append(0xd9)
                data.append(UInt8(bytes.count))
            case 0x100...0xffff:
                data.append(0xda)
                appendBigEndian(UInt64(bytes.count), byteCount: 2, to: &data)
            default:
                data.append(0xdb)
                appendBigEndian(UInt64(bytes.count), byteCount: 4, to: &data)
            }
            data.append(contentsOf: bytes)
        case .binary(let bytes):
            switch bytes.count {
            case 0...0xff:
                data.append(0xc4)
                data.append(UInt8(bytes.count))
            case 0x100...0xffff:
                data.append(0xc5)
                appendBigEndian(UInt64(bytes.count), byteCount: 2, to: &data)
            default:
                data.append(0xc6)
                appendBigEndian(UInt64(bytes.count), byteCount: 4, to: &data)
            }
            data.append(contentsOf: bytes)
        case .array(let array):
            switch array.count {
            case 0...15:
                data.append(UInt8(0x90 | array.count))
            case 16...0xffff:
                data.append(0xdc)
                appendBigEndian(UInt64(array.count), byteCount: 2, to: &data)
            default:
                data.append(0xdd)
                appendBigEndian(UInt64(array.count), byteCount: 4, to: &data)
            }
            for element in array {
                write(element, to: &data)
            }
        case .map(let map):
            switch map.count {
            case 0...15:
                data.append(UInt8(0x80 | map.count))
            case 16...0xffff:
                data.append(0xde)
                appendBigEndian(UInt64(map.count), byteCount: 2, to: &data)
            default:
                data.append(0xdf)
                appendBigEndian(UInt64(map.count), byteCount: 4, to: &data)
            }
            for (key, value) in map {
                write(key, to: &data)
                write(value, to: &data)
            }
        case .ext(let type, let bytes):
            switch bytes.count {
            case 1:
                data.append(0xd4)
            case 2:
                data.append(0xd5)
            case 4:
                data.append(0xd6)
            case 8:
                data.append(0xd7)
            case 16:
                data.append(0xd8)
            case 0...0xff:
                data.append(0xc7)
                data.append(UInt8(bytes.count))
            case 0x100...0xffff:
                data.append(0xc8)
                appendBigEndian(UInt64(bytes.count), byteCount: 2, to: &data)
            default:
                data.append(0xc9)
                appendBigEndian(UInt64(bytes.count), byteCount: 4, to: &data)
            }
            data.append(UInt8(bitPattern: type))
            data.append(contentsOf: bytes)
        }
    }

    /// Non-negative ints always use unsigned markers so that decode(encode(v)) == v
    /// preserves the int/uint distinction, which the wire otherwise lacks.
    private static func writeInt(_ value: Int64, to data: inout Data) {
        switch value {
        case -32 ... -1:
            data.append(UInt8(bitPattern: Int8(value)))
        case -128...127:
            data.append(0xd0)
            appendBigEndian(UInt64(bitPattern: value), byteCount: 1, to: &data)
        case -32768...32767:
            data.append(0xd1)
            appendBigEndian(UInt64(bitPattern: value), byteCount: 2, to: &data)
        case -2147483648...2147483647:
            data.append(0xd2)
            appendBigEndian(UInt64(bitPattern: value), byteCount: 4, to: &data)
        default:
            data.append(0xd3)
            appendBigEndian(UInt64(bitPattern: value), byteCount: 8, to: &data)
        }
    }

    private static func writeUInt(_ value: UInt64, to data: inout Data) {
        switch value {
        case 0...127:
            data.append(UInt8(value))
        case 128...0xff:
            data.append(0xcc)
            data.append(UInt8(value))
        case 0x100...0xffff:
            data.append(0xcd)
            appendBigEndian(value, byteCount: 2, to: &data)
        case 0x10000...0xffff_ffff:
            data.append(0xce)
            appendBigEndian(value, byteCount: 4, to: &data)
        default:
            data.append(0xcf)
            appendBigEndian(value, byteCount: 8, to: &data)
        }
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, to data: inout Data) {
        var shift = (byteCount - 1) * 8
        while shift >= 0 {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
            shift -= 8
        }
    }
}
