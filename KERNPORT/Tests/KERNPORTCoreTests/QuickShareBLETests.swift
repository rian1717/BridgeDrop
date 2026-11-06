import XCTest
@testable import KERNPORTCore

final class QuickShareBLETests: XCTestCase {

    func testServiceNameCarriesTheFourCharacterId() {
        let raw = Data([0x23, 0x52, 0x59, 0x5A, 0x45, 0xFC, 0x9F, 0x5E, 0x00, 0x00])
        let serviceName = raw.urlSafeBase64EncodedString()
        XCTAssertEqual(QuickShareBLE.endpointID(fromServiceName: serviceName), "RYZE")
    }

    func testFastAdvertisementCarriesAPlainName() {
        // The protocol's example: endpoint ABCD, name Pixel.
        let bytes: [UInt8] = [
            0x4A, 0x0B,
            0x23, 0x41, 0x42, 0x43, 0x44, 0x05, 0x50, 0x69, 0x78, 0x65, 0x6C,
            0x12, 0x34,
        ]
        let sighting = QuickShareBLE.parse(serviceData: Data(bytes))
        XCTAssertEqual(sighting?.endpointID, "ABCD")
        XCTAssertEqual(sighting?.name, "Pixel")
    }

    func testHiddenWiFiRecordStillYieldsTheBluetoothName() {
        var hidden = Data([0x12])
        hidden.append(Data(repeating: 0, count: 16))
        var record = Data([0x23, 0x41, 0x42, 0x43, 0x44, UInt8(hidden.count)])
        record.append(hidden)
        var packet = Data([0x4A, UInt8(record.count)])
        packet.append(record)
        let name = Array("RYZE S22".utf8)
        packet.append(UInt8(name.count))
        packet.append(contentsOf: name)

        let sighting = QuickShareBLE.parse(serviceData: packet)
        XCTAssertEqual(sighting?.endpointID, "ABCD")
        XCTAssertEqual(sighting?.name, "RYZE S22")
    }

    func testPlaceholderAdvertisementIsIgnored() {
        let placeholder = Data("QCAAABACAAADAAAAAAAAAAA".utf8)
        XCTAssertNil(QuickShareBLE.parse(serviceData: placeholder))
    }
}
