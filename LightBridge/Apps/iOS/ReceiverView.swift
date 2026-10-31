import SwiftUI

struct ReceiverView: View {
    @StateObject private var m = ReceiverModel()
    @State private var pin = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if m.mode == .qr {
                    ScannerView(lockFocus: m.lockFocus) { m.handle(qr: $0) }
                } else {
                    MatrixScannerView(lockFocus: m.lockFocus) { m.handleFrame($0) }
                }
            }
            .id(m.mode)
            .ignoresSafeArea()

            if m.mode == .matrix {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .frame(width: g.size.width * 0.95, height: g.size.width * 0.95)
                        .position(x: g.size.width / 2, y: g.size.height / 2.3)
                }.allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                if let url = m.savedURL {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text(url.lastPathComponent).font(.headline).lineLimit(1)
                    if let t = m.finishedIn { Text("Doğrulandı (SHA-256) · \(String(format: "%.1f", t)) sn").font(.caption) }
                    HStack {
                        ShareLink(item: url) { Label("Paylaş / Kaydet", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                        Button("Yeni aktarım") { m.reset() }.buttonStyle(.bordered)
                    }
                    Text("Dosyalar → iPhone'umda → LightBridge").font(.caption2).foregroundStyle(.secondary)
                } else if m.needsPIN {
                    Label("Şifreli dosya alındı", systemImage: "lock.fill")
                    SecureField("Parola", text: $pin).textFieldStyle(.roundedBorder)
                    if m.pinError { Text("Parola yanlış").font(.caption).foregroundStyle(.red) }
                    Button("Aç") { m.unlock(pin) }.buttonStyle(.borderedProminent)
                } else {
                    switch m.status.state {
                    case .waiting:
                        Label(m.mode == .qr ? "Mac ekranındaki kodu kameraya göster"
                                            : "Matrisi sarı çerçeveye sığdır, telefonu ekrana paralel tut",
                              systemImage: "viewfinder")
                    case .receiving:
                        ProgressView(value: m.status.fraction)
                        Text("%\(Int(m.status.fraction * 100)) · \(m.status.received)/\(m.status.total) sembol").font(.caption)
                    case .hashMismatch:
                        Label("Özet uyuşmadı, tekrar alınıyor…", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    case .needsPassphrase, .verified:
                        if m.labMode, case .verified = m.status.state { Label("Alındı (Lab)", systemImage: "checkmark") }
                    }
                }

                Picker("Mod", selection: $m.mode) { ForEach(ScanMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                HStack {
                    Toggle("Odağı kilitle", isOn: $m.lockFocus)
                    Toggle("Lab", isOn: $m.labMode)
                }.font(.caption).toggleStyle(.button)

                if m.labMode {
                    if let csv = m.labCSV { ShareLink(item: csv) { Label("CSV'yi paylaş", systemImage: "tablecells") }.font(.caption) }
                    ForEach(m.labRows.prefix(4)) { r in
                        Text("\(r.name): \(r.ok ? "\(Int(r.goodput)) B/s" : "tamamlanmadı \(r.received)/\(r.total)")")
                            .font(.caption2.monospaced())
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
        .overlay(alignment: .top) {
            Text("Okunan: \(m.rawCount) · Geçerli: \(m.validCount)")
                .font(.caption.monospaced()).padding(6)
                .background(.black.opacity(0.6)).foregroundStyle(.white)
        }
    }
}
