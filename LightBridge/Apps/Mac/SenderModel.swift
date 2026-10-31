import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import LightBridgeCore

enum SendMode: String, CaseIterable, Identifiable {
    case qr = "QR", matrixMono = "Matris mono", matrixGray = "Matris 4 ton"
    var id: String { rawValue }
    var spec: MatrixSpec? {
        switch self { case .qr: return nil; case .matrixMono: return .mono96; case .matrixGray: return .gray64 }
    }
}

struct LabProfile { let name: String; let mode: SendMode; let sb: Int; let fps: Double; let tiles: Int }

@MainActor
final class SenderModel: ObservableObject {
    @Published var image: NSImage?
    @Published var fileName = ""
    @Published var fileSize = 0
    @Published var isSending = false
    @Published var fps: Double = 6
    @Published var symbolBytes: Double = 250
    @Published var mode: SendMode = .qr
    @Published var tiles = 1
    @Published var passphrase = ""
    @Published var errorText: String?
    @Published var currentSymbol = 0
    @Published var symbolCount = 0
    @Published var inRepair = false
    @Published var elapsed: TimeInterval = 0
    @Published var isLab = false
    @Published var labStatus = ""

    let labSeconds: Double = 25
    static let labProfiles: [LabProfile] = [
        .init(name: "qr-P200-F8", mode: .qr, sb: 200, fps: 8, tiles: 1),
        .init(name: "qr-P300-F10", mode: .qr, sb: 300, fps: 10, tiles: 1),
        .init(name: "qr-P400-F12", mode: .qr, sb: 400, fps: 12, tiles: 1),
        .init(name: "qr-P400-F15", mode: .qr, sb: 400, fps: 15, tiles: 1),
        .init(name: "qr-P600-F10", mode: .qr, sb: 600, fps: 10, tiles: 1),
        .init(name: "qr-P200-F10-2x2", mode: .qr, sb: 200, fps: 10, tiles: 2),
        .init(name: "qr-P300-F10-2x2", mode: .qr, sb: 300, fps: 10, tiles: 2),
        .init(name: "mono96-F10", mode: .matrixMono, sb: 0, fps: 10, tiles: 1),
        .init(name: "mono96-F15", mode: .matrixMono, sb: 0, fps: 15, tiles: 1),
        .init(name: "gray64-F10", mode: .matrixGray, sb: 0, fps: 10, tiles: 1),
        .init(name: "gray64-F15", mode: .matrixGray, sb: 0, fps: 15, tiles: 1),
    ]

    private var fileData: Data?
    private var sender: LBOPSender?
    private var timer: Timer?
    private var startDate: Date?
    private var labTask: Task<Void, Never>?
    private let ciContext = CIContext()

    // MARK: Dosya
    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { errorText = "Dosya okunamadı"; return }
        stopLab(); stop()
        fileData = d; fileName = url.lastPathComponent; fileSize = d.count; errorText = nil
    }

    /// Paylaş eklentisinin bıraktığı dosyayı alır ve yayını başlatır.
    func loadFromInbox() {
        guard let inbox = SharedInbox.folder,
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]),
              let newest = files.max(by: {
                  ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                  ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
              }) else { return }
        load(url: newest)
        try? FileManager.default.removeItem(at: newest)
        start()
    }

    // MARK: Yayın
    var effectiveSymbolBytes: Int { mode.spec?.maxSymbolBytes ?? Int(symbolBytes) }
    var packetsPerFrame: Int { mode == .qr ? tiles * tiles : 1 }

    func start() {
        guard let d = fileData else { return }
        do {
            let s = try LBOPSender(fileData: d, fileName: fileName, symbolBytes: effectiveSymbolBytes,
                                   blockSymbols: 128, passphrase: isLab ? nil : (passphrase.isEmpty ? nil : passphrase))
            sender = s; symbolCount = s.symbolCount
        } catch { errorText = "Şifreleme hatası"; return }
        isSending = true; startDate = Date(); elapsed = 0; errorText = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil; isSending = false; image = nil }
    func restartIfNeeded() { if isSending && !isLab { start() } }

    private func tick() {
        guard let s = sender else { return }
        let pkts = (0..<packetsPerFrame).map { _ in s.nextPacket() }
        switch mode {
        case .qr: image = composeQR(pkts.map { Base45.encode($0.encode()) }, tiles: tiles)
        case .matrixMono, .matrixGray: if let spec = mode.spec { image = renderMatrix(pkts[0], spec: spec) }
        }
        currentSymbol = s.currentSymbol; inRepair = s.inRepairPhase
        if let t = startDate { elapsed = Date().timeIntervalSince(t) }
    }

    /// Tahmini ham hız (bayt/sn). Gerçek hız alıcıda ölçülür (Lab).
    var estimatedBytesPerSecond: Double { fps * Double(packetsPerFrame) * Double(effectiveSymbolBytes) * 23.0 / 24.0 }

    // MARK: Görüntü üretimi
    private func composeQR(_ texts: [String], tiles: Int) -> NSImage? {
        let side = 1000, tileSide = side / tiles
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        for (i, t) in texts.enumerated() {
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(t.utf8); f.correctionLevel = "M"
            guard let out = f.outputImage?.samplingNearest(),
                  let cg = ciContext.createCGImage(out, from: out.extent) else { continue }
            let quiet = max(8, Int(Double(tileSide) * 0.07))
            let k = max(1, (tileSide - 2 * quiet) / cg.width)
            let w = min(tileSide, cg.width * k)
            let col = i % tiles, row = i / tiles
            let x = col * tileSide + (tileSide - w) / 2
            let y = side - (row + 1) * tileSide + (tileSide - w) / 2
            ctx.draw(cg, in: CGRect(x: x, y: y, width: w, height: w))
        }
        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: side, height: side))
    }

    private func renderMatrix(_ pkt: LBOPPacket, spec: MatrixSpec) -> NSImage? {
        guard let r = LBMatrix.renderLuma(packet: pkt.encode(), spec: spec, cellPx: 10),
              let provider = CGDataProvider(data: Data(r.pixels) as CFData),
              let cg = CGImage(width: r.side, height: r.side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: r.side,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: r.side, height: r.side))
    }

    // MARK: Hız laboratuvarı (M4)
    /// Profilleri sırayla yayınlar (her biri 25 sn, 32 KiB rastgele veri). iPhone "Lab modu" açıkken
    /// her oturumu ölçer ve CSV'ye yazar. Simplex olduğundan Mac sonucu görmez; sonuçlar telefondadır.
    func startLab() {
        stopLab(); stop()
        isLab = true
        labTask = Task { [weak self] in
            guard let self else { return }
            for p in Self.labProfiles {
                if Task.isCancelled { break }
                self.labStatus = "\(p.name)"
                self.mode = p.mode; self.fps = p.fps; self.tiles = p.tiles
                if p.sb > 0 { self.symbolBytes = Double(p.sb) }
                var d = Data(count: 32 * 1024)
                _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32 * 1024, $0.baseAddress!) }
                self.fileData = d; self.fileName = "LAB-\(p.name)"; self.fileSize = d.count
                self.start()
                try? await Task.sleep(nanoseconds: UInt64(self.labSeconds * 1_000_000_000))
            }
            self.stop(); self.isLab = false; self.labStatus = "Lab bitti"
        }
    }

    func stopLab() { labTask?.cancel(); labTask = nil; if isLab { isLab = false; stop() } }
}
