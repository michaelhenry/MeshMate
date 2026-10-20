import Foundation

/// A frame received from the radio: either a reply to the current command
/// or an asynchronous push (codes ≥ 0x80).
public enum ResponseFrame: Hashable, Sendable {
  case ok
  case error(DeviceErrorCode?)
  case contactsStart(count: UInt32)
  case contact(Contact)
  case endOfContacts(mostRecentLastModified: UInt32)
  case selfInfo(SelfInfo)
  case sent(SentInfo)
  case contactMessage(ReceivedContactMessage)
  case channelMessage(ReceivedChannelMessage)
  case currentTime(UInt32)
  case noMoreMessages
  case exportedContact(Data)
  case batteryAndStorage(BatteryAndStorage)
  case deviceInfo(DeviceInfo)
  case privateKey(Data)
  case disabled
  case channelInfo(ChannelInfo)
  case signStart(maxLength: UInt32)
  case signature(Data)
  case customVariables([CustomVariable])
  case advertPath(AdvertPath)
  case tuningParameters(TuningParameters)
  case stats(DeviceStats)
  case autoAddConfig(AutoAddConfig)
  case allowedRepeatFrequencies([FrequencyRange])
  case channelData(ReceivedChannelData)
  case defaultFloodScope(FloodScope?)
  case cliReply(String)
  case push(PushEvent)
  case unknown(code: UInt8, payload: Data)

  public enum Code: UInt8, Sendable {
    case ok = 0
    case error = 1
    case contactsStart = 2
    case contact = 3
    case endOfContacts = 4
    case selfInfo = 5
    case sent = 6
    case contactMessage = 7
    case channelMessage = 8
    case currentTime = 9
    case noMoreMessages = 10
    case exportContact = 11
    case batteryAndStorage = 12
    case deviceInfo = 13
    case privateKey = 14
    case disabled = 15
    case contactMessageV3 = 16
    case channelMessageV3 = 17
    case channelInfo = 18
    case signStart = 19
    case signature = 20
    case customVariables = 21
    case advertPath = 22
    case tuningParameters = 23
    case stats = 24
    case autoAddConfig = 25
    case allowedRepeatFrequencies = 26
    case channelDataReceived = 27
    case defaultFloodScope = 28
    case cliReply = 29
  }

  public init(decoding data: Data) throws {
    guard let first = data.first else { throw DecodingError.emptyFrame }
    if first >= 0x80 {
      self = .push(try PushEvent(decoding: data))
      return
    }
    var r = ByteReader(data)
    try r.skip(1)
    guard let code = Code(rawValue: first) else {
      self = .unknown(code: first, payload: r.rest())
      return
    }
    switch code {
    case .ok:
      self = .ok

    case .error:
      self = .error(r.optionalU8().flatMap(DeviceErrorCode.init(rawValue:)))

    case .contactsStart:
      self = .contactsStart(count: try r.u32())

    case .contact:
      self = .contact(try Contact(reading: &r))

    case .endOfContacts:
      self = .endOfContacts(mostRecentLastModified: r.optionalU32() ?? 0)

    case .selfInfo:
      self = .selfInfo(try SelfInfo(reading: &r))

    case .sent:
      let flood = try r.u8() != 0
      let ack = try r.u32()
      let timeout = try r.u32()
      self = .sent(SentInfo(isFlood: flood, expectedAck: ack, timeoutMilliseconds: timeout))

    case .contactMessage:
      self = .contactMessage(try ReceivedContactMessage(reading: &r, snr: nil))

    case .contactMessageV3:
      let snr = Double(try r.i8()) / 4
      try r.skip(2)
      self = .contactMessage(try ReceivedContactMessage(reading: &r, snr: snr))

    case .channelMessage:
      self = .channelMessage(try ReceivedChannelMessage(reading: &r, snr: nil))

    case .channelMessageV3:
      let snr = Double(try r.i8()) / 4
      try r.skip(2)
      self = .channelMessage(try ReceivedChannelMessage(reading: &r, snr: snr))

    case .currentTime:
      self = .currentTime(try r.u32())

    case .noMoreMessages:
      self = .noMoreMessages

    case .exportContact:
      self = .exportedContact(r.rest())

    case .batteryAndStorage:
      let mv = try r.u16()
      if r.remaining >= 8 {
        self = .batteryAndStorage(BatteryAndStorage(batteryMillivolts: mv, storageUsedKB: try r.u32(), storageTotalKB: try r.u32()))
      } else {
        self = .batteryAndStorage(BatteryAndStorage(batteryMillivolts: mv))
      }

    case .deviceInfo:
      self = .deviceInfo(try DeviceInfo(reading: &r))

    case .privateKey:
      self = .privateKey(r.rest())

    case .disabled:
      self = .disabled

    case .channelInfo:
      let index = try r.u8()
      let name = try r.fixedString(32)
      let secret = try r.bytes(ChannelInfo.secretLength)
      self = .channelInfo(ChannelInfo(index: index, name: name, secret: secret))

    case .signStart:
      try r.skip(1)
      self = .signStart(maxLength: try r.u32())

    case .signature:
      self = .signature(r.rest())

    case .customVariables:
      self = .customVariables(CustomVariable.parseList(r.restString()))

    case .advertPath:
      let ts = try r.u32()
      let length = PathLength(rawValue: try r.u8())
      let bytes = try r.bytes(min(length.byteCount, r.remaining))
      self = .advertPath(AdvertPath(receivedTimestamp: ts, path: MeshPath(length: length, bytes: bytes)))

    case .tuningParameters:
      let rx = try r.u32()
      let af = try r.u32()
      self = .tuningParameters(TuningParameters(rxDelayBase: Double(rx) / 1000, airtimeFactor: Double(af) / 1000))

    case .stats:
      self = .stats(try DeviceStats(reading: &r))

    case .autoAddConfig:
      let flags = try r.u8()
      let hops = r.optionalU8() ?? 0
      self = .autoAddConfig(AutoAddConfig(flags: .init(rawValue: flags), maxHops: hops))

    case .allowedRepeatFrequencies:
      var ranges: [FrequencyRange] = []
      while r.remaining >= 8 {
        ranges.append(FrequencyRange(lowerKHz: try r.u32(), upperKHz: try r.u32()))
      }
      self = .allowedRepeatFrequencies(ranges)

    case .channelDataReceived:
      let snr = Double(try r.i8()) / 4
      try r.skip(2)
      let index = try r.u8()
      let pathLength = PathLength(rawValue: try r.u8())
      let dataType = try r.u16()
      let length = Int(try r.u8())
      let payload = try r.bytes(min(length, r.remaining))
      self = .channelData(ReceivedChannelData(channelIndex: index, pathLength: pathLength, dataType: dataType, payload: payload, snr: snr))

    case .defaultFloodScope:
      if r.remaining >= 31 + 16 {
        let name = try r.fixedString(31)
        let key = try r.bytes(16)
        self = .defaultFloodScope(FloodScope(name: name, key: key))
      } else {
        self = .defaultFloodScope(nil)
      }

    case .cliReply:
      self = .cliReply(r.restString())
    }
  }

  /// The firmware error carried by this frame, if it is an error.
  public var deviceError: DeviceErrorCode?? {
    if case let .error(code) = self { return .some(code) }
    return nil
  }
}

// MARK: - Push events

/// Asynchronous notifications the radio sends at any time.
public enum PushEvent: Hashable, Sendable {
  /// A known contact re-advertised.
  case advert(PublicKey)
  case pathUpdated(PublicKey)
  case sendConfirmed(ackCode: UInt32, roundTripMilliseconds: UInt32)
  /// Messages are queued on the radio; call `syncNextMessage`.
  case messageWaiting
  case rawData(snr: Double, rssi: Int8, payload: Data)
  case loginSuccess(LoginResult)
  case loginFailed(KeyPrefix)
  case statusResponse(KeyPrefix, RemoteNodeStatus)
  case logRxData(RxLogEntry)
  case traceData(TraceResult)
  /// An advert from a node not yet in contacts (manual add mode, or newly added).
  case newAdvert(Contact)
  case telemetryResponse(KeyPrefix, [TelemetryReading])
  case binaryResponse(tag: UInt32, data: Data)
  case pathDiscoveryResponse(PathDiscoveryResult)
  case controlData(ControlData)
  case contactDeleted(PublicKey)
  case contactsFull
  case unknown(code: UInt8, payload: Data)

  public enum Code: UInt8, Sendable {
    case advert = 0x80
    case pathUpdated = 0x81
    case sendConfirmed = 0x82
    case messageWaiting = 0x83
    case rawData = 0x84
    case loginSuccess = 0x85
    case loginFailed = 0x86
    case statusResponse = 0x87
    case logRxData = 0x88
    case traceData = 0x89
    case newAdvert = 0x8A
    case telemetryResponse = 0x8B
    case binaryResponse = 0x8C
    case pathDiscoveryResponse = 0x8D
    case controlData = 0x8E
    case contactDeleted = 0x8F
    case contactsFull = 0x90
  }

  public init(decoding data: Data) throws {
    guard let first = data.first else { throw DecodingError.emptyFrame }
    var r = ByteReader(data)
    try r.skip(1)
    guard let code = Code(rawValue: first) else {
      self = .unknown(code: first, payload: r.rest())
      return
    }
    switch code {
    case .advert:
      self = .advert(try r.publicKey())

    case .pathUpdated:
      self = .pathUpdated(try r.publicKey())

    case .sendConfirmed:
      let ack = try r.u32()
      let trip = r.optionalU32() ?? 0
      self = .sendConfirmed(ackCode: ack, roundTripMilliseconds: trip)

    case .messageWaiting:
      self = .messageWaiting

    case .rawData:
      let snr = Double(try r.i8()) / 4
      let rssi = try r.i8()
      try r.skip(1)
      self = .rawData(snr: snr, rssi: rssi, payload: r.rest())

    case .loginSuccess:
      let permissions = try r.u8()
      let prefix = KeyPrefix(try r.bytes(6))
      var result = LoginResult(permissions: permissions, nodePrefix: prefix)
      if r.remaining >= 4 { result.serverTimestamp = try r.u32() }
      if r.remaining >= 1 { result.aclPermissions = try r.u8() }
      if r.remaining >= 1 { result.firmwareLevel = try r.u8() }
      self = .loginSuccess(result)

    case .loginFailed:
      try r.skip(1)
      self = .loginFailed(KeyPrefix(try r.bytes(6)))

    case .statusResponse:
      try r.skip(1)
      let prefix = KeyPrefix(try r.bytes(6))
      self = .statusResponse(prefix, try RemoteNodeStatus(decoding: r.rest()))

    case .logRxData:
      let snr = Double(try r.i8()) / 4
      let rssi = try r.i8()
      self = .logRxData(RxLogEntry(snr: snr, rssi: rssi, raw: r.rest()))

    case .traceData:
      try r.skip(1)
      let pathLength = Int(try r.u8())
      let flags = try r.u8()
      let tag = try r.u32()
      let auth = try r.u32()
      let hashBytes = try r.bytes(pathLength)
      let sizeShift = Int(flags & 0x03)
      let hashSize = 1 << sizeShift
      let hopCount = pathLength >> sizeShift
      var snrs: [Double] = []
      for _ in 0..<hopCount {
        snrs.append(Double(try r.i8()) / 4)
      }
      let finalSNR = Double(r.optionalI8() ?? 0) / 4
      let hashes = stride(from: 0, to: hashBytes.count, by: hashSize).map {
        hashBytes.subdata(in: $0..<min($0 + hashSize, hashBytes.count))
      }
      self = .traceData(TraceResult(tag: tag, authCode: auth, flags: flags, hopHashes: hashes, hopSNRs: snrs, finalSNR: finalSNR))

    case .newAdvert:
      self = .newAdvert(try Contact(reading: &r))

    case .telemetryResponse:
      try r.skip(1)
      let prefix = KeyPrefix(try r.bytes(6))
      self = .telemetryResponse(prefix, CayenneLPP.decode(r.rest()))

    case .binaryResponse:
      try r.skip(1)
      let tag = try r.u32()
      self = .binaryResponse(tag: tag, data: r.rest())

    case .pathDiscoveryResponse:
      try r.skip(1)
      let prefix = KeyPrefix(try r.bytes(6))
      let outLength = PathLength(rawValue: try r.u8())
      let outBytes = try r.bytes(outLength.byteCount)
      let inLength = PathLength(rawValue: try r.u8())
      let inBytes = try r.bytes(inLength.byteCount)
      self = .pathDiscoveryResponse(PathDiscoveryResult(
        nodePrefix: prefix,
        outPath: MeshPath(length: outLength, bytes: outBytes),
        inPath: MeshPath(length: inLength, bytes: inBytes)
      ))

    case .controlData:
      let snr = Double(try r.i8()) / 4
      let rssi = try r.i8()
      let pathLength = try r.u8()
      self = .controlData(ControlData(snr: snr, rssi: rssi, pathLength: pathLength, payload: r.rest()))

    case .contactDeleted:
      self = .contactDeleted(try r.publicKey())

    case .contactsFull:
      self = .contactsFull
    }
  }
}

// MARK: - Struct decoding helpers

extension ByteReader {
  mutating func publicKey() throws -> PublicKey {
    let bytes = try bytes(PublicKey.length)
    guard let key = PublicKey(bytes) else { throw DecodingError.invalidValue("public key") }
    return key
  }
}

extension Contact {
  /// Reads the 147-byte contact record used by `RESP_CODE_CONTACT` and
  /// `PUSH_CODE_NEW_ADVERT` (after the code byte).
  public init(reading r: inout ByteReader) throws {
    let key = try r.publicKey()
    let type = NodeType(byte: try r.u8())
    let flags = try r.u8()
    let pathLength = PathLength(rawValue: try r.u8())
    let pathBytes = try r.bytes(PathLength.maxPathBytes)
    let name = try r.fixedString(Contact.nameWidth)
    let lastAdvert = try r.u32()
    var latitude = 0.0
    var longitude = 0.0
    var lastModified: UInt32 = 0
    if r.remaining >= 8 {
      latitude = Double(try r.i32()) / 1_000_000
      longitude = Double(try r.i32()) / 1_000_000
    }
    if r.remaining >= 4 {
      lastModified = try r.u32()
    }
    self.init(
      publicKey: key,
      type: type,
      flags: flags,
      outPath: pathLength.isValid && !pathLength.isFlood
        ? MeshPath(length: pathLength, bytes: pathBytes)
        : .flood,
      name: name,
      lastAdvert: lastAdvert,
      latitude: latitude,
      longitude: longitude,
      lastModified: lastModified
    )
  }

  /// Encodes the record in the same layout the firmware emits (used by the
  /// demo radio and tests).
  public func encodedRecord() -> Data {
    var w = ByteWriter()
    w.bytes(publicKey.bytes)
    w.u8(type.rawValue)
    w.u8(flags)
    w.u8(outPath.length.rawValue)
    w.fixedBytes(outPath.bytes, width: PathLength.maxPathBytes)
    w.fixedString(name, width: Contact.nameWidth)
    w.u32(lastAdvert)
    w.i32(Int32((latitude * 1_000_000).rounded()))
    w.i32(Int32((longitude * 1_000_000).rounded()))
    w.u32(lastModified)
    return w.data
  }
}

extension SelfInfo {
  init(reading r: inout ByteReader) throws {
    let type = NodeType(byte: try r.u8())
    let txPower = try r.i8()
    let maxTx = try r.i8()
    let key = try r.publicKey()
    let lat = Double(try r.i32()) / 1_000_000
    let lon = Double(try r.i32()) / 1_000_000
    let multiAcks = try r.u8()
    let policy = AdvertLocationPolicy(byte: try r.u8())
    let modes = TelemetryModes(byte: try r.u8())
    let manualAdd = try r.u8()
    let freq = try r.u32()
    let bw = try r.u32()
    let sf = try r.u8()
    let cr = try r.u8()
    let name = r.restString()
    self.init(
      advertType: type,
      txPower: txPower,
      maxTxPower: maxTx,
      publicKey: key,
      latitude: lat,
      longitude: lon,
      multiAcks: multiAcks,
      advertLocationPolicy: policy,
      telemetryModes: modes,
      manualAddContacts: manualAdd,
      radio: RadioParameters(frequencyKHz: freq, bandwidthHz: bw, spreadingFactor: sf, codingRate: cr),
      name: name
    )
  }
}

extension DeviceInfo {
  init(reading r: inout ByteReader) throws {
    let version = try r.u8()
    var info = DeviceInfo(
      firmwareVersionCode: version,
      maxContacts: 0,
      maxChannels: 0,
      blePin: 0,
      firmwareBuildDate: "",
      manufacturer: "",
      firmwareVersion: ""
    )
    if r.remaining >= 2 {
      info.maxContacts = Int(try r.u8()) * 2
      info.maxChannels = Int(try r.u8())
    }
    if r.remaining >= 4 { info.blePin = try r.u32() }
    if r.remaining >= 12 { info.firmwareBuildDate = try r.fixedString(12) }
    if r.remaining >= 40 { info.manufacturer = try r.fixedString(40) }
    if r.remaining >= 20 { info.firmwareVersion = try r.fixedString(20) }
    if r.remaining >= 1 { info.clientRepeat = try r.u8() != 0 }
    if r.remaining >= 1 { info.pathHashMode = try r.u8() }
    self = info
  }
}

extension ReceivedContactMessage {
  init(reading r: inout ByteReader, snr: Double?) throws {
    let prefix = KeyPrefix(try r.bytes(6))
    let pathLength = PathLength(rawValue: try r.u8())
    let type = TextType(byte: try r.u8())
    let timestamp = try r.u32()
    var author: KeyPrefix?
    if type == .signedPlain {
      author = KeyPrefix(try r.bytes(4))
    }
    self.init(
      senderPrefix: prefix,
      pathLength: pathLength,
      textType: type,
      senderTimestamp: timestamp,
      authorPrefix: author,
      text: r.restString(),
      snr: snr
    )
  }
}

extension ReceivedChannelMessage {
  init(reading r: inout ByteReader, snr: Double?) throws {
    let index = try r.u8()
    let pathLength = PathLength(rawValue: try r.u8())
    let type = TextType(byte: try r.u8())
    let timestamp = try r.u32()
    self.init(
      channelIndex: index,
      pathLength: pathLength,
      textType: type,
      senderTimestamp: timestamp,
      text: r.restString(),
      snr: snr
    )
  }
}

extension DeviceStats {
  init(reading r: inout ByteReader) throws {
    let type = try r.u8()
    switch StatsType(rawValue: type) {
    case .core:
      self = .core(CoreStats(
        batteryMillivolts: try r.u16(),
        uptimeSeconds: try r.u32(),
        errorFlags: try r.u16(),
        queueLength: try r.u8()
      ))
    case .radio:
      self = .radio(RadioStats(
        noiseFloor: try r.i16(),
        lastRSSI: try r.i8(),
        lastSNR: Double(try r.i8()) / 4,
        txAirtimeSeconds: try r.u32(),
        rxAirtimeSeconds: try r.u32()
      ))
    case .packets:
      self = .packets(PacketStats(
        received: try r.u32(),
        sent: try r.u32(),
        sentFlood: try r.u32(),
        sentDirect: try r.u32(),
        receivedFlood: try r.u32(),
        receivedDirect: try r.u32(),
        receiveErrors: r.optionalU32() ?? 0
      ))
    case nil:
      throw DecodingError.invalidValue("stats type \(type)")
    }
  }
}
