import Foundation

// MARK: - Identity

/// A 32-byte Ed25519 public key identifying a mesh node.
public struct PublicKey: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let length = 32

  public let bytes: Data

  public init?(_ bytes: Data) {
    guard bytes.count == Self.length else { return nil }
    self.bytes = Data(bytes)
  }

  public init?(hex: String) {
    guard let data = Data(hexString: hex) else { return nil }
    self.init(data)
  }

  public var hex: String { bytes.hexString }

  /// The leading bytes of the key. MeshCore commonly identifies nodes by a
  /// 6-byte prefix in message frames, and by a 1-3 byte hash in paths.
  public func prefix(_ count: Int = 6) -> KeyPrefix {
    KeyPrefix(bytes.prefix(count))
  }

  public var description: String { hex }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let hex = try container.decode(String.self)
    guard let key = PublicKey(hex: hex) else {
      throw Swift.DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid public key hex"
      )
    }
    self = key
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }
}

/// A truncated public key, as used in message and response frames.
public struct KeyPrefix: Hashable, Sendable, Codable, CustomStringConvertible {
  public let bytes: Data

  public init(_ bytes: Data) {
    self.bytes = Data(bytes)
  }

  public init?(hex: String) {
    guard let data = Data(hexString: hex) else { return nil }
    self.init(data)
  }

  public var hex: String { bytes.hexString }
  public var description: String { hex }

  /// Whether this prefix identifies the given key.
  public func matches(_ key: PublicKey) -> Bool {
    !bytes.isEmpty && key.bytes.starts(with: bytes)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let hex = try container.decode(String.self)
    guard let data = Data(hexString: hex) else {
      throw Swift.DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid hex")
    }
    self.init(data)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }
}

/// The advertised role of a node.
public enum NodeType: UInt8, Sendable, Codable, CaseIterable, Hashable {
  case none = 0
  case chat = 1
  case repeater = 2
  case room = 3
  case sensor = 4

  public init(byte: UInt8) {
    self = NodeType(rawValue: byte) ?? .none
  }

  public var displayName: String {
    switch self {
    case .none: "Unknown"
    case .chat: "Companion"
    case .repeater: "Repeater"
    case .room: "Room Server"
    case .sensor: "Sensor"
    }
  }

  /// Nodes that accept an admin/guest login.
  public var supportsLogin: Bool {
    self == .repeater || self == .room || self == .sensor
  }
}

// MARK: - Paths

/// The encoded path-length byte used throughout the protocol.
///
/// The low 6 bits hold the hop count and the top 2 bits the per-hop hash size
/// minus one (1, 2 or 3 bytes). `0xFF` means "unknown / use flood routing".
public struct PathLength: Hashable, Sendable, Codable {
  public static let flood = PathLength(rawValue: 0xFF)
  public static let maxPathBytes = 64

  public var rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public init(hashSize: Int, hopCount: Int) {
    let size = UInt8(max(1, min(3, hashSize)) - 1)
    self.rawValue = size << 6 | UInt8(max(0, min(63, hopCount)))
  }

  public var isFlood: Bool { rawValue == 0xFF }
  public var hashSize: Int { Int(rawValue >> 6) + 1 }
  public var hopCount: Int { isFlood ? 0 : Int(rawValue & 63) }
  public var byteCount: Int { isFlood ? 0 : hopCount * hashSize }
  public var isValid: Bool { isFlood || (hashSize != 4 && byteCount <= Self.maxPathBytes) }
}

/// A route through repeaters, expressed as a list of per-hop key hashes.
public struct MeshPath: Hashable, Sendable, Codable {
  public var length: PathLength
  /// Raw hash bytes (`length.byteCount` bytes).
  public var bytes: Data

  public init(length: PathLength, bytes: Data) {
    self.length = length
    self.bytes = Data(bytes.prefix(length.byteCount))
  }

  public static let flood = MeshPath(length: .flood, bytes: Data())

  public var isFlood: Bool { length.isFlood }

  /// The hop hashes, one `Data` per hop.
  public var hops: [Data] {
    guard !isFlood, length.hashSize > 0 else { return [] }
    let size = length.hashSize
    return stride(from: 0, to: bytes.count, by: size).map {
      bytes.subdata(in: $0..<min($0 + size, bytes.count))
    }
  }

  /// e.g. `a1 → 3f → 07`, or `Flood`, or `Direct` for a zero-hop path.
  public var displayString: String {
    if isFlood { return "Flood" }
    if hops.isEmpty { return "Direct (0 hops)" }
    return hops.map(\.hexString).joined(separator: " → ")
  }

  /// Parses a user-entered path such as `a1,3f,07` or `a13f 07c2`.
  public init?(hopString: String) {
    let parts = hopString
      .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ">" || $0 == "→" })
      .map(String.init)
      .filter { !$0.isEmpty }
    guard !parts.isEmpty else {
      self.init(length: PathLength(hashSize: 1, hopCount: 0), bytes: Data())
      return
    }
    let decoded = parts.compactMap { Data(hexString: $0) }
    guard decoded.count == parts.count,
          let size = decoded.first?.count, (1...3).contains(size),
          decoded.allSatisfy({ $0.count == size }),
          decoded.count * size <= PathLength.maxPathBytes
    else { return nil }
    self.init(
      length: PathLength(hashSize: size, hopCount: decoded.count),
      bytes: decoded.reduce(into: Data()) { $0.append($1) }
    )
  }
}

// MARK: - Contacts

public struct Contact: Hashable, Sendable, Codable, Identifiable {
  public static let nameWidth = 32

  public var publicKey: PublicKey
  public var type: NodeType
  /// Bit 0 is "favourite". Bits 1-3 grant telemetry permissions
  /// (base / location / environment) to this contact.
  public var flags: UInt8
  public var outPath: MeshPath
  public var name: String
  public var lastAdvert: UInt32
  public var latitude: Double
  public var longitude: Double
  public var lastModified: UInt32

  public var id: PublicKey { publicKey }

  public init(
    publicKey: PublicKey,
    type: NodeType,
    flags: UInt8 = 0,
    outPath: MeshPath = .flood,
    name: String,
    lastAdvert: UInt32 = 0,
    latitude: Double = 0,
    longitude: Double = 0,
    lastModified: UInt32 = 0
  ) {
    self.publicKey = publicKey
    self.type = type
    self.flags = flags
    self.outPath = outPath
    self.name = name
    self.lastAdvert = lastAdvert
    self.latitude = latitude
    self.longitude = longitude
    self.lastModified = lastModified
  }

  public var isFavourite: Bool {
    get { flags & 0x01 != 0 }
    set { flags = newValue ? flags | 0x01 : flags & ~0x01 }
  }

  public var telemetryPermissions: TelemetryPermissions {
    get { TelemetryPermissions(rawValue: (flags >> 1) & 0x07) }
    set { flags = (flags & 0x01) | (newValue.rawValue & 0x07) << 1 }
  }

  public var hasLocation: Bool { latitude != 0 || longitude != 0 }

  public var displayName: String {
    name.isEmpty ? publicKey.prefix(4).hex : name
  }
}

/// Telemetry categories a contact is allowed to request from this node.
public struct TelemetryPermissions: OptionSet, Hashable, Sendable, Codable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let base = TelemetryPermissions(rawValue: 1 << 0)
  public static let location = TelemetryPermissions(rawValue: 1 << 1)
  public static let environment = TelemetryPermissions(rawValue: 1 << 2)
}

// MARK: - Device

/// Reply to `APP_START`: the radio's own identity and current settings.
public struct SelfInfo: Hashable, Sendable, Codable {
  public var advertType: NodeType
  public var txPower: Int8
  public var maxTxPower: Int8
  public var publicKey: PublicKey
  public var latitude: Double
  public var longitude: Double
  public var multiAcks: UInt8
  public var advertLocationPolicy: AdvertLocationPolicy
  public var telemetryModes: TelemetryModes
  public var manualAddContacts: UInt8
  public var radio: RadioParameters
  public var name: String

  public init(
    advertType: NodeType = .chat,
    txPower: Int8,
    maxTxPower: Int8,
    publicKey: PublicKey,
    latitude: Double = 0,
    longitude: Double = 0,
    multiAcks: UInt8 = 0,
    advertLocationPolicy: AdvertLocationPolicy = .none,
    telemetryModes: TelemetryModes = TelemetryModes(),
    manualAddContacts: UInt8 = 0,
    radio: RadioParameters,
    name: String
  ) {
    self.advertType = advertType
    self.txPower = txPower
    self.maxTxPower = maxTxPower
    self.publicKey = publicKey
    self.latitude = latitude
    self.longitude = longitude
    self.multiAcks = multiAcks
    self.advertLocationPolicy = advertLocationPolicy
    self.telemetryModes = telemetryModes
    self.manualAddContacts = manualAddContacts
    self.radio = radio
    self.name = name
  }

  /// When set, new adverts are not added to contacts automatically
  /// (subject to `AutoAddConfig`).
  public var isManualContactAdd: Bool { manualAddContacts & 0x01 != 0 }
}

public enum AdvertLocationPolicy: UInt8, Hashable, Sendable, Codable, CaseIterable {
  case none = 0
  case share = 1
  case preferences = 2

  public init(byte: UInt8) { self = Self(rawValue: byte) ?? .none }
}

/// Who may request telemetry from this node, per category.
public enum TelemetryMode: UInt8, Hashable, Sendable, Codable, CaseIterable {
  case deny = 0
  case allowFlagged = 1
  case allowAll = 2

  public init(bits: UInt8) { self = Self(rawValue: bits & 0x03) ?? .deny }

  public var displayName: String {
    switch self {
    case .deny: "Nobody"
    case .allowFlagged: "Allowed contacts"
    case .allowAll: "Everyone"
    }
  }
}

public struct TelemetryModes: Hashable, Sendable, Codable {
  public var base: TelemetryMode
  public var location: TelemetryMode
  public var environment: TelemetryMode

  public init(base: TelemetryMode = .deny, location: TelemetryMode = .deny, environment: TelemetryMode = .deny) {
    self.base = base
    self.location = location
    self.environment = environment
  }

  public init(byte: UInt8) {
    base = TelemetryMode(bits: byte)
    location = TelemetryMode(bits: byte >> 2)
    environment = TelemetryMode(bits: byte >> 4)
  }

  public var byte: UInt8 {
    environment.rawValue << 4 | location.rawValue << 2 | base.rawValue
  }
}

/// LoRa modulation parameters.
public struct RadioParameters: Hashable, Sendable, Codable {
  /// Centre frequency in kHz (e.g. 915_800 for 915.8 MHz).
  public var frequencyKHz: UInt32
  /// Bandwidth in Hz (e.g. 250_000 for 250 kHz).
  public var bandwidthHz: UInt32
  public var spreadingFactor: UInt8
  public var codingRate: UInt8

  public init(frequencyKHz: UInt32, bandwidthHz: UInt32, spreadingFactor: UInt8, codingRate: UInt8) {
    self.frequencyKHz = frequencyKHz
    self.bandwidthHz = bandwidthHz
    self.spreadingFactor = spreadingFactor
    self.codingRate = codingRate
  }

  public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: UInt8, codingRate: UInt8) {
    self.init(
      frequencyKHz: UInt32((frequencyMHz * 1000).rounded()),
      bandwidthHz: UInt32((bandwidthKHz * 1000).rounded()),
      spreadingFactor: spreadingFactor,
      codingRate: codingRate
    )
  }

  public var frequencyMHz: Double { Double(frequencyKHz) / 1000 }
  public var bandwidthKHz: Double { Double(bandwidthHz) / 1000 }

  public var isValid: Bool {
    (150_000...2_500_000).contains(frequencyKHz)
      && (7_000...500_000).contains(bandwidthHz)
      && (5...12).contains(spreadingFactor)
      && (5...8).contains(codingRate)
  }

  public var summary: String {
    String(
      format: "%.3f MHz · BW %g kHz · SF%d · CR%d",
      frequencyMHz, bandwidthKHz, Int(spreadingFactor), Int(codingRate)
    )
  }
}

/// Reply to `DEVICE_QUERY`.
public struct DeviceInfo: Hashable, Sendable, Codable {
  public var firmwareVersionCode: UInt8
  public var maxContacts: Int
  public var maxChannels: Int
  public var blePin: UInt32
  public var firmwareBuildDate: String
  public var manufacturer: String
  public var firmwareVersion: String
  /// Client repeat mode (firmware protocol v9+).
  public var clientRepeat: Bool
  /// 0 = 1-byte, 1 = 2-byte, 2 = 3-byte path hashes (protocol v10+).
  public var pathHashMode: UInt8

  public init(
    firmwareVersionCode: UInt8,
    maxContacts: Int,
    maxChannels: Int,
    blePin: UInt32,
    firmwareBuildDate: String,
    manufacturer: String,
    firmwareVersion: String,
    clientRepeat: Bool = false,
    pathHashMode: UInt8 = 0
  ) {
    self.firmwareVersionCode = firmwareVersionCode
    self.maxContacts = maxContacts
    self.maxChannels = maxChannels
    self.blePin = blePin
    self.firmwareBuildDate = firmwareBuildDate
    self.manufacturer = manufacturer
    self.firmwareVersion = firmwareVersion
    self.clientRepeat = clientRepeat
    self.pathHashMode = pathHashMode
  }

  /// Whether the radio supports a command introduced in protocol `version`.
  public func supports(protocolVersion version: UInt8) -> Bool {
    firmwareVersionCode >= version
  }
}

public struct BatteryAndStorage: Hashable, Sendable, Codable {
  public var batteryMillivolts: UInt16
  public var storageUsedKB: UInt32?
  public var storageTotalKB: UInt32?

  public init(batteryMillivolts: UInt16, storageUsedKB: UInt32? = nil, storageTotalKB: UInt32? = nil) {
    self.batteryMillivolts = batteryMillivolts
    self.storageUsedKB = storageUsedKB
    self.storageTotalKB = storageTotalKB
  }

  /// Rough single-cell Li-ion state of charge.
  public var estimatedPercent: Int {
    let volts = Double(batteryMillivolts) / 1000
    let percent = (volts - 3.3) / (4.15 - 3.3) * 100
    return Int(max(0, min(100, percent)).rounded())
  }
}

// MARK: - Channels

public struct ChannelInfo: Hashable, Sendable, Codable, Identifiable {
  public static let secretLength = 16
  /// The well-known key of the default "Public" channel.
  public static let publicSecret = Data(hexString: "8b3387e9c5cdea6ac9e5edbaa115cd72")!

  public var index: UInt8
  public var name: String
  public var secret: Data

  public var id: UInt8 { index }

  public init(index: UInt8, name: String, secret: Data) {
    self.index = index
    self.name = name
    self.secret = secret
  }

  /// An unused slot has an empty name and an all-zero secret.
  public var isEmpty: Bool {
    name.isEmpty && secret.allSatisfy { $0 == 0 }
  }

  public var isPublic: Bool { secret == Self.publicSecret }
  public var isHashtag: Bool { name.hasPrefix("#") }
}

// MARK: - Sending

/// `RESP_CODE_SENT`: the radio queued a message or request for transmission.
public struct SentInfo: Hashable, Sendable, Codable {
  public var isFlood: Bool
  /// The expected ACK code (for text messages) or request tag (for requests).
  public var expectedAck: UInt32
  /// Firmware's suggested time to wait for the ACK / response.
  public var timeoutMilliseconds: UInt32

  public init(isFlood: Bool, expectedAck: UInt32, timeoutMilliseconds: UInt32) {
    self.isFlood = isFlood
    self.expectedAck = expectedAck
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}

public enum TextType: UInt8, Hashable, Sendable, Codable {
  case plain = 0
  case cliData = 1
  case signedPlain = 2
  case cliCommand = 3

  public init(byte: UInt8) { self = Self(rawValue: byte) ?? .plain }
}

// MARK: - Received messages

/// A direct message (or room server post / CLI reply) received from a contact.
public struct ReceivedContactMessage: Hashable, Sendable, Codable {
  public var senderPrefix: KeyPrefix
  /// Hop count when received via flood, nil when received directly.
  public var pathLength: PathLength
  public var textType: TextType
  public var senderTimestamp: UInt32
  /// For signed (room server) messages: the original author's 4-byte key prefix.
  public var authorPrefix: KeyPrefix?
  public var text: String
  /// Signal-to-noise ratio in dB (v3 frames only).
  public var snr: Double?

  public init(
    senderPrefix: KeyPrefix,
    pathLength: PathLength,
    textType: TextType,
    senderTimestamp: UInt32,
    authorPrefix: KeyPrefix? = nil,
    text: String,
    snr: Double? = nil
  ) {
    self.senderPrefix = senderPrefix
    self.pathLength = pathLength
    self.textType = textType
    self.senderTimestamp = senderTimestamp
    self.authorPrefix = authorPrefix
    self.text = text
    self.snr = snr
  }
}

/// A group text received on one of the radio's channels.
public struct ReceivedChannelMessage: Hashable, Sendable, Codable {
  public var channelIndex: UInt8
  public var pathLength: PathLength
  public var textType: TextType
  public var senderTimestamp: UInt32
  /// Raw text, which MeshCore formats as `"<sender name>: <message>"`.
  public var text: String
  public var snr: Double?

  public init(
    channelIndex: UInt8,
    pathLength: PathLength,
    textType: TextType = .plain,
    senderTimestamp: UInt32,
    text: String,
    snr: Double? = nil
  ) {
    self.channelIndex = channelIndex
    self.pathLength = pathLength
    self.textType = textType
    self.senderTimestamp = senderTimestamp
    self.text = text
    self.snr = snr
  }

  /// The sender's advertised name, split from the message body.
  public var senderName: String? { Self.split(text).sender }
  public var body: String { Self.split(text).body }

  static func split(_ text: String) -> (sender: String?, body: String) {
    guard let range = text.range(of: ": ") else { return (nil, text) }
    let sender = String(text[..<range.lowerBound])
    guard !sender.isEmpty, sender.count <= 32 else { return (nil, text) }
    return (sender, String(text[range.upperBound...]))
  }
}

/// A binary datagram received on a channel (protocol v13+).
public struct ReceivedChannelData: Hashable, Sendable, Codable {
  public var channelIndex: UInt8
  public var pathLength: PathLength
  public var dataType: UInt16
  public var payload: Data
  public var snr: Double

  public init(channelIndex: UInt8, pathLength: PathLength, dataType: UInt16, payload: Data, snr: Double) {
    self.channelIndex = channelIndex
    self.pathLength = pathLength
    self.dataType = dataType
    self.payload = payload
    self.snr = snr
  }
}

// MARK: - Misc responses

public struct AdvertPath: Hashable, Sendable, Codable {
  public var receivedTimestamp: UInt32
  public var path: MeshPath

  public init(receivedTimestamp: UInt32, path: MeshPath) {
    self.receivedTimestamp = receivedTimestamp
    self.path = path
  }
}

public struct TuningParameters: Hashable, Sendable, Codable {
  public var rxDelayBase: Double
  public var airtimeFactor: Double

  public init(rxDelayBase: Double, airtimeFactor: Double) {
    self.rxDelayBase = rxDelayBase
    self.airtimeFactor = airtimeFactor
  }
}

public struct AutoAddConfig: Hashable, Sendable, Codable {
  public struct Flags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let overwriteOldest = Flags(rawValue: 1 << 0)
    public static let chat = Flags(rawValue: 1 << 1)
    public static let repeater = Flags(rawValue: 1 << 2)
    public static let roomServer = Flags(rawValue: 1 << 3)
    public static let sensor = Flags(rawValue: 1 << 4)
  }

  public var flags: Flags
  /// 0 = no limit.
  public var maxHops: UInt8

  public init(flags: Flags, maxHops: UInt8) {
    self.flags = flags
    self.maxHops = maxHops
  }
}

public struct FrequencyRange: Hashable, Sendable, Codable {
  public var lowerKHz: UInt32
  public var upperKHz: UInt32

  public init(lowerKHz: UInt32, upperKHz: UInt32) {
    self.lowerKHz = lowerKHz
    self.upperKHz = upperKHz
  }

  public func contains(_ kHz: UInt32) -> Bool { (lowerKHz...upperKHz).contains(kHz) }
}

public struct FloodScope: Hashable, Sendable, Codable {
  public var name: String
  public var key: Data

  public init(name: String, key: Data) {
    self.name = name
    self.key = key
  }
}

public struct CustomVariable: Hashable, Sendable, Codable, Identifiable {
  public var name: String
  public var value: String
  public var id: String { name }

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }

  /// Parses the `name:value,name:value` format.
  public static func parseList(_ text: String) -> [CustomVariable] {
    text.split(separator: ",").compactMap { pair in
      guard let colon = pair.firstIndex(of: ":") else { return nil }
      let afterColon = pair.index(after: colon)
      return CustomVariable(
        name: String(pair[pair.startIndex..<colon]),
        value: String(pair[afterColon..<pair.endIndex])
      )
    }
  }
}

public enum StatsType: UInt8, Hashable, Sendable, Codable, CaseIterable {
  case core = 0
  case radio = 1
  case packets = 2
}

public enum DeviceStats: Hashable, Sendable, Codable {
  case core(CoreStats)
  case radio(RadioStats)
  case packets(PacketStats)
}

public struct CoreStats: Hashable, Sendable, Codable {
  public var batteryMillivolts: UInt16
  public var uptimeSeconds: UInt32
  public var errorFlags: UInt16
  public var queueLength: UInt8

  public init(batteryMillivolts: UInt16, uptimeSeconds: UInt32, errorFlags: UInt16, queueLength: UInt8) {
    self.batteryMillivolts = batteryMillivolts
    self.uptimeSeconds = uptimeSeconds
    self.errorFlags = errorFlags
    self.queueLength = queueLength
  }
}

public struct RadioStats: Hashable, Sendable, Codable {
  public var noiseFloor: Int16
  public var lastRSSI: Int8
  public var lastSNR: Double
  public var txAirtimeSeconds: UInt32
  public var rxAirtimeSeconds: UInt32

  public init(noiseFloor: Int16, lastRSSI: Int8, lastSNR: Double, txAirtimeSeconds: UInt32, rxAirtimeSeconds: UInt32) {
    self.noiseFloor = noiseFloor
    self.lastRSSI = lastRSSI
    self.lastSNR = lastSNR
    self.txAirtimeSeconds = txAirtimeSeconds
    self.rxAirtimeSeconds = rxAirtimeSeconds
  }
}

public struct PacketStats: Hashable, Sendable, Codable {
  public var received: UInt32
  public var sent: UInt32
  public var sentFlood: UInt32
  public var sentDirect: UInt32
  public var receivedFlood: UInt32
  public var receivedDirect: UInt32
  public var receiveErrors: UInt32

  public init(
    received: UInt32, sent: UInt32, sentFlood: UInt32, sentDirect: UInt32,
    receivedFlood: UInt32, receivedDirect: UInt32, receiveErrors: UInt32
  ) {
    self.received = received
    self.sent = sent
    self.sentFlood = sentFlood
    self.sentDirect = sentDirect
    self.receivedFlood = receivedFlood
    self.receivedDirect = receivedDirect
    self.receiveErrors = receiveErrors
  }
}

/// Firmware error codes carried by `RESP_CODE_ERR`.
public enum DeviceErrorCode: UInt8, Hashable, Sendable, Codable {
  case unsupportedCommand = 1
  case notFound = 2
  case tableFull = 3
  case badState = 4
  case fileIOError = 5
  case illegalArgument = 6

  public var message: String {
    switch self {
    case .unsupportedCommand: "The radio doesn't support this command."
    case .notFound: "Not found on the radio."
    case .tableFull: "The radio's table is full or busy. Try again shortly."
    case .badState: "The radio is busy with another operation."
    case .fileIOError: "The radio couldn't read or write its storage."
    case .illegalArgument: "The radio rejected the value."
    }
  }
}
