import Foundation
import CryptoKit
import Security

/// Simplex gönderici. Çıkış akışı:
///  1) tüm sistematik semboller (dosya sırayla),
///  2) sonsuz onarım turu: her blok için sırayla yeni seed'li onarım sembolleri.
/// Manifest her `manifestInterval` pakette bir araya girer. Alıcı geri bildirim vermez.
public final class LBOPSender {
    public let manifest: FileManifest
    public let sessionID: Data
    private let payload: Data          // şifreliyse blob
    private var emitted: UInt64 = 0
    private var tick: UInt64 = 0
    public var manifestInterval: UInt64 = 24

    public init(fileData: Data, fileName: String, symbolBytes: Int = 400,
                blockSymbols: Int = 128, passphrase: String? = nil) throws {
        precondition(symbolBytes > 0 && symbolBytes <= LBOP.maxPayload)
        precondition(blockSymbols > 0 && blockSymbols <= 4096)
        var sid = Data(count: 8)
        _ = sid.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        self.sessionID = sid

        var body = fileData
        var name = fileName
        var salt = Data()
        var enc = false
        if let pass = passphrase, !pass.isEmpty {
            let s = try LBCrypto.seal(file: fileData, name: fileName, passphrase: pass)
            body = s.blob; salt = s.salt; enc = true; name = "sifreli.lbx"
        }
        self.payload = Data(body)
        let count = max(1, (body.count + symbolBytes - 1) / symbolBytes)
        self.manifest = FileManifest(
            fileName: name, originalLength: UInt64(body.count),
            sha256: Data(SHA256.hash(data: body)),
            symbolBytes: UInt16(symbolBytes), symbolCount: UInt32(count),
            blockSymbols: UInt16(blockSymbols), encrypted: enc, salt: salt)
    }

    public var symbolCount: Int { Int(manifest.symbolCount) }
    /// Sistematik tur ilerlemesi (0...symbolCount)
    public var currentSymbol: Int { Int(min(emitted, UInt64(manifest.symbolCount))) }
    public var inRepairPhase: Bool { emitted >= UInt64(manifest.symbolCount) }

    private func symbol(_ i: Int) -> [UInt8] {
        let sb = Int(manifest.symbolBytes)
        var out = [UInt8](repeating: 0, count: sb)
        let start = i * sb
        if start < payload.count {
            let end = min(start + sb, payload.count)
            payload.copyBytes(to: &out, from: start..<end)
        }
        return out
    }

    public func nextPacket() -> LBOPPacket {
        defer { tick += 1 }
        if tick % manifestInterval == 0 {
            return LBOPPacket(type: .manifest, sessionID: sessionID, sequence: 0, payload: manifest.encode())
        }
        let sc = UInt64(manifest.symbolCount)
        let K = UInt64(manifest.blockSymbols)
        defer { emitted += 1 }
        if emitted < sc {
            let i = Int(emitted)
            return LBOPPacket(type: .data, sessionID: sessionID,
                              blockIndex: UInt32(emitted / K), sequence: UInt32(emitted % K),
                              payload: Data(symbol(i)))
        }
        let m = emitted - sc
        let nb = UInt64(manifest.blockCount)
        let block = Int(m % nb)
        let seed = UInt32(truncatingIfNeeded: m / nb)
        let kb = manifest.blockSize(block)
        let bits = Fountain.repairBits(k: kb, block: UInt32(block), seed: seed)
        var acc = [UInt8](repeating: 0, count: Int(manifest.symbolBytes))
        for j in 0..<kb where Fountain.isSet(bits, j) {
            let s = symbol(block * Int(K) + j)
            for t in 0..<acc.count { acc[t] ^= s[t] }
        }
        return LBOPPacket(type: .repair, sessionID: sessionID, blockIndex: UInt32(block), sequence: seed, payload: Data(acc))
    }

    public func nextQRString() -> String { Base45.encode(nextPacket().encode()) }
}
