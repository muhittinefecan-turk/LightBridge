import SwiftUI
import UniformTypeIdentifiers

struct SenderView: View {
    @EnvironmentObject var m: SenderModel
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("LIGHTBRIDGE").font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(4)

                ZStack {
                    Rectangle().fill(.white)
                    if let img = m.image {
                        Image(nsImage: img).interpolation(.none).resizable().scaledToFit().padding(10)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 42))
                            Text("Dosyayı buraya sürükle ya da seç").font(.headline)
                            Text("Finder'da sağ tık → Paylaş → LightBridge de çalışır").font(.caption)
                        }.foregroundStyle(.gray)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: 560)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                            Task { @MainActor in m.load(url: u); m.start() }
                        }
                    }
                    return true
                }

                if m.isLab {
                    Text("LAB: \(m.labStatus) · iPhone'da Lab modunu aç").font(.headline).foregroundStyle(.orange)
                }
                if !m.fileName.isEmpty {
                    VStack(spacing: 4) {
                        Text(m.fileName).font(.headline).lineLimit(1)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(m.fileSize), countStyle: .file)) · \(m.symbolCount) sembol")
                            .font(.caption).foregroundStyle(.secondary)
                        if m.isSending {
                            ProgressView(value: Double(m.currentSymbol), total: Double(max(1, m.symbolCount)))
                            Text(m.inRepair ? "Onarım turu (FEC) · \(Int(m.elapsed)) sn" : "İlk tur · \(Int(m.elapsed)) sn")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Tahmini ham hız ≈ \(Int(m.estimatedBytesPerSecond / 100) * 100 / 1000) KB/s (gerçek hız alıcıda ölçülür)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let e = m.errorText { Text(e).foregroundStyle(.red).font(.caption) }

                HStack {
                    Button("Dosya seç…") { importing = true }
                    if m.isSending { Button("Durdur") { m.stopLab(); m.stop() } }
                    else if !m.fileName.isEmpty { Button("Başlat") { m.start() }.keyboardShortcut(.defaultAction) }
                    Button("Tam ekran") { NSApp.keyWindow?.toggleFullScreen(nil) }
                }

                GroupBox("Kanal") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mod", selection: $m.mode) {
                            ForEach(SendMode.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).onChange(of: m.mode) { _ in m.restartIfNeeded() }
                        if m.mode == .qr {
                            Picker("Çoklu kod", selection: $m.tiles) {
                                Text("1×1").tag(1); Text("2×2").tag(2); Text("3×3").tag(3)
                            }.pickerStyle(.segmented).onChange(of: m.tiles) { _ in m.restartIfNeeded() }
                            HStack { Text("Sembol: \(Int(m.symbolBytes)) B")
                                Slider(value: $m.symbolBytes, in: 100...900, step: 50) { _ in m.restartIfNeeded() } }
                        }
                        HStack { Text("Kare/sn: \(Int(m.fps))")
                            Slider(value: $m.fps, in: 4...30, step: 1) { _ in m.restartIfNeeded() } }
                        SecureField("Parola (isteğe bağlı, şifreler)", text: $m.passphrase)
                        Text("Kayıp paketleri onarım (FEC) tamamlar. Okuma zorsa kare/sn ve sembolü düşür; iPhone'u ekrana düz tut. Matris modları deneyseldir: iPhone'da Matris moduna geçip çerçeveye sığdır.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                GroupBox("Hız laboratuvarı") {
                    HStack {
                        Text("11 profili 25'er sn yayınlar; iPhone'da Lab modu sonuçları CSV'ye yazar.").font(.caption)
                        Spacer()
                        if m.isLab { Button("Lab'ı durdur") { m.stopLab() } } else { Button("Lab başlat") { m.startLab() } }
                    }
                }
            }
            .padding(20)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { r in
            if case .success(let u) = r { m.load(url: u); m.start() }
        }
    }
}
