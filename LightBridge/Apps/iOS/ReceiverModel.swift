import SwiftUI
import LightBridgeCore
import Photos

struct LabRow: Identifiable {
    let id = UUID()
    let time: Date
    let name: String
    let bytes: Int
    let seconds: Double
    let received: Int
    let total: Int
    let raw: Int
    let valid: Int
    let ok: Bool
    var goodput: Double { ok && seconds > 0 ? Double(bytes) / seconds : 0 }
    var csv: String {
        let f = ISO8601DateFormatter().string(from: time)
        return "\(f),\(name),\(bytes),\(String(format: "%.2f", seconds)),\(Int(goodput)),\(received),\(total),\(raw),\(valid),\(ok ? "ok" : "incomplete")"
    }
    static let header = "time,profile,bytes,seconds,goodput_Bps,received_symbols,total_symbols,raw_frames,valid_packets,result"
}

enum ScanMode: String, CaseIterable, Identifiable {
    case qr = "QR", matrix = "Matris"
    var id: String { rawValue }
}

@MainActor
final class ReceiverModel: ObservableObject {
    @Published var status = ReceiveStatus()
    @Published var savedURL: URL?
    @Published var finishedIn: TimeInterval?
    @Published var rawCount = 0
    @Published var validCount = 0
    @Published var needsPIN = false
    @Published var pinError = false
    @Published var labMode = false
    @Published var labRows: [LabRow] = []
    @Published var mode: ScanMode = .qr
    @Published var lockFocus = false
    @Published var labCSV: URL?

    private let rx = LBOPReceiver()
    private var startedAt: Date?
    private var handledSession: Data?
    private var curName = ""
    private var persistTimer: Timer?

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lb_state.json")
    }

    init() {
        // M3: yarım kalan aktarımı geri yükle
        if let d = try? Data(contentsOf: stateURL), !d.isEmpty {
            rx.restore(d); status = rx.status
            if status.state == .receiving { startedAt = Date(); curName = rx.manifest?.fileName ?? "" }
        }
        persistTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persist() }
        }
    }

    private func persist() {
        if status.state == .receiving { try? rx.exportState().write(to: stateURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: stateURL) }
    }

    // MARK: Girişler
    func handle(qr: String) {
        rawCount += 1
        guard let raw = try? Base45.decode(qr) else { return }
        process(raw)
    }

    func handleFrame(_ raw: Data?) {
        rawCount += 1
        guard let raw else { return }
        process(raw)
    }

    private func process(_ raw: Data) {
        guard (try? LBOPPacket.decode(raw)) != nil else { return }
        validCount += 1
        let before = status
        let beforeSession = rx.sessionID
        status = rx.ingest(packet: raw)

        if rx.sessionID != beforeSession {
            // yeni oturum: önceki yarım kaldıysa lab'e yaz
            if labMode, before.state == .receiving, let t = startedAt {
                logRow(name: curName, bytes: 0, secs: Date().timeIntervalSince(t),
                       rec: before.received, tot: before.total, ok: false)
            }
            startedAt = nil; finishedIn = nil; savedURL = nil; needsPIN = false
            rawCount = 1; validCount = 1
        }
        if let m = rx.manifest { curName = m.fileName }
        if status.state == .receiving, startedAt == nil {
            startedAt = Date(); UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if status.state == .needsPassphrase { needsPIN = true }
        if case .verified = status.state, handledSession != rx.sessionID, let r = rx.result {
            handledSession = rx.sessionID
            completed(r.name, r.data)
        }
    }

    private func completed(_ name: String, _ data: Data) {
        let secs = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        finishedIn = secs
        if labMode {
            logRow(name: name, bytes: data.count, secs: secs, rec: status.total, tot: status.total, ok: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            save(name, data)
        }
    }

    func unlock(_ pin: String) {
        if rx.unlock(passphrase: pin), let r = rx.result {
            needsPIN = false; pinError = false; status = rx.status
            handledSession = rx.sessionID
            completed(r.name, r.data)
        } else { pinError = true }
    }

    // MARK: Lab (M4)
    private func logRow(name: String, bytes: Int, secs: Double, rec: Int, tot: Int, ok: Bool) {
        let row = LabRow(time: Date(), name: name, bytes: bytes, seconds: secs, received: rec, total: tot,
                         raw: rawCount, valid: validCount, ok: ok)
        labRows.insert(row, at: 0)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("lightbridge_lab.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? (LabRow.header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data((row.csv + "\n").utf8)); try? h.close()
        }
        labCSV = url
    }

    // MARK: Kaydetme
    private func save(_ name: String, _ data: Data) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dst = docs.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: dst.path) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            dst = docs.appendingPathComponent(ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"); i += 1
        }
        try? data.write(to: dst, options: .atomic)
        savedURL = dst
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let ext = dst.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "gif", "mov", "mp4"].contains(ext) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                guard s == .authorized || s == .limited else { return }
                PHPhotoLibrary.shared().performChanges {
                    if ["mov", "mp4"].contains(ext) { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: dst) }
                    else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: dst) }
                }
            }
        }
    }

    func reset() {
        rx.reset(); status = ReceiveStatus(); savedURL = nil; startedAt = nil; finishedIn = nil
        handledSession = nil; needsPIN = false; pinError = false; rawCount = 0; validCount = 0
        try? FileManager.default.removeItem(at: stateURL)
    }
}
