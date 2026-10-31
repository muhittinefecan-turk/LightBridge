import Foundation

public enum LBOP {
    public static let magic: [UInt8] = Array("LBOP".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 28
    public static let maxPayload = 1200
}

public enum PacketType: UInt8 {
    case manifest = 0x01, data = 0x02, repair = 0x03, end = 0x04
}

public enum PacketError: Error {
    case tooShort, badMagic, unsupportedVersion, unknownType, badLength, badCRC
}

/// LBOP/1 paketi: 28 bayt başlık (big-endian) + payload.
public struct LBOPPacket: Equatable {
    public var type: PacketType
    public var sessionID: Data      // 8 bayt
    public var blockIndex: UInt32
    public var sequence: UInt32
    public var payload: Data

    public init(type: PacketType, sessionID: Data, blockIndex: UInt32 = 0, sequence: UInt32, payload: Data) {
        precondition(sessionID.count == 8)
        self.type = type; self.sessionID = sessionID
        self.blockIndex = blockIndex; self.sequence = sequence; self.payload = payload
    }

    public func encode() -> Data {
        var d = Data(LBOP.magic)
        d.append(LBOP.version)
        d.append(type.rawValue)
        d.append(sessionID)
        d.appendBE(blockIndex)
        d.appendBE(sequence)
        d.appendBE(UInt16(payload.count))
        d.appendBE(UInt32(0))               // CRC yer tutucu
        d.append(payload)
        let crc = CRC32C.checksum(d)
        d.replaceSubrange(24..<28, with: withUnsafeBytes(of: crc.bigEndian) { Data($0) })
        return d
    }

    public static func decode(_ data: Data) throws -> LBOPPacket {
        let b = [UInt8](data)
        guard b.count >= LBOP.headerSize else { throw PacketError.tooShort }
        guard Array(b[0..<4]) == LBOP.magic else { throw PacketError.badMagic }
        guard b[4] == LBOP.version else { throw PacketError.unsupportedVersion }
        guard let type = PacketType(rawValue: b[5]) else { throw PacketError.unknownType }
        let session = Data(b[6..<14])
        let block = b.beU32(at: 14)
        let seq = b.beU32(at: 18)
        let len = Int(b[22]) << 8 | Int(b[23])
        let crc = b.beU32(at: 24)
        guard len <= LBOP.maxPayload, b.count == LBOP.headerSize + len else { throw PacketError.badLength }
        var zeroed = b
        zeroed.replaceSubrange(24..<28, with: [0, 0, 0, 0])
        guard CRC32C.checksum(Data(zeroed)) == crc else { throw PacketError.badCRC }
        return LBOPPacket(type: type, sessionID: session, blockIndex: block, sequence: seq,
                          payload: Data(b[28...]))
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE(_ v: UInt32) { for s in [24, 16, 8, 0] { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func appendBE(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(s)) & 0xFF)) } }
}
extension Array where Element == UInt8 {
    func beU32(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func beU64(at i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[i + $1]) }
    }
}
