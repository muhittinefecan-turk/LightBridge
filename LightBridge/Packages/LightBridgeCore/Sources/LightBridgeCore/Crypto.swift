import Foundation
import CryptoKit
import CommonCrypto
import Security

/// İsteğe bağlı PIN/parola şifreleme: PBKDF2-HMAC-SHA256 (200k tur) + AES-256-GCM.
/// Not: Optik kanal, görüş alanındaki herkesin paketleri kaydedebileceği bir kanaldır; kısa PIN'ler
/// çevrimdışı denemeye açıktır. Uzun parola önerilir. (Tehdit modeli: Docs/PROTOCOL.md)
public enum LBCrypto {
    public enum CryptoError: Error { case kdfFailed, wrongPassphrase, malformed }

    static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let st = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                                      saltBytes, saltBytes.count,
                                      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                      &key, key.count)
        guard st == kCCSuccess else { throw CryptoError.kdfFailed }
        return SymmetricKey(data: Data(key))
    }

    /// plain = [u8 ad uzunluğu][ad][dosya]
    public static func seal(file: Data, name: String, passphrase: String) throws -> (blob: Data, salt: Data) {
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw CryptoError.kdfFailed }
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let nameBytes = Data(FileManifest.sanitize(name).utf8.prefix(120))
        var plain = Data([UInt8(nameBytes.count)])
        plain.append(nameBytes); plain.append(file)
        let box = try AES.GCM.seal(plain, using: key)
        guard let combined = box.combined else { throw CryptoError.malformed }
        return (combined, salt)
    }

    public static func open(blob: Data, salt: Data, passphrase: String) throws -> (name: String, data: Data) {
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let plain: Data
        do { plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: key) }
        catch { throw CryptoError.wrongPassphrase }
        let b = [UInt8](plain)
        guard let nl = b.first.map(Int.init), b.count >= 1 + nl else { throw CryptoError.malformed }
        let name = FileManifest.sanitize(String(decoding: b[1..<(1 + nl)], as: UTF8.self))
        return (name, Data(b[(1 + nl)...]))
    }
}
