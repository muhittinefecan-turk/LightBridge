import Foundation

/// RFC 9285 Base45. QR alfasayısal modunun 45 karakterlik alfabesiyle birebir uyumlu.
public enum Base45 {
    public enum DecodeError: Error { case invalidCharacter, invalidLength, overflow }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)
    private static let reverse: [UInt8: Int] = {
        var m = [UInt8: Int]()
        for (i, c) in alphabet.enumerated() { m[c] = i }
        return m
    }()

    public static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 3 / 2 + 3)
        var i = 0
        while i + 1 < bytes.count {
            let n = Int(bytes[i]) * 256 + Int(bytes[i + 1])
            out.append(alphabet[n % 45])
            out.append(alphabet[(n / 45) % 45])
            out.append(alphabet[n / (45 * 45)])
            i += 2
        }
        if i < bytes.count {
            let n = Int(bytes[i])
            out.append(alphabet[n % 45])
            out.append(alphabet[n / 45])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) throws -> Data {
        let chars = Array(string.utf8)
        var vals = [Int]()
        vals.reserveCapacity(chars.count)
        for c in chars {
            guard let v = reverse[c] else { throw DecodeError.invalidCharacter }
            vals.append(v)
        }
        var out = [UInt8]()
        out.reserveCapacity(vals.count * 2 / 3 + 1)
        var i = 0
        while i + 2 < vals.count {
            let n = vals[i] + vals[i + 1] * 45 + vals[i + 2] * 45 * 45
            guard n <= 0xFFFF else { throw DecodeError.overflow }
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
            i += 3
        }
        let rest = vals.count - i
        if rest == 2 {
            let n = vals[i] + vals[i + 1] * 45
            guard n <= 0xFF else { throw DecodeError.overflow }
            out.append(UInt8(n))
        } else if rest != 0 {
            throw DecodeError.invalidLength
        }
        return Data(out)
    }
}
