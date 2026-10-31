import Foundation
import Network
import CryptoKit
import Darwin

/// Payload encoded into the LightBridge beacon and custom URL scheme.
public struct HighSpeedBeaconPayload: Equatable {
    public let token: String
    public let ip: String
    public let port: UInt16
    public let fileName: String
    public let fileSize: UInt64
    public let sha256Hex: String

    public init(token: String, ip: String, port: UInt16, fileName: String, fileSize: UInt64, sha256Hex: String) {
        self.token = token
        self.ip = ip
        self.port = port
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256Hex = sha256Hex
    }

    /// URL for native iOS Camera scanning (triggers yellow banner) and in-app scanner.
    public func toURL() -> URL? {
        var comp = URLComponents()
        comp.scheme = "lightbridge"
        comp.host = "transfer"
        comp.queryItems = [
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "ip", value: ip),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "n", value: fileName),
            URLQueryItem(name: "s", value: String(fileSize)),
            URLQueryItem(name: "h", value: sha256Hex)
        ]
        return comp.url
    }

    public static func parse(string: String) -> HighSpeedBeaconPayload? {
        guard let url = URL(string: string) else { return nil }
        return parse(url: url)
    }

    public static func parse(url: URL) -> HighSpeedBeaconPayload? {
        guard url.scheme == "lightbridge",
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comp.queryItems else { return nil }

        func val(_ key: String) -> String? { items.first(where: { $0.name == key })?.value }

        guard let token = val("t"),
              let ip = val("ip"),
              let portStr = val("p"), let port = UInt16(portStr),
              let name = val("n"),
              let sizeStr = val("s"), let size = UInt64(sizeStr),
              let hash = val("h") else { return nil }

        return HighSpeedBeaconPayload(
            token: token,
            ip: ip,
            port: port,
            fileName: name,
            fileSize: size,
            sha256Hex: hash
        )
    }
}

/// Helper to get local IPv4 address
public enum LocalNetworkHelper {
    public static func getLocalIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Prioritize en0 (standard Wi-Fi on Mac and iOS)
                if name == "en0" || name == "en1" || name == "pdp_ip0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: hostname)
                        if name == "en0" { break }
                    }
                }
            }
        }
        return address
    }
}

/// High-speed P2P sender powered by Network.framework.
public final class HighSpeedSender {
    public enum State {
        case idle
        case listening
        case transmitting(progress: Double, speedMBs: Double)
        case finished
        case failed(String)
    }

    private let fileData: Data
    private let fileName: String
    private let sha256Hex: String
    public let token: String

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.lightbridge.highspeed.sender", qos: .userInteractive)

    public var onStateChange: ((State) -> Void)?

    public init(fileData: Data, fileName: String) {
        self.fileData = fileData
        self.fileName = fileName
        self.token = String(UUID().uuidString.prefix(12))

        let digest = SHA256.hash(data: fileData)
        self.sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
    }

    public func start() throws -> HighSpeedBeaconPayload {
        stop()

        guard let ip = LocalNetworkHelper.getLocalIPv4() ?? "127.0.0.1" as String? else {
            throw NSError(domain: "LightBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Yerel IP adresi bulunamadı."])
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true

        let l = try NWListener(using: params)
        self.listener = l

        // Bonjour üzerinden anında keşif yayını
        var txt = NWTXTRecord()
        txt["token"] = token
        txt["name"] = fileName
        txt["size"] = String(fileData.count)
        txt["sha"] = sha256Hex
        l.service = NWListener.Service(name: "LightBridge-\(token.prefix(6))", type: "_lightbridge._tcp", domain: "local.", txtRecord: txt)

        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.listening)
            case .failed(let err):
                self.onStateChange?(.failed(err.localizedDescription))
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        l.start(queue: queue)

        // Block briefly until ready or use assigned port if available
        let semaphore = DispatchSemaphore(value: 0)
        var assignedPort: UInt16 = 0
        l.stateUpdateHandler = { newState in
            if case .ready = newState, let p = l.port?.rawValue {
                assignedPort = p
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 0.3)
        if assignedPort == 0 { assignedPort = l.port?.rawValue ?? 0 }

        return HighSpeedBeaconPayload(
            token: token,
            ip: ip,
            port: assignedPort,
            fileName: fileName,
            fileSize: UInt64(fileData.count),
            sha256Hex: sha256Hex
        )
    }

    private func handleConnection(_ conn: NWConnection) {
        activeConnection?.cancel()
        activeConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.verifyAndSend(conn)
            }
        }
        conn.start(queue: queue)
    }

    private func verifyAndSend(_ conn: NWConnection) {
        // First read handshake token line (ends with \n)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, _, error in
            guard let self = self, let data = data,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  line == self.token else {
                conn.cancel()
                return
            }
            self.streamData(conn)
        }
    }

    private func streamData(_ conn: NWConnection) {
        let total = fileData.count
        var offset = 0
        let chunkSize = 128 * 1024 // 128 KB
        let startTime = Date()

        func sendNext() {
            guard offset < total else {
                // Done! Send 4-byte completion marker: 0xDEADBEEF
                var marker = UInt32(0xDEADBEEF).bigEndian
                let markerData = Data(bytes: &marker, count: 4)
                conn.send(content: markerData, completion: .contentProcessed { [weak self] _ in
                    self?.onStateChange?(.finished)
                })
                return
            }

            let nextChunkSize = min(chunkSize, total - offset)
            let chunk = fileData.subdata(in: offset..<(offset + nextChunkSize))
            offset += nextChunkSize

            let elapsed = max(0.001, Date().timeIntervalSince(startTime))
            let speedMBs = (Double(offset) / (1024 * 1024)) / elapsed
            let progress = Double(offset) / Double(total)
            self.onStateChange?(.transmitting(progress: progress, speedMBs: speedMBs))

            conn.send(content: chunk, completion: .contentProcessed { err in
                if err == nil {
                    sendNext()
                } else {
                    conn.cancel()
                }
            })
        }

        sendNext()
    }

    public func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
    }

    deinit {
        stop()
    }
}

/// High-speed P2P client powered by Network.framework.
public final class HighSpeedClient {
    public enum State {
        case connecting
        case downloading(progress: Double, speedMBs: Double)
        case verifying
        case success(name: String, data: Data)
        case failed(String)
    }

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.lightbridge.highspeed.client", qos: .userInteractive)
    public var onStateChange: ((State) -> Void)?

    public init() {}

    public func receive(payload: HighSpeedBeaconPayload) {
        let endpointHost = NWEndpoint.Host(payload.ip)
        guard let endpointPort = NWEndpoint.Port(rawValue: payload.port) else {
            onStateChange?(.failed("Geçersiz port: \(payload.port)"))
            return
        }
        let conn = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        startWithConnection(conn, payload: payload)
    }

    public func receive(endpoint: NWEndpoint, payload: HighSpeedBeaconPayload) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        startWithConnection(conn, payload: payload)
    }

    private func startWithConnection(_ conn: NWConnection, payload: HighSpeedBeaconPayload) {
        onStateChange?(.connecting)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendHandshake(payload)
            case .failed(let err):
                self.onStateChange?(.failed("Bağlantı hatası: \(err.localizedDescription)"))
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func sendHandshake(_ payload: HighSpeedBeaconPayload) {
        let handshake = "\(payload.token)\n".data(using: .utf8)!
        connection?.send(content: handshake, completion: .contentProcessed { [weak self] err in
            if let err = err {
                self?.onStateChange?(.failed("El sıkışma hatası: \(err.localizedDescription)"))
                return
            }
            self?.readStream(payload)
        })
    }

    private func readStream(_ payload: HighSpeedBeaconPayload) {
        let total = Int(payload.fileSize)
        var received = Data()
        received.reserveCapacity(total)
        let startTime = Date()

        func readLoop() {
            guard let conn = self.connection else { return }

            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    received.append(data)
                    let currentCount = min(received.count, total)
                    let elapsed = max(0.001, Date().timeIntervalSince(startTime))
                    let speedMBs = (Double(currentCount) / (1024 * 1024)) / elapsed
                    let progress = total == 0 ? 1.0 : Double(currentCount) / Double(total)
                    self.onStateChange?(.downloading(progress: progress, speedMBs: speedMBs))
                }

                if received.count >= total || isComplete {
                    self.finish(received: received.prefix(total), payload: payload)
                } else if error != nil {
                    self.onStateChange?(.failed("İndirme sırasında veri kesildi."))
                } else {
                    readLoop()
                }
            }
        }

        readLoop()
    }

    private func finish(received: Data, payload: HighSpeedBeaconPayload) {
        onStateChange?(.verifying)
        connection?.cancel()
        connection = nil

        let digest = SHA256.hash(data: received)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        if hex.lowercased() == payload.sha256Hex.lowercased() {
            onStateChange?(.success(name: payload.fileName, data: Data(received)))
        } else {
            onStateChange?(.failed("SHA-256 doğrulama hatası!"))
        }
    }

    public func cancel() {
        connection?.cancel()
        connection = nil
    }

    deinit {
        cancel()
    }
}

/// Bonjour tabanlı otomatik yakındaki Mac keşif motoru (Sıfır tarama süresi)
public final class HighSpeedBrowser {
    private var browser: NWBrowser?
    public var onDiscovered: ((NWEndpoint, HighSpeedBeaconPayload) -> Void)?

    public init() {}

    public func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_lightbridge._tcp", domain: "local."), using: params)
        b.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            for result in results {
                if case .service = result.endpoint {
                    if case .bonjour(let txt) = result.metadata {
                        if let token = txt["token"],
                           let fileName = txt["name"],
                           let sizeStr = txt["size"], let size = UInt64(sizeStr),
                           let sha = txt["sha"] {
                            let payload = HighSpeedBeaconPayload(
                                token: token,
                                ip: "",
                                port: 0,
                                fileName: fileName,
                                fileSize: size,
                                sha256Hex: sha
                            )
                            self.onDiscovered?(result.endpoint, payload)
                        }
                    }
                }
            }
        }
        b.start(queue: .main)
        self.browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    deinit {
        stop()
    }
}
