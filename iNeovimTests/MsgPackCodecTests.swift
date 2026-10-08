import XCTest
@testable import iNeovim

@MainActor
final class MsgPackCodecTests: XCTestCase {
    func testNilAndBool() throws {
        assertEncodes(.nil, to: [0xc0])
        assertEncodes(.bool(false), to: [0xc2])
        assertEncodes(.bool(true), to: [0xc3])
        try assertRoundTrip(.nil)
        try assertRoundTrip(.bool(false))
        try assertRoundTrip(.bool(true))
    }

    func testUIntBoundaries() throws {
        assertEncodes(.uint(0), to: [0x00])
        assertEncodes(.uint(127), to: [0x7f])
        assertEncodes(.uint(128), to: [0xcc, 0x80])
        assertEncodes(.uint(255), to: [0xcc, 0xff])
        assertEncodes(.uint(256), to: [0xcd, 0x01, 0x00])
        assertEncodes(.uint(0xffff), to: [0xcd, 0xff, 0xff])
        assertEncodes(.uint(0x1_0000), to: [0xce, 0x00, 0x01, 0x00, 0x00])
        assertEncodes(.uint(0xffff_ffff), to: [0xce, 0xff, 0xff, 0xff, 0xff])
        assertEncodes(.uint(0x1_0000_0000), to: [0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        assertEncodes(.uint(UInt64.max), to: [0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        try assertRoundTrip(.uint(0))
        try assertRoundTrip(.uint(300))
        try assertRoundTrip(.uint(70_000))
        try assertRoundTrip(.uint(UInt64(UInt32.max) + 1))
        try assertRoundTrip(.uint(UInt64.max))
    }

    func testIntBoundaries() throws {
        assertEncodes(.int(-1), to: [0xff])
        assertEncodes(.int(-32), to: [0xe0])
        assertEncodes(.int(-33), to: [0xd0, 0xdf])
        assertEncodes(.int(-128), to: [0xd0, 0x80])
        assertEncodes(.int(-129), to: [0xd1, 0xff, 0x7f])
        assertEncodes(.int(127), to: [0xd0, 0x7f])
        assertEncodes(.int(128), to: [0xd1, 0x00, 0x80])
        assertEncodes(.int(32767), to: [0xd1, 0x7f, 0xff])
        assertEncodes(.int(32768), to: [0xd2, 0x00, 0x00, 0x80, 0x00])
        assertEncodes(.int(Int64(Int32.min)), to: [0xd2, 0x80, 0x00, 0x00, 0x00])
        assertEncodes(.int(Int64(Int32.max)), to: [0xd2, 0x7f, 0xff, 0xff, 0xff])
        assertEncodes(.int(Int64(Int32.max) + 1), to: [0xd3, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00])
        assertEncodes(.int(Int64.min), to: [0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        assertEncodes(.int(Int64.max), to: [0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        try assertRoundTrip(.int(-1))
        try assertRoundTrip(.int(-129))
        try assertRoundTrip(.int(Int64.min))
        try assertRoundTrip(.int(Int64.max))
    }

    func testIntUintIdentityPreserved() throws {
        XCTAssertNotEqual(MsgPackValue.int(5), MsgPackValue.uint(5))
        var decoder = MsgPackDecoder()
        decoder.feed(Data([0x05]))
        XCTAssertEqual(try decoder.nextValue(), .uint(5))
    }

    func testFloat() throws {
        assertEncodes(.float(3.141592653589793), to: [0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18])
        try assertRoundTrip(.float(0))
        try assertRoundTrip(.float(-273.15))
        try assertRoundTrip(.float(1e300))
        var decoder = MsgPackDecoder()
        decoder.feed(Data([0xca, 0x3f, 0xc0, 0x00, 0x00]))
        XCTAssertEqual(try decoder.nextValue(), .float(1.5))
    }

    func testStrings() throws {
        assertEncodes(.string(""), to: [0xa0])
        assertEncodes(.string("hello"), to: [0xa5, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        let string31 = String(repeating: "a", count: 31)
        assertEncodes(.string(string31), to: [0xbf] + Array(repeating: 0x61, count: 31))
        let string32 = String(repeating: "a", count: 32)
        assertEncodes(.string(string32), to: [0xd9, 0x20] + Array(repeating: 0x61, count: 32))
        let string300 = String(repeating: "a", count: 300)
        assertEncodes(.string(string300), to: [0xda, 0x01, 0x2c] + Array(repeating: 0x61, count: 300))
        try assertRoundTrip(.string("Hello, 世界 👋"))
    }

    func testBinary() throws {
        assertEncodes(.binary(Data([1, 2, 3])), to: [0xc4, 0x03, 0x01, 0x02, 0x03])
        let bytes300 = Data((0..<300).map { UInt8($0 % 256) })
        XCTAssertEqual(Data(MsgPackEncoder.encode(.binary(bytes300)).prefix(3)), Data([0xc5, 0x01, 0x2c]))
        try assertRoundTrip(.binary(Data([0, 255, 128])))
        try assertRoundTrip(.binary(bytes300))
    }

    func testArrayAndMap() throws {
        assertEncodes(
            .array([.int(1), .string("two"), .bool(true)]),
            to: [0x93, 0xd0, 0x01, 0xa3, 0x74, 0x77, 0x6f, 0xc3]
        )
        let map16 = MsgPackValue.map(Dictionary(uniqueKeysWithValues: (0..<16).map {
            (MsgPackValue.uint(UInt64($0)), MsgPackValue.bool($0 % 2 == 0))
        }))
        XCTAssertEqual(Data(MsgPackEncoder.encode(map16).prefix(3)), Data([0xde, 0x00, 0x10]))
        try assertRoundTrip(map16)
        let nested = MsgPackValue.array([
            .string("a"),
            .array([.uint(1), .uint(2)]),
            .map([.string("k"): .nil]),
        ])
        try assertRoundTrip(nested)
    }

    func testExt() throws {
        assertEncodes(.ext(type: 0, data: Data([1, 2, 3, 4])), to: [0xd6, 0x00, 0x01, 0x02, 0x03, 0x04])
        assertEncodes(.ext(type: -1, data: Data([1])), to: [0xd4, 0xff, 0x01])
        assertEncodes(
            .ext(type: 5, data: Data(repeating: 0xab, count: 3)),
            to: [0xc7, 0x03, 0x05, 0xab, 0xab, 0xab]
        )
        try assertRoundTrip(.ext(type: 0, data: Data([1, 2, 3, 4])))
        try assertRoundTrip(.ext(type: -128, data: Data(repeating: 0, count: 16)))
    }

    func testNvimHandles() throws {
        let buffer = Buffer(rawValue: 42)
        let value = MsgPackValue(buffer)
        assertEncodes(value, to: [0xd7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2a])
        var decoder = MsgPackDecoder()
        decoder.feed(MsgPackEncoder.encode(value))
        let decoded = try decoder.nextValue()
        XCTAssertEqual(decoded?.handle(as: Buffer.self), buffer)
        XCTAssertNil(decoded?.handle(as: Window.self))
        XCTAssertNil(decoded?.handle(as: Tabpage.self))
        try assertRoundTrip(MsgPackValue(Window(rawValue: 7)))
        try assertRoundTrip(MsgPackValue(Tabpage(rawValue: 3)))
    }

    func testIncrementalDecoding() throws {
        let first = MsgPackEncoder.encode(.array([.uint(1), .uint(2)]))
        let second = MsgPackEncoder.encode(.string("tail"))
        var decoder = MsgPackDecoder()
        for (offset, byte) in first.enumerated() {
            decoder.feed(Data([byte]))
            if offset < first.count - 1 {
                XCTAssertNil(try decoder.nextValue(), "incomplete at byte \(offset)")
            }
        }
        XCTAssertEqual(try decoder.nextValue(), .array([.uint(1), .uint(2)]))
        XCTAssertEqual(decoder.bufferedByteCount, 0)

        decoder.feed(first + second)
        XCTAssertEqual(try decoder.nextValue(), .array([.uint(1), .uint(2)]))
        XCTAssertEqual(try decoder.nextValue(), .string("tail"))
        XCTAssertEqual(decoder.bufferedByteCount, 0)

        decoder.feed(Data([0xda, 0x00]))
        XCTAssertNil(try decoder.nextValue())
        XCTAssertEqual(decoder.bufferedByteCount, 2)
    }

    func testInvalidMarkerThrows() {
        var decoder = MsgPackDecoder()
        decoder.feed(Data([0xc1]))
        XCTAssertThrowsError(try decoder.nextValue()) { error in
            guard case MsgPackError.invalidMarker(let marker) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(marker, 0xc1)
        }
    }

    func testInvalidUTF8Throws() {
        var decoder = MsgPackDecoder()
        decoder.feed(Data([0xa1, 0xff]))
        XCTAssertThrowsError(try decoder.nextValue()) { error in
            guard case MsgPackError.invalidUTF8 = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    private func assertRoundTrip(
        _ value: MsgPackValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var decoder = MsgPackDecoder()
        decoder.feed(MsgPackEncoder.encode(value))
        XCTAssertEqual(try decoder.nextValue(), value, "round-trip failed for \(value)", file: file, line: line)
        XCTAssertEqual(decoder.bufferedByteCount, 0, "decoder not drained", file: file, line: line)
    }

    private func assertEncodes(
        _ value: MsgPackValue,
        to bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Array(MsgPackEncoder.encode(value)), bytes, "wrong encoding for \(value)", file: file, line: line)
    }
}
