import Foundation
import CryptoKit

public struct ReceiveStatus: Equatable {
    public enum State: Equatable {
        case waiting
        case receiving
        case needsPassphrase
        case verified(fileName: String)
        case hashMismatch
    }
    public var state: State = .waiting
    public var received: Int = 0   // çözülmüş bağımsız sembol sayısı
    public var total: Int = 0
    public var fraction: Double { total == 0 ? 0 : Double(received) / Double(total) }
    public init(state: State = .waiting, received: Int = 0, total: Int = 0) {
        self.state = state; self.received = received; self.total = total
    }
}

/// Alıcı: paket → oturum → blok çözücüler (sistematik + onarım) → birleştirme → SHA-256 → (şifre çözme).
public final class LBOPReceiver {
    public private(set) var status = ReceiveStatus()
    public private(set) var result: (name: String, data: Data)?
    public private(set) var sessionID: Data?
    public private(set) var manifest: FileManifest?
    /// Yeni oturumun manifesti gelirse mevcut oturumu bırakıp ona geçer.
    public var autoSwitchSession = true

    public static let maxFileBytes: UInt64 = 256 * 1024 * 1024
    private struct Pending { let pkt: LBOPPacket; let raw: Data }
    private var decoders: [Int: BlockDecoder] = [:]
    private var pending: [Pending] = []
    private var accepted: [Data] = []
    private var cipherBlob: Data?

    public init() {}

    public func reset() {
        sessionID = nil; manifest = nil; decoders = [:]; pending = []; accepted = []
        cipherBlob = nil; result = nil; status = ReceiveStatus()
    }

    @discardableResult
    public func ingest(qrString: String) -> ReceiveStatus {
        guard let raw = try? Base45.decode(qrString) else { return status }
        return ingest(packet: raw)
    }

    @discardableResult
    public func ingest(packet raw: Data) -> ReceiveStatus {
        guard let pkt = try? LBOPPacket.decode(raw) else { return status }

        if sessionID == nil {
            sessionID = pkt.sessionID
        } else if pkt.sessionID != sessionID {
            guard autoSwitchSession, pkt.type == .manifest,
                  (try? FileManifest.decode(pkt.payload)) != nil else { return status }
            reset(); sessionID = pkt.sessionID
        }
        if result != nil || status.state == .needsPassphrase { return status }

        switch pkt.type {
        case .manifest:
            guard manifest == nil, let m = try? FileManifest.decode(pkt.payload),
                  m.originalLength <= Self.maxFileBytes else { break }
            manifest = m
            status.total = Int(m.symbolCount)
            accepted.append(raw)
            let queued = pending; pending = []
            for p in queued { apply(p.pkt, raw: p.raw, m) }
        case .data, .repair:
            if let m = manifest { apply(pkt, raw: raw, m) }
            else if pending.count < 4096 { pending.append(Pending(pkt: pkt, raw: raw)) }
        case .end:
            break
        }

        guard let m = manifest else { return status }
        status.received = decoders.values.reduce(0) { $0 + $1.rank }
        if (0..<m.blockCount).allSatisfy({ decoders[$0]?.isSolved == true }) { finish(m) }
        else { status.state = .receiving }
        return status
    }

    private func apply(_ pkt: LBOPPacket, raw: Data, _ m: FileManifest) {
        let b = Int(pkt.blockIndex)
        guard b < m.blockCount, pkt.payload.count == Int(m.symbolBytes) else { return }
        let kb = m.blockSize(b)
        let bits: [UInt64]
        switch pkt.type {
        case .data:
            guard Int(pkt.sequence) < kb else { return }
            bits = Fountain.systematicBits(k: kb, index: Int(pkt.sequence))
        case .repair:
            bits = Fountain.repairBits(k: kb, block: pkt.blockIndex, seed: pkt.sequence)
        default: return
        }
        let dec: BlockDecoder
        if let d = decoders[b] { dec = d } else { dec = BlockDecoder(k: kb, symbolBytes: Int(m.symbolBytes)); decoders[b] = dec }
        if dec.add(bits: bits, data: pkt.payload) { accepted.append(raw) }
    }

    private func finish(_ m: FileManifest) {
        var out = Data(capacity: Int(m.originalLength) + Int(m.symbolBytes))
        for b in 0..<m.blockCount {
            guard let syms = decoders[b]?.symbols() else { return }
            for s in syms { out.append(s) }
        }
        out = out.prefix(Int(m.originalLength))
        guard Data(SHA256.hash(data: out)) == m.sha256 else {
            status.state = .hashMismatch
            decoders = [:]; status.received = 0
            if let first = accepted.first { accepted = [first] }
            return
        }
        status.received = status.total
        if m.encrypted {
            cipherBlob = out
            status.state = .needsPassphrase
        } else {
            result = (m.fileName, out)
            status.state = .verified(fileName: m.fileName)
        }
    }

    /// Şifreli aktarım için parolayı dener.
    @discardableResult
    public func unlock(passphrase: String) -> Bool {
        guard let m = manifest, let blob = cipherBlob,
              let r = try? LBCrypto.open(blob: blob, salt: m.salt, passphrase: passphrase) else { return false }
        result = (r.name, r.data)
        status.state = .verified(fileName: r.name)
        return true
    }

    // MARK: Devam ettirme (M3)
    private struct Snapshot: Codable { var packets: [Data] }

    /// Kabul edilmiş (bilgi getiren) paketleri serileştirir; uygulama kapanıp açılınca kaldığı yerden sürer.
    public func exportState() -> Data {
        (try? JSONEncoder().encode(Snapshot(packets: accepted))) ?? Data()
    }

    public func restore(_ data: Data) {
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        reset()
        for p in snap.packets { ingest(packet: p) }
    }
}
