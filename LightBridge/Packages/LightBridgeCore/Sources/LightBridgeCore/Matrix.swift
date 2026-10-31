import Foundation

/// M7 — Deneysel özel optik matris (QR yerine). Düzen (N×N hücre):
///  - dış halka: siyah çerçeve (konumlandırma),
///  - satır 1: kalibrasyon (seviyeler tekrar tekrar; alıcı eşikleri buradan öğrenir),
///  - satır 2..N-2, sütun 1..N-2: veri. Akış = [u16 uzunluk][LBOP paketi][sıfır dolgu], MSB-önce.
///  - 1 bit/hücre (siyah/beyaz) ya da 2 bit/hücre (4 gri ton, Gray kodlu).
/// Çerçeve etrafında 2 hücre beyaz sessiz alan vardır. Perspektif/dönme düzeltmesi YOKTUR:
/// telefon ekrana paralel tutulmalı (bu bir araştırma prototipidir, QR'ın yerini tutmaz).
public struct MatrixSpec: Equatable, Sendable {
    public let n: Int
    public let bitsPerCell: Int
    public init(n: Int, bitsPerCell: Int) { self.n = n; self.bitsPerCell = bitsPerCell }

    public static let mono96 = MatrixSpec(n: 96, bitsPerCell: 1)
    public static let gray64 = MatrixSpec(n: 64, bitsPerCell: 2)
    public static let presets: [MatrixSpec] = [.mono96, .gray64]

    public var levels: Int { 1 << bitsPerCell }
    public var dataCells: Int { (n - 3) * (n - 2) }
    public var capacityBytes: Int { dataCells * bitsPerCell / 8 }
    public var maxPacketBytes: Int { capacityBytes - 2 }
    public var maxSymbolBytes: Int { min(LBOP.maxPayload, maxPacketBytes - LBOP.headerSize) }
}

public enum LBMatrix {
    public static let marginCells = 2

    static func toGray(_ v: Int) -> Int { v ^ (v >> 1) }
    static func fromGray(_ g: Int) -> Int { var v = g; var s = g >> 1; while s != 0 { v ^= s; s >>= 1 }; return v }

    /// n×n parlaklık ızgarası (çerçeve + kalibrasyon + veri).
    public static func cellLuma(packet: Data, spec: MatrixSpec) -> [UInt8]? {
        guard packet.count <= spec.maxPacketBytes else { return nil }
        let n = spec.n, L = spec.levels, bpc = spec.bitsPerCell
        var grid = [UInt8](repeating: 255, count: n * n)
        for i in 0..<n { grid[i] = 0; grid[(n - 1) * n + i] = 0; grid[i * n] = 0; grid[i * n + n - 1] = 0 }
        for c in 1...(n - 2) { grid[n + c] = UInt8((c - 1) % L * 255 / (L - 1)) }

        var stream = [UInt8]()
        stream.append(UInt8(packet.count >> 8)); stream.append(UInt8(packet.count & 0xFF))
        stream.append(contentsOf: packet)
        stream.append(contentsOf: [UInt8](repeating: 0, count: max(0, spec.capacityBytes - stream.count)))

        var bitPos = 0
        func nextBits() -> Int {
            var v = 0
            for _ in 0..<bpc {
                let byte = bitPos / 8 < stream.count ? stream[bitPos / 8] : 0
                v = (v << 1) | Int((byte >> UInt8(7 - bitPos % 8)) & 1)
                bitPos += 1
            }
            return v
        }
        for r in 2...(n - 2) { for c in 1...(n - 2) {
            grid[r * n + c] = UInt8(toGray(nextBits()) * 255 / (L - 1))
        } }
        return grid
    }

    /// Ekranda gösterilecek tam görüntü (sessiz alan dahil). Kare, 8 bit gri.
    public static func renderLuma(packet: Data, spec: MatrixSpec, cellPx: Int) -> (pixels: [UInt8], side: Int)? {
        guard let cells = cellLuma(packet: packet, spec: spec) else { return nil }
        let total = spec.n + 2 * marginCells
        let side = total * cellPx
        var px = [UInt8](repeating: 255, count: side * side)
        for r in 0..<spec.n { for c in 0..<spec.n {
            let v = cells[r * spec.n + c]
            if v == 255 { continue }
            let y0 = (r + marginCells) * cellPx, x0 = (c + marginCells) * cellPx
            for y in y0..<(y0 + cellPx) { for x in x0..<(x0 + cellPx) { px[y * side + x] = v } }
        } }
        return (px, side)
    }

    // MARK: Çözme
    private static func otsu(_ samples: [UInt8]) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for s in samples { hist[Int(s)] += 1 }
        let total = samples.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var wB = 0, sumB = 0.0, best = 0.0, thr = 128
        for t in 0..<256 {
            wB += hist[t]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let v = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if v > best { best = v; thr = t }
        }
        return thr
    }

    /// Kamera karesinin (kırpılmış) parlaklık düzleminden LBOP paket baytlarını çıkarır.
    /// Dönen veri "LBOP" ile başlıyorsa geçerli aday sayılır; CRC kontrolünü çağıran yapar.
    public static func decode(luma: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                              specs: [MatrixSpec]) -> Data? {
        guard width > 64, height > 64 else { return nil }
        @inline(__always) func px(_ x: Int, _ y: Int) -> Int { Int(luma[y * rowBytes + x]) }

        // 1) eşik
        let step = max(2, min(width, height) / 200)
        var samples = [UInt8]()
        var y = 0
        while y < height { var x = 0; while x < width { samples.append(luma[y * rowBytes + x]); x += step }; y += step }
        let thr = max(16, otsu(samples))
        let (mn, mx) = (samples.min() ?? 0, samples.max() ?? 255)
        guard mx - mn > 80 else { return nil }

        // 2) kaba sınırlar: koyu piksel yoğunluğu yüksek satır/sütunlar
        let sw = (width + step - 1) / step, sh = (height + step - 1) / step
        var colDark = [Int](repeating: 0, count: sw), rowDark = [Int](repeating: 0, count: sh)
        for sy in 0..<sh { for sx in 0..<sw where px(min(sx * step, width - 1), min(sy * step, height - 1)) < thr {
            colDark[sx] += 1; rowDark[sy] += 1
        } }
        let rowMin = max(3, sw / 12), colMin = max(3, sh / 12)
        guard let top = rowDark.firstIndex(where: { $0 >= rowMin }),
              let bottom = rowDark.lastIndex(where: { $0 >= rowMin }),
              let left = colDark.firstIndex(where: { $0 >= colMin }),
              let right = colDark.lastIndex(where: { $0 >= colMin }),
              bottom > top, right > left else { return nil }

        // 3) piksel hassasiyetinde kenar inceltme: çerçeve çizgisi boydan boya koyu
        //    wantMin: true → penceredeki en küçük koyu sütun/satır, false → en büyük
        func refine(vertical: Bool, approx: Int, from: Int, to: Int, wantMin: Bool) -> Int {
            var found: Int?
            let limit = vertical ? width : height
            for d in -(step * 2)...(step * 2) {
                let p = approx + d
                guard p >= 0, p < limit else { continue }
                var dark = 0, tot = 0
                var q = from
                while q < to {
                    tot += 1
                    if (vertical ? px(p, q) : px(q, p)) < thr { dark += 1 }
                    q += 2
                }
                if tot > 0, Double(dark) / Double(tot) > 0.8 {
                    if let f = found { found = wantMin ? min(f, p) : max(f, p) } else { found = p }
                }
            }
            return found ?? approx
        }
        let ly0 = top * step, ly1 = min(bottom * step, height - 1)
        let lx0 = left * step, lx1 = min(right * step, width - 1)
        let yIn0 = ly0 + (ly1 - ly0) / 10, yIn1 = ly1 - (ly1 - ly0) / 10
        let xIn0 = lx0 + (lx1 - lx0) / 10, xIn1 = lx1 - (lx1 - lx0) / 10
        let x0 = refine(vertical: true, approx: lx0, from: yIn0, to: yIn1, wantMin: true)
        let x1 = refine(vertical: true, approx: lx1, from: yIn0, to: yIn1, wantMin: false)
        let y0 = refine(vertical: false, approx: ly0, from: xIn0, to: xIn1, wantMin: true)
        let y1 = refine(vertical: false, approx: ly1, from: xIn0, to: xIn1, wantMin: false)
        guard x1 - x0 > 64, y1 - y0 > 64 else { return nil }

        // 4) her şablonu dene
        for spec in specs {
            let n = spec.n, L = spec.levels, bpc = spec.bitsPerCell
            let cw = Double(x1 - x0 + 1) / Double(n), ch = Double(y1 - y0 + 1) / Double(n)
            guard cw >= 2, ch >= 2 else { continue }

            func sample(_ r: Int, _ c: Int) -> Double {
                let cx = Double(x0) + (Double(c) + 0.5) * cw, cy = Double(y0) + (Double(r) + 0.5) * ch
                var acc = 0.0, cnt = 0.0
                for oy in [-0.2, 0.0, 0.2] { for ox in [-0.2, 0.0, 0.2] {
                    let xx = Int((cx + ox * cw).rounded()), yy = Int((cy + oy * ch).rounded())
                    if xx >= 0, xx < width, yy >= 0, yy < height { acc += Double(px(xx, yy)); cnt += 1 }
                } }
                return cnt > 0 ? acc / cnt : 0
            }

            var sums = [Double](repeating: 0, count: L), cnts = [Double](repeating: 0, count: L)
            for c in 1...(n - 2) { let l = (c - 1) % L; sums[l] += sample(1, c); cnts[l] += 1 }
            let means = (0..<L).map { sums[$0] / max(1, cnts[$0]) }
            guard means[L - 1] - means[0] > 60, zip(means, means.dropFirst()).allSatisfy({ $0 < $1 }) else { continue }

            var bytes = [UInt8](repeating: 0, count: spec.capacityBytes)
            var bitPos = 0
            for r in 2...(n - 2) { for c in 1...(n - 2) {
                let s = sample(r, c)
                var best = 0, bd = Double.infinity
                for l in 0..<L { let d = abs(s - means[l]); if d < bd { bd = d; best = l } }
                let v = fromGray(best)
                for k in stride(from: bpc - 1, through: 0, by: -1) {
                    if bitPos / 8 < bytes.count, (v >> k) & 1 == 1 { bytes[bitPos / 8] |= UInt8(0x80 >> (bitPos % 8)) }
                    bitPos += 1
                }
            } }
            let len = Int(bytes[0]) << 8 | Int(bytes[1])
            guard len >= LBOP.headerSize, len <= spec.maxPacketBytes, 2 + len <= bytes.count else { continue }
            let pkt = Data(bytes[2..<(2 + len)])
            if pkt.prefix(4) == Data(LBOP.magic) { return pkt }
        }
        return nil
    }
}
