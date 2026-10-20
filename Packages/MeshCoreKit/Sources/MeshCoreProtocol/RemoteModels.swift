import Foundation

/// `PUSH_CODE_LOGIN_SUCCESS`.
public struct LoginResult: Hashable, Sendable, Codable {
  public var permissions: UInt8
  public var nodePrefix: KeyPrefix
  public var serverTimestamp: UInt32?
  public var aclPermissions: UInt8?
  public var firmwareLevel: UInt8?

  public init(
    permissions: UInt8,
    nodePrefix: KeyPrefix,
    serverTimestamp: UInt32? = nil,
    aclPermissions: UInt8? = nil,
    firmwareLevel: UInt8? = nil
  ) {
    self.permissions = permissions
    self.nodePrefix = nodePrefix
    self.serverTimestamp = serverTimestamp
    self.aclPermissions = aclPermissions
    self.firmwareLevel = firmwareLevel
  }

  /// Bit 0 of `permissions` flags admin access.
  public var isAdmin: Bool { permissions & 0x01 != 0 }
}

/// The stats block returned by repeaters and room servers to a status request.
public struct RemoteNodeStatus: Hashable, Sendable, Codable {
  public var batteryMillivolts: UInt16
  public var txQueueLength: UInt16
  public var noiseFloor: Int16
  public var lastRSSI: Int16
  public var packetsReceived: UInt32
  public var packetsSent: UInt32
  public var airtimeSeconds: UInt32
  public var uptimeSeconds: UInt32
  public var sentFlood: UInt32
  public var sentDirect: UInt32
  public var receivedFlood: UInt32
  public var receivedDirect: UInt32
  public var errorEvents: UInt16
  public var lastSNR: Double
  public var directDuplicates: UInt16
  public var floodDuplicates: UInt16
  public var rxAirtimeSeconds: UInt32
  public var receiveErrors: UInt32?

  public init(
    batteryMillivolts: UInt16 = 0, txQueueLength: UInt16 = 0, noiseFloor: Int16 = 0,
    lastRSSI: Int16 = 0, packetsReceived: UInt32 = 0, packetsSent: UInt32 = 0,
    airtimeSeconds: UInt32 = 0, uptimeSeconds: UInt32 = 0, sentFlood: UInt32 = 0,
    sentDirect: UInt32 = 0, receivedFlood: UInt32 = 0, receivedDirect: UInt32 = 0,
    errorEvents: UInt16 = 0, lastSNR: Double = 0, directDuplicates: UInt16 = 0,
    floodDuplicates: UInt16 = 0, rxAirtimeSeconds: UInt32 = 0, receiveErrors: UInt32? = nil
  ) {
    self.batteryMillivolts = batteryMillivolts
    self.txQueueLength = txQueueLength
    self.noiseFloor = noiseFloor
    self.lastRSSI = lastRSSI
    self.packetsReceived = packetsReceived
    self.packetsSent = packetsSent
    self.airtimeSeconds = airtimeSeconds
    self.uptimeSeconds = uptimeSeconds
    self.sentFlood = sentFlood
    self.sentDirect = sentDirect
    self.receivedFlood = receivedFlood
    self.receivedDirect = receivedDirect
    self.errorEvents = errorEvents
    self.lastSNR = lastSNR
    self.directDuplicates = directDuplicates
    self.floodDuplicates = floodDuplicates
    self.rxAirtimeSeconds = rxAirtimeSeconds
    self.receiveErrors = receiveErrors
  }

  /// Decodes the 52 (or 56, firmware ≥ 1.12) byte `RepeaterStats` struct.
  public init(decoding data: Data) throws {
    var r = ByteReader(data)
    batteryMillivolts = try r.u16()
    txQueueLength = try r.u16()
    noiseFloor = try r.i16()
    lastRSSI = try r.i16()
    packetsReceived = try r.u32()
    packetsSent = try r.u32()
    airtimeSeconds = try r.u32()
    uptimeSeconds = try r.u32()
    sentFlood = try r.u32()
    sentDirect = try r.u32()
    receivedFlood = try r.u32()
    receivedDirect = try r.u32()
    errorEvents = try r.u16()
    lastSNR = Double(try r.i16()) / 4
    directDuplicates = try r.u16()
    floodDuplicates = try r.u16()
    rxAirtimeSeconds = try r.u32()
    if r.remaining >= 4 {
      receiveErrors = try r.u32()
    } else {
      receiveErrors = nil
    }
  }
}

/// `PUSH_CODE_TRACE_DATA`: per-hop SNR collected by a trace packet.
public struct TraceResult: Hashable, Sendable, Codable {
  public var tag: UInt32
  public var authCode: UInt32
  public var flags: UInt8
  /// One hash per hop (each `hashSize` bytes).
  public var hopHashes: [Data]
  /// SNR (dB) measured by each hop when receiving the trace.
  public var hopSNRs: [Double]
  /// SNR (dB) of the final hop back to this radio.
  public var finalSNR: Double

  public init(tag: UInt32, authCode: UInt32, flags: UInt8, hopHashes: [Data], hopSNRs: [Double], finalSNR: Double) {
    self.tag = tag
    self.authCode = authCode
    self.flags = flags
    self.hopHashes = hopHashes
    self.hopSNRs = hopSNRs
    self.finalSNR = finalSNR
  }

  public var hashSize: Int { 1 << Int(flags & 0x03) }
}

/// `PUSH_CODE_PATH_DISCOVERY_RESPONSE`.
public struct PathDiscoveryResult: Hashable, Sendable, Codable {
  public var nodePrefix: KeyPrefix
  /// Route from this radio to the node.
  public var outPath: MeshPath
  /// Route the response took back to this radio.
  public var inPath: MeshPath

  public init(nodePrefix: KeyPrefix, outPath: MeshPath, inPath: MeshPath) {
    self.nodePrefix = nodePrefix
    self.outPath = outPath
    self.inPath = inPath
  }
}

/// A raw packet heard on air (`PUSH_CODE_LOG_RX_DATA`).
public struct RxLogEntry: Hashable, Sendable, Codable {
  public var snr: Double
  public var rssi: Int8
  public var raw: Data

  public init(snr: Double, rssi: Int8, raw: Data) {
    self.snr = snr
    self.rssi = rssi
    self.raw = raw
  }

  public var header: PacketHeader? {
    raw.first.map(PacketHeader.init(byte:))
  }

  /// Path (repeater hashes) the packet has travelled so far, when decodable.
  public var path: MeshPath? {
    guard let header else { return nil }
    var reader = ByteReader(raw)
    do {
      try reader.skip(1)
      if header.route.hasTransportCodes { try reader.skip(4) }
      let length = PathLength(rawValue: try reader.u8())
      guard length.isValid, !length.isFlood else { return nil }
      return MeshPath(length: length, bytes: try reader.bytes(length.byteCount))
    } catch {
      return nil
    }
  }
}

/// The first byte of every over-the-air packet.
public struct PacketHeader: Hashable, Sendable, Codable {
  public enum Route: UInt8, Hashable, Sendable, Codable {
    case transportFlood = 0
    case flood = 1
    case direct = 2
    case transportDirect = 3

    public var hasTransportCodes: Bool { self == .transportFlood || self == .transportDirect }
    public var isFlood: Bool { self == .flood || self == .transportFlood }
  }

  public enum PayloadType: UInt8, Hashable, Sendable, Codable {
    case request = 0x00
    case response = 0x01
    case textMessage = 0x02
    case ack = 0x03
    case advert = 0x04
    case groupText = 0x05
    case groupData = 0x06
    case anonymousRequest = 0x07
    case path = 0x08
    case trace = 0x09
    case multipart = 0x0A
    case control = 0x0B
    case rawCustom = 0x0F
    case unknown = 0xFF

    public var displayName: String {
      switch self {
      case .request: "REQ"
      case .response: "RESP"
      case .textMessage: "TXT"
      case .ack: "ACK"
      case .advert: "ADVERT"
      case .groupText: "GRP_TXT"
      case .groupData: "GRP_DATA"
      case .anonymousRequest: "ANON_REQ"
      case .path: "PATH"
      case .trace: "TRACE"
      case .multipart: "MULTIPART"
      case .control: "CONTROL"
      case .rawCustom: "RAW"
      case .unknown: "?"
      }
    }
  }

  public var route: Route
  public var payloadType: PayloadType
  public var version: UInt8

  public init(byte: UInt8) {
    route = Route(rawValue: byte & 0x03) ?? .flood
    payloadType = PayloadType(rawValue: (byte >> 2) & 0x0F) ?? .unknown
    version = (byte >> 6) & 0x03
  }
}

/// `PUSH_CODE_CONTROL_DATA` (zero-hop control packets, e.g. node discovery).
public struct ControlData: Hashable, Sendable, Codable {
  public var snr: Double
  public var rssi: Int8
  public var pathLength: UInt8
  public var payload: Data

  public init(snr: Double, rssi: Int8, pathLength: UInt8, payload: Data) {
    self.snr = snr
    self.rssi = rssi
    self.pathLength = pathLength
    self.payload = payload
  }

  /// Decodes a node-discovery response, if this is one.
  public var discoveryResponse: NodeDiscoveryResponse? {
    guard let first = payload.first, first & 0xF0 == ControlType.nodeDiscoverResponse else { return nil }
    var reader = ByteReader(payload)
    do {
      try reader.skip(1)
      let snrIn = Double(try reader.i8()) / 4
      let tag = try reader.u32()
      let key = reader.rest()
      return NodeDiscoveryResponse(
        nodeType: NodeType(byte: first & 0x0F),
        snrIn: snrIn,
        snrOut: snr,
        rssi: rssi,
        tag: tag,
        keyBytes: key.count >= 32 ? key.prefix(32) : key.prefix(8)
      )
    } catch {
      return nil
    }
  }
}

public enum ControlType {
  public static let nodeDiscoverRequest: UInt8 = 0x80
  public static let nodeDiscoverResponse: UInt8 = 0x90
}

public struct NodeDiscoveryResponse: Hashable, Sendable, Codable, Identifiable {
  public var nodeType: NodeType
  /// SNR of our request as heard by the responder.
  public var snrIn: Double
  /// SNR of the response as heard by us.
  public var snrOut: Double
  public var rssi: Int8
  public var tag: UInt32
  /// Either the full 32-byte key or an 8-byte prefix.
  public var keyBytes: Data

  public var id: Data { keyBytes }

  public init(nodeType: NodeType, snrIn: Double, snrOut: Double, rssi: Int8, tag: UInt32, keyBytes: Data) {
    self.nodeType = nodeType
    self.snrIn = snrIn
    self.snrOut = snrOut
    self.rssi = rssi
    self.tag = tag
    self.keyBytes = Data(keyBytes)
  }

  public var publicKey: PublicKey? { PublicKey(keyBytes) }
}

/// Response to a `REQ_TYPE_GET_NEIGHBOURS` binary request.
public struct NeighboursResponse: Hashable, Sendable, Codable {
  public struct Neighbour: Hashable, Sendable, Codable, Identifiable {
    public var keyPrefix: KeyPrefix
    public var secondsAgo: Int32
    public var snr: Double
    public var id: KeyPrefix { keyPrefix }

    public init(keyPrefix: KeyPrefix, secondsAgo: Int32, snr: Double) {
      self.keyPrefix = keyPrefix
      self.secondsAgo = secondsAgo
      self.snr = snr
    }
  }

  public var totalCount: Int
  public var neighbours: [Neighbour]

  public init(totalCount: Int, neighbours: [Neighbour]) {
    self.totalCount = totalCount
    self.neighbours = neighbours
  }

  public init(decoding data: Data, prefixLength: Int) throws {
    var reader = ByteReader(data)
    totalCount = Int(try reader.i16())
    let results = Int(try reader.i16())
    var list: [Neighbour] = []
    for _ in 0..<max(0, results) {
      guard reader.remaining >= prefixLength + 5 else { break }
      let prefix = KeyPrefix(try reader.bytes(prefixLength))
      let secs = try reader.i32()
      let snr = Double(try reader.i8()) / 4
      list.append(Neighbour(keyPrefix: prefix, secondsAgo: secs, snr: snr))
    }
    neighbours = list
  }
}

/// Response to a `REQ_TYPE_GET_ACCESS_LIST` binary request.
public struct AccessListEntry: Hashable, Sendable, Codable, Identifiable {
  public var keyPrefix: KeyPrefix
  public var permissions: UInt8
  public var id: KeyPrefix { keyPrefix }

  public init(keyPrefix: KeyPrefix, permissions: UInt8) {
    self.keyPrefix = keyPrefix
    self.permissions = permissions
  }

  public var roleName: String {
    switch permissions & 0x03 {
    case 3: "Admin"
    case 2: "Read/Write"
    case 1: "Read only"
    default: "Guest"
    }
  }

  public static func decodeList(_ data: Data) -> [AccessListEntry] {
    var reader = ByteReader(data)
    var result: [AccessListEntry] = []
    while reader.remaining >= 7 {
      guard let prefix = try? reader.bytes(6), let perm = try? reader.u8() else { break }
      if prefix.allSatisfy({ $0 == 0 }) { continue }
      result.append(AccessListEntry(keyPrefix: KeyPrefix(prefix), permissions: perm))
    }
    return result
  }
}

/// Binary request types understood by repeaters, room servers and sensors.
public enum BinaryRequestType: UInt8, Hashable, Sendable, Codable {
  case status = 0x01
  case keepAlive = 0x02
  case telemetry = 0x03
  case minMaxAverage = 0x04
  case accessList = 0x05
  case neighbours = 0x06
  case ownerInfo = 0x07
}

public enum NeighbourOrder: UInt8, Hashable, Sendable, Codable, CaseIterable {
  case newestFirst = 0
  case oldestFirst = 1
  case strongestFirst = 2
  case weakestFirst = 3
}

/// Payload builders for `Command.sendBinaryRequest`.
public enum BinaryRequest {
  /// `REQ_TYPE_GET_NEIGHBOURS` (repeaters).
  public static func neighbours(
    count: UInt8 = 255,
    offset: UInt16 = 0,
    order: NeighbourOrder = .newestFirst,
    prefixLength: UInt8 = 6
  ) -> Data {
    var w = ByteWriter(code: BinaryRequestType.neighbours.rawValue)
    w.u8(0) // request version
    w.u8(count)
    w.u16(offset)
    w.u8(order.rawValue)
    w.u8(prefixLength)
    w.u32(UInt32.random(in: 1 ... .max)) // makes the packet hash unique
    return w.data
  }

  /// `REQ_TYPE_GET_ACCESS_LIST` (admin only).
  public static func accessList() -> Data {
    Data([BinaryRequestType.accessList.rawValue, 0, 0])
  }

  /// `REQ_TYPE_GET_STATUS` via the generic binary request path.
  public static func status() -> Data {
    Data([BinaryRequestType.status.rawValue])
  }
}
