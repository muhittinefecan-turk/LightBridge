import Foundation

public enum ManifestError: Error { case malformed, nameTooLong }

/// İkili manifest:
/// [u64 aktarılan uzunluk][32 SHA-256][u16 sembol baytı][u32 toplam sembol][u16 blok sembol sayısı K]
/// [u8 bayrak (bit0=şifreli)][şifreliyse 16 bayt salt][u8 ad uzunluğu][ad UTF-8]
/// "Aktarılan" = şifreliyse şifreli blob, değilse dosyanın kendisi; SHA-256 de bunun üstündendir.
public struct FileManifest: Equatable {
    public var fileName: String
    public var originalLength: UInt64
    public var sha256: Data
    public var symbolBytes: UInt16
    public var symbolCount: UInt32
    public var blockSymbols: UInt16
    public var encrypted: Bool
    public var salt: Data

    public init(fileName: String, originalLength: UInt64, sha256: Data, symbolBytes: UInt16,
                symbolCount: UInt32, blockSymbols: UInt16 = 128, encrypted: Bool = false, salt: Data = Data()) {
        self.fileName = Self.sanitize(fileName)
        self.originalLength = originalLength; self.sha256 = sha256
        self.symbolBytes = symbolBytes; self.symbolCount = symbolCount
        self.blockSymbols = blockSymbols; self.encrypted = encrypted; self.salt = salt
    }

    public var blockCount: Int { (Int(symbolCount) + Int(blockSymbols) - 1) / Int(blockSymbols) }
    public func blockSize(_ b: Int) -> Int { min(Int(blockSymbols), Int(symbolCount) - b * Int(blockSymbols)) }

    public static func sanitize(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        n = String(n.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while n.hasPrefix(".") { n.removeFirst() }
        var bytes = Array(n.utf8)
        if bytes.count > 120 { bytes = Array(bytes.prefix(120)) }
        let cut = String(decoding: bytes, as: UTF8.self)
        return cut.isEmpty ? "lightbridge-dosya" : cut
    }

    public func encode() -> Data {
        var d = Data()
        d.appendBE(originalLength)
        d.append(sha256)
        d.appendBE(symbolBytes)
        d.appendBE(symbolCount)
        d.appendBE(blockSymbols)
        d.append(encrypted ? 1 : 0)
        if encrypted { d.append(salt) }
        let name = Data(fileName.utf8)
        d.append(UInt8(name.count))
        d.append(name)
        return d
    }

    public static func decode(_ data: Data) throws -> FileManifest {
        let b = [UInt8](data)
        guard b.count >= 8 + 32 + 2 + 4 + 2 + 1 + 1 else { throw ManifestError.malformed }
        let len = b.beU64(at: 0)
        let hash = Data(b[8..<40])
        let sb = UInt16(b[40]) << 8 | UInt16(b[41])
        let sc = b.beU32(at: 42)
        let ks = UInt16(b[46]) << 8 | UInt16(b[47])
        let flags = b[48]
        var i = 49
        var salt = Data()
        let enc = flags & 1 == 1
        if enc {
            guard b.count >= i + 16 + 1 else { throw ManifestError.malformed }
            salt = Data(b[i..<(i + 16)]); i += 16
        }
        guard b.count > i else { throw ManifestError.malformed }
        let nl = Int(b[i]); i += 1
        guard b.count == i + nl, sb > 0, ks > 0, Int(sb) <= LBOP.maxPayload else { throw ManifestError.malformed }
        let expected = max(1, (len + UInt64(sb) - 1) / UInt64(sb))
        guard UInt64(sc) == expected else { throw ManifestError.malformed }
        let name = String(decoding: b[i..<(i + nl)], as: UTF8.self)
        return FileManifest(fileName: name, originalLength: len, sha256: hash, symbolBytes: sb,
                            symbolCount: sc, blockSymbols: ks, encrypted: enc, salt: salt)
    }
}
