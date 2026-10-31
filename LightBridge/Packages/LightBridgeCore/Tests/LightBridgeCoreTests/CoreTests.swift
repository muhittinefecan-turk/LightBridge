import XCTest
import CryptoKit
@testable import LightBridgeCore

private func randomData(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

final class CoreTests: XCTestCase {
    func testCRC32CVector() { XCTAssertEqual(CRC32C.checksum(Data("123456789".utf8)), 0xE3069283) }

    func testBase45RFCVectors() throws {
        XCTAssertEqual(Base45.encode(Data("AB".utf8)), "BB8")
        XCTAssertEqual(Base45.encode(Data("Hello!!".utf8)), "%69 VD92EX0")
        XCTAssertEqual(Base45.encode(Data("base-45".utf8)), "UJCLQE7W581")
        XCTAssertEqual(Base45.encode(Data("ietf!".utf8)), "QED8WEX0")
        XCTAssertEqual(try Base45.decode("QED8WEX0"), Data("ietf!".utf8))
    }

    func testPacketRoundTripAndCorruption() throws {
        let p = LBOPPacket(type: .data, sessionID: Data(repeating: 7, count: 8), sequence: 5, payload: Data([1, 2, 3]))
        let e = p.encode()
        XCTAssertEqual(e.count, 28 + 3)
        XCTAssertEqual(try LBOPPacket.decode(e), p)
        var bad = e; bad[30] ^= 0xFF
        XCTAssertThrowsError(try LBOPPacket.decode(bad))
    }

    func testManifestRoundTrip() throws {
        let m = FileManifest(fileName: "a.bin", originalLength: 1000, sha256: Data(repeating: 1, count: 32),
                             symbolBytes: 100, symbolCount: 10, blockSymbols: 4, encrypted: true, salt: Data(repeating: 9, count: 16))
        XCTAssertEqual(try FileManifest.decode(m.encode()), m)
    }

    /// Kayıp + yinelenme + karışık sıra: %40 kayıpla bile onarım sembolleriyle tamamlanmalı.
    func testTransferWithHeavyLossUsesRepair() throws {
        let file = randomData(10 * 1024)
        let sender = try LBOPSender(fileData: file, fileName: "test.bin", symbolBytes: 400, blockSymbols: 16)
        let rx = LBOPReceiver()
        var n = 0
        while rx.result == nil && n < 4000 {
            let s = sender.nextQRString()
            if Int.random(in: 0..<10) >= 4 { rx.ingest(qrString: s); if Bool.random() { rx.ingest(qrString: s) } }
            n += 1
        }
        let r = try XCTUnwrap(rx.result)
        XCTAssertEqual(r.data, file); XCTAssertEqual(r.name, "test.bin")
    }

    func testMultiBlockLargeFile() throws {
        let file = randomData(300_000)
        let sender = try LBOPSender(fileData: file, fileName: "big.bin", symbolBytes: 900, blockSymbols: 128)
        let rx = LBOPReceiver()
        var n = 0
        while rx.result == nil && n < 20000 {
            let p = sender.nextPacket().encode()
            if Int.random(in: 0..<10) >= 2 { rx.ingest(packet: p) }
            n += 1
        }
        XCTAssertEqual(rx.result?.data, file)
    }

    func testLateJoinerStillCompletes() throws {
        let file = randomData(5000)
        let sender = try LBOPSender(fileData: file, fileName: "late.bin", symbolBytes: 200, blockSymbols: 8)
        for _ in 0..<40 { _ = sender.nextPacket() }       // alıcı ilk 40 paketi kaçırdı
        let rx = LBOPReceiver()
        var n = 0
        while rx.result == nil && n < 3000 { rx.ingest(packet: sender.nextPacket().encode()); n += 1 }
        XCTAssertEqual(rx.result?.data, file)
    }

    func testResumeFromSnapshot() throws {
        let file = randomData(8000)
        let sender = try LBOPSender(fileData: file, fileName: "r.bin", symbolBytes: 200, blockSymbols: 16)
        let rx1 = LBOPReceiver()
        for _ in 0..<20 { rx1.ingest(packet: sender.nextPacket().encode()) }
        let state = rx1.exportState()
        let rx2 = LBOPReceiver(); rx2.restore(state)
        XCTAssertEqual(rx2.status.received, rx1.status.received)
        var n = 0
        while rx2.result == nil && n < 3000 { rx2.ingest(packet: sender.nextPacket().encode()); n += 1 }
        XCTAssertEqual(rx2.result?.data, file)
    }

    func testEncryptedTransfer() throws {
        let file = randomData(3000)
        let sender = try LBOPSender(fileData: file, fileName: "gizli.pdf", symbolBytes: 300, blockSymbols: 8, passphrase: "uzun-bir-parola")
        let rx = LBOPReceiver()
        var n = 0
        while rx.status.state != .needsPassphrase && n < 3000 { rx.ingest(packet: sender.nextPacket().encode()); n += 1 }
        XCTAssertEqual(rx.status.state, .needsPassphrase)
        XCTAssertFalse(rx.unlock(passphrase: "yanlis"))
        XCTAssertTrue(rx.unlock(passphrase: "uzun-bir-parola"))
        XCTAssertEqual(rx.result?.data, file); XCTAssertEqual(rx.result?.name, "gizli.pdf")
    }

    func testCorruptPacketIgnoredAndSessionSwitch() throws {
        let a = try LBOPSender(fileData: randomData(500), fileName: "a", symbolBytes: 100)
        let b = try LBOPSender(fileData: randomData(500), fileName: "b", symbolBytes: 100)
        let rx = LBOPReceiver()
        rx.ingest(packet: a.nextPacket().encode())              // a manifest
        var junk = b.nextPacket().encode(); junk[40] ^= 1
        rx.ingest(packet: junk)                                  // bozuk, yok sayılır
        XCTAssertEqual(rx.sessionID, a.sessionID)
        rx.ingest(packet: b.nextPacket().encode())               // b'nin sonraki paketi manifest değil → yok say
        XCTAssertEqual(rx.sessionID, a.sessionID)
    }

    func testFileNameSanitize() {
        XCTAssertFalse(FileManifest.sanitize("../../etc/passwd").contains("/"))
        XCTAssertFalse(FileManifest.sanitize("../x").hasPrefix("."))
    }

    // MARK: Matris
    private func roundTrip(spec: MatrixSpec, noise: Int, contrast: Double) throws {
        let payload = randomData(spec.maxSymbolBytes)
        let pkt = LBOPPacket(type: .data, sessionID: Data(repeating: 3, count: 8), sequence: 1, payload: payload).encode()
        var (px, side) = try XCTUnwrap(LBMatrix.renderLuma(packet: pkt, spec: spec, cellPx: 8))
        for i in 0..<px.count {
            var v = Double(px[i]) * contrast + Double.random(in: -Double(noise)...Double(noise))
            v = max(0, min(255, v)); px[i] = UInt8(v)
        }
        let out = px.withUnsafeBufferPointer {
            LBMatrix.decode(luma: $0.baseAddress!, width: side, height: side, rowBytes: side, specs: MatrixSpec.presets)
        }
        XCTAssertEqual(out, pkt)
        XCTAssertNoThrow(try LBOPPacket.decode(try XCTUnwrap(out)))
    }
    func testMatrixMono() throws { try roundTrip(spec: .mono96, noise: 0, contrast: 1.0) }
    func testMatrixMonoNoisy() throws { try roundTrip(spec: .mono96, noise: 25, contrast: 0.75) }
    func testMatrixGray() throws { try roundTrip(spec: .gray64, noise: 0, contrast: 1.0) }
}
