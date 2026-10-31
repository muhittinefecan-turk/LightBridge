import Foundation

/// GF(2) üzerinde "fountain" tipi onarım kodu (rastgele doğrusal kod).
/// - Sistematik sembol: tek bitlik denklem (kaynak sembolün kendisi).
/// - Onarım sembolü: seed'den türetilen rastgele alt kümenin XOR'u. Seed + blok + k her iki uçta aynı denklemi üretir.
/// Blok başına k sembol için ortalama ~k+2 bağımsız denklem yeterlidir.
public enum Fountain {
    struct SplitMix64 {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    public static func words(for k: Int) -> Int { (k + 63) / 64 }

    public static func systematicBits(k: Int, index: Int) -> [UInt64] {
        var b = [UInt64](repeating: 0, count: words(for: k))
        b[index / 64] |= (UInt64(1) << UInt64(index % 64))
        return b
    }

    public static func repairBits(k: Int, block: UInt32, seed: UInt32) -> [UInt64] {
        var rng = SplitMix64(s: ((UInt64(block) << 32) | UInt64(seed)) ^ 0xA5A5_5A5A_1234_ABCD)
        let w = words(for: k)
        var bits = [UInt64](repeating: 0, count: w)
        for i in 0..<w { bits[i] = rng.next() }
        let rem = k % 64
        if rem != 0 { bits[w - 1] &= (UInt64(1) << UInt64(rem)) - 1 }
        if bits.allSatisfy({ $0 == 0 }) { bits[0] = 1 }
        return bits
    }

    public static func isSet(_ bits: [UInt64], _ i: Int) -> Bool {
        (bits[i / 64] >> UInt64(i % 64)) & 1 == 1
    }
}

/// Tek bir bloğun çözücüsü: artımlı Gauss eleme.
final class BlockDecoder {
    let k: Int
    let symbolBytes: Int
    private let words: Int
    private var pivotBits: [[UInt64]?]
    private var pivotData: [[UInt8]?]
    private(set) var rank = 0
    var isSolved: Bool { rank == k }

    init(k: Int, symbolBytes: Int) {
        self.k = k; self.symbolBytes = symbolBytes
        self.words = Fountain.words(for: k)
        self.pivotBits = Array(repeating: nil, count: k)
        self.pivotData = Array(repeating: nil, count: k)
    }

    private func lowestBit(_ b: [UInt64]) -> Int? {
        for i in 0..<b.count where b[i] != 0 { return i * 64 + b[i].trailingZeroBitCount }
        return nil
    }

    /// Yeni bilgi getirdiyse true.
    @discardableResult
    func add(bits: [UInt64], data: Data) -> Bool {
        guard !isSolved, data.count == symbolBytes else { return false }
        var b = bits
        var d = [UInt8](data)
        while true {
            guard let p = lowestBit(b), p < k else { return false }
            if let pb = pivotBits[p], let pd = pivotData[p] {
                for i in 0..<words { b[i] ^= pb[i] }
                for i in 0..<symbolBytes { d[i] ^= pd[i] }
            } else {
                pivotBits[p] = b; pivotData[p] = d; rank += 1
                return true
            }
        }
    }

    /// rank == k iken kaynak sembolleri döndürür.
    func symbols() -> [Data]? {
        guard isSolved else { return nil }
        var rows = pivotData.map { $0! }
        for p in stride(from: k - 1, through: 0, by: -1) {
            let bits = pivotBits[p]!
            if p + 1 < k {
                for q in (p + 1)..<k where Fountain.isSet(bits, q) {
                    let rq = rows[q]
                    for i in 0..<symbolBytes { rows[p][i] ^= rq[i] }
                }
            }
        }
        return rows.map { Data($0) }
    }
}
