import Foundation

/// Every command the companion radio firmware accepts (protocol v14 /
/// firmware 1.18). Encoding mirrors `MyMesh::handleCmdFrame` exactly.
public enum Command: Hashable, Sendable {
  case appStart(appName: String)
  case sendTextMessage(type: TextType, attempt: UInt8, timestamp: UInt32, recipient: KeyPrefix, text: String)
  case sendChannelTextMessage(channelIndex: UInt8, timestamp: UInt32, text: String)
  case getContacts(since: UInt32?)
  case getDeviceTime
  case setDeviceTime(UInt32)
  case sendSelfAdvert(flood: Bool)
  case setAdvertName(String)
  case addUpdateContact(Contact)
  case syncNextMessage
  case setRadioParameters(RadioParameters, clientRepeat: Bool?)
  case setTxPower(Int8)
  case resetPath(PublicKey)
  case setAdvertLocation(latitude: Double, longitude: Double)
  case removeContact(PublicKey)
  case shareContact(PublicKey)
  /// `nil` exports this radio's own advert.
  case exportContact(PublicKey?)
  case importContact(Data)
  case reboot
  case getBatteryAndStorage
  case setTuningParameters(TuningParameters)
  case deviceQuery(appTargetVersion: UInt8)
  case exportPrivateKey
  case importPrivateKey(Data)
  case sendRawData(path: MeshPath, payload: Data)
  case sendLogin(PublicKey, password: String)
  case sendStatusRequest(PublicKey)
  case hasConnection(PublicKey)
  case logout(PublicKey)
  case getContactByKey(PublicKey)
  case getChannel(UInt8)
  case setChannel(ChannelInfo)
  case signStart
  case signData(Data)
  case signFinish
  case sendTracePath(tag: UInt32, authCode: UInt32, flags: UInt8, path: Data)
  case setDevicePin(UInt32)
  case setOtherParameters(manualAddContacts: UInt8, telemetryModes: TelemetryModes, advertLocationPolicy: AdvertLocationPolicy, multiAcks: UInt8)
  /// `nil` requests this radio's own telemetry.
  case sendTelemetryRequest(PublicKey?)
  case getCustomVariables
  case setCustomVariable(name: String, value: String)
  case getAdvertPath(PublicKey)
  case getTuningParameters
  case sendBinaryRequest(PublicKey, data: Data)
  case factoryReset
  case sendPathDiscoveryRequest(PublicKey)
  /// `nil` clears the override; `.some(nil-key)` isn't representable – use `setUnscopedFlood`.
  case setFloodScopeKey(Data?)
  case setUnscopedFlood
  case sendControlData(Data)
  case getStats(StatsType)
  case sendAnonymousRequest(PublicKey, data: Data)
  case setAutoAddConfig(AutoAddConfig)
  case getAutoAddConfig
  case getAllowedRepeatFrequencies
  case setPathHashMode(UInt8)
  case sendChannelData(channelIndex: UInt8, path: MeshPath, dataType: UInt16, payload: Data)
  case setDefaultFloodScope(FloodScope?)
  case getDefaultFloodScope
  case sendRawPacket(priority: UInt8, packet: Data)
  case runCLICommand(String)

  public enum Code: UInt8, Sendable {
    case appStart = 1
    case sendTextMessage = 2
    case sendChannelTextMessage = 3
    case getContacts = 4
    case getDeviceTime = 5
    case setDeviceTime = 6
    case sendSelfAdvert = 7
    case setAdvertName = 8
    case addUpdateContact = 9
    case syncNextMessage = 10
    case setRadioParameters = 11
    case setTxPower = 12
    case resetPath = 13
    case setAdvertLocation = 14
    case removeContact = 15
    case shareContact = 16
    case exportContact = 17
    case importContact = 18
    case reboot = 19
    case getBatteryAndStorage = 20
    case setTuningParameters = 21
    case deviceQuery = 22
    case exportPrivateKey = 23
    case importPrivateKey = 24
    case sendRawData = 25
    case sendLogin = 26
    case sendStatusRequest = 27
    case hasConnection = 28
    case logout = 29
    case getContactByKey = 30
    case getChannel = 31
    case setChannel = 32
    case signStart = 33
    case signData = 34
    case signFinish = 35
    case sendTracePath = 36
    case setDevicePin = 37
    case setOtherParameters = 38
    case sendTelemetryRequest = 39
    case getCustomVariables = 40
    case setCustomVariable = 41
    case getAdvertPath = 42
    case getTuningParameters = 43
    case sendBinaryRequest = 50
    case factoryReset = 51
    case sendPathDiscoveryRequest = 52
    case setFloodScopeKey = 54
    case sendControlData = 55
    case getStats = 56
    case sendAnonymousRequest = 57
    case setAutoAddConfig = 58
    case getAutoAddConfig = 59
    case getAllowedRepeatFrequencies = 60
    case setPathHashMode = 61
    case sendChannelData = 62
    case setDefaultFloodScope = 63
    case getDefaultFloodScope = 64
    case sendRawPacket = 65
    case runCLICommand = 66
  }

  /// Largest frame the firmware accepts.
  public static let maxFrameSize = 176
  /// Maximum UTF-8 bytes of message text (10 cipher blocks).
  public static let maxTextBytes = 160
  /// The app protocol version we speak; ≥ 3 enables SNR in message frames.
  public static let appProtocolVersion: UInt8 = 3

  public var code: Code {
    switch self {
    case .appStart: .appStart
    case .sendTextMessage: .sendTextMessage
    case .sendChannelTextMessage: .sendChannelTextMessage
    case .getContacts: .getContacts
    case .getDeviceTime: .getDeviceTime
    case .setDeviceTime: .setDeviceTime
    case .sendSelfAdvert: .sendSelfAdvert
    case .setAdvertName: .setAdvertName
    case .addUpdateContact: .addUpdateContact
    case .syncNextMessage: .syncNextMessage
    case .setRadioParameters: .setRadioParameters
    case .setTxPower: .setTxPower
    case .resetPath: .resetPath
    case .setAdvertLocation: .setAdvertLocation
    case .removeContact: .removeContact
    case .shareContact: .shareContact
    case .exportContact: .exportContact
    case .importContact: .importContact
    case .reboot: .reboot
    case .getBatteryAndStorage: .getBatteryAndStorage
    case .setTuningParameters: .setTuningParameters
    case .deviceQuery: .deviceQuery
    case .exportPrivateKey: .exportPrivateKey
    case .importPrivateKey: .importPrivateKey
    case .sendRawData: .sendRawData
    case .sendLogin: .sendLogin
    case .sendStatusRequest: .sendStatusRequest
    case .hasConnection: .hasConnection
    case .logout: .logout
    case .getContactByKey: .getContactByKey
    case .getChannel: .getChannel
    case .setChannel: .setChannel
    case .signStart: .signStart
    case .signData: .signData
    case .signFinish: .signFinish
    case .sendTracePath: .sendTracePath
    case .setDevicePin: .setDevicePin
    case .setOtherParameters: .setOtherParameters
    case .sendTelemetryRequest: .sendTelemetryRequest
    case .getCustomVariables: .getCustomVariables
    case .setCustomVariable: .setCustomVariable
    case .getAdvertPath: .getAdvertPath
    case .getTuningParameters: .getTuningParameters
    case .sendBinaryRequest: .sendBinaryRequest
    case .factoryReset: .factoryReset
    case .sendPathDiscoveryRequest: .sendPathDiscoveryRequest
    case .setFloodScopeKey, .setUnscopedFlood: .setFloodScopeKey
    case .sendControlData: .sendControlData
    case .getStats: .getStats
    case .sendAnonymousRequest: .sendAnonymousRequest
    case .setAutoAddConfig: .setAutoAddConfig
    case .getAutoAddConfig: .getAutoAddConfig
    case .getAllowedRepeatFrequencies: .getAllowedRepeatFrequencies
    case .setPathHashMode: .setPathHashMode
    case .sendChannelData: .sendChannelData
    case .setDefaultFloodScope: .setDefaultFloodScope
    case .getDefaultFloodScope: .getDefaultFloodScope
    case .sendRawPacket: .sendRawPacket
    case .runCLICommand: .runCLICommand
    }
  }

  /// The wire representation of this command.
  public func encoded() -> Data {
    var w = ByteWriter(code: code.rawValue)
    switch self {
    case let .appStart(appName):
      // byte 1: app version, bytes 2...7 reserved, then the app name.
      w.u8(Self.appProtocolVersion)
      w.bytes([UInt8](repeating: 0x20, count: 6))
      w.string(appName)

    case let .sendTextMessage(type, attempt, timestamp, recipient, text):
      w.u8(type.rawValue)
      w.u8(attempt)
      w.u32(timestamp)
      w.fixedBytes(recipient.bytes, width: 6)
      w.string(text.utf8Truncated(toByteCount: Self.maxTextBytes))

    case let .sendChannelTextMessage(channelIndex, timestamp, text):
      w.u8(TextType.plain.rawValue)
      w.u8(channelIndex)
      w.u32(timestamp)
      w.string(text.utf8Truncated(toByteCount: Self.maxTextBytes))

    case let .getContacts(since):
      if let since { w.u32(since) }

    case .getDeviceTime, .syncNextMessage, .getBatteryAndStorage, .exportPrivateKey,
         .signStart, .signFinish, .getCustomVariables, .getTuningParameters,
         .getAutoAddConfig, .getAllowedRepeatFrequencies, .getDefaultFloodScope:
      break

    case let .setDeviceTime(seconds):
      w.u32(seconds)

    case let .sendSelfAdvert(flood):
      w.u8(flood ? 1 : 0)

    case let .setAdvertName(name):
      w.string(name.utf8Truncated(toByteCount: Contact.nameWidth - 1))

    case let .addUpdateContact(contact):
      w.bytes(contact.publicKey.bytes)
      w.u8(contact.type.rawValue)
      w.u8(contact.flags)
      w.u8(contact.outPath.length.rawValue)
      w.fixedBytes(contact.outPath.bytes, width: PathLength.maxPathBytes)
      w.fixedString(contact.name, width: Contact.nameWidth)
      w.u32(contact.lastAdvert)
      w.i32(Int32((contact.latitude * 1_000_000).rounded()))
      w.i32(Int32((contact.longitude * 1_000_000).rounded()))

    case let .setRadioParameters(radio, clientRepeat):
      w.u32(radio.frequencyKHz)
      w.u32(radio.bandwidthHz)
      w.u8(radio.spreadingFactor)
      w.u8(radio.codingRate)
      if let clientRepeat { w.u8(clientRepeat ? 1 : 0) }

    case let .setTxPower(power):
      w.i8(power)

    case let .resetPath(key), let .removeContact(key), let .shareContact(key),
         let .hasConnection(key), let .logout(key), let .getContactByKey(key),
         let .sendStatusRequest(key):
      w.bytes(key.bytes)

    case let .setAdvertLocation(latitude, longitude):
      w.i32(Int32((latitude * 1_000_000).rounded()))
      w.i32(Int32((longitude * 1_000_000).rounded()))

    case let .exportContact(key):
      if let key { w.bytes(key.bytes) }

    case let .importContact(data):
      w.bytes(data)

    case .reboot:
      w.string("reboot")

    case let .setTuningParameters(tuning):
      w.u32(UInt32(max(0, tuning.rxDelayBase * 1000).rounded()))
      w.u32(UInt32(max(0, tuning.airtimeFactor * 1000).rounded()))

    case let .deviceQuery(version):
      w.u8(version)

    case let .importPrivateKey(key):
      w.fixedBytes(key, width: 64)

    case let .sendRawData(path, payload):
      w.u8(path.length.rawValue)
      w.bytes(path.bytes)
      w.bytes(payload)

    case let .sendLogin(key, password):
      w.bytes(key.bytes)
      w.string(password.utf8Truncated(toByteCount: 15))

    case let .getChannel(index):
      w.u8(index)

    case let .setChannel(channel):
      w.u8(channel.index)
      w.fixedString(channel.name, width: 32)
      w.fixedBytes(channel.secret, width: ChannelInfo.secretLength)

    case let .signData(chunk):
      w.bytes(chunk)

    case let .sendTracePath(tag, authCode, flags, path):
      w.u32(tag)
      w.u32(authCode)
      w.u8(flags)
      w.bytes(path)

    case let .setDevicePin(pin):
      w.u32(pin)

    case let .setOtherParameters(manualAdd, modes, policy, multiAcks):
      w.u8(manualAdd)
      w.u8(modes.byte)
      w.u8(policy.rawValue)
      w.u8(multiAcks)

    case let .sendTelemetryRequest(key):
      w.bytes([0, 0, 0]) // reserved
      if let key { w.bytes(key.bytes) }

    case let .setCustomVariable(name, value):
      w.string("\(name):\(value)")

    case let .getAdvertPath(key):
      w.u8(0) // reserved
      w.bytes(key.bytes)

    case let .sendBinaryRequest(key, data), let .sendAnonymousRequest(key, data):
      w.bytes(key.bytes)
      w.bytes(data)

    case .factoryReset:
      w.string("reset")

    case let .sendPathDiscoveryRequest(key):
      w.u8(0) // reserved
      w.bytes(key.bytes)

    case let .setFloodScopeKey(key):
      w.u8(0)
      if let key { w.fixedBytes(key, width: 16) }

    case .setUnscopedFlood:
      w.u8(1)

    case let .sendControlData(data):
      w.bytes(data)

    case let .getStats(type):
      w.u8(type.rawValue)

    case let .setAutoAddConfig(config):
      w.u8(config.flags.rawValue)
      w.u8(config.maxHops)

    case let .setPathHashMode(mode):
      w.u8(0) // sub-command
      w.u8(mode)

    case let .sendChannelData(channelIndex, path, dataType, payload):
      w.u8(channelIndex)
      w.u8(path.length.rawValue)
      if !path.isFlood { w.bytes(path.bytes) }
      w.u16(dataType)
      w.bytes(payload)

    case let .setDefaultFloodScope(scope):
      if let scope {
        w.fixedString(scope.name, width: 31)
        w.fixedBytes(scope.key, width: 16)
      }

    case let .sendRawPacket(priority, packet):
      w.u8(priority)
      w.bytes(packet)

    case let .runCLICommand(text):
      w.string(text)
    }
    return w.data
  }

  /// How the pipeline should wait for this command's reply.
  public var responseExpectation: ResponseExpectation {
    switch self {
    case .reboot:
      return .none
    case .factoryReset:
      // The firmware disables the link before replying and reboots.
      return .none
    case .getContacts:
      return .multiple
    default:
      return .single
    }
  }

  /// Whether `frame` completes this command's exchange.
  public func isTerminal(_ frame: ResponseFrame) -> Bool {
    switch self {
    case .getContacts:
      switch frame {
      case .endOfContacts, .error: return true
      default: return false
      }
    default:
      return true
    }
  }

  /// Whether `frame` can plausibly be a reply to this command. Used to drop
  /// stragglers from an earlier command that timed out, so they aren't
  /// mistaken for the reply to the next one.
  public func isPlausibleReply(_ frame: ResponseFrame) -> Bool {
    switch frame {
    case .ok, .error, .disabled, .unknown:
      return true
    case .contactsStart, .endOfContacts:
      if case .getContacts = self { return true }
      return false
    case .contact:
      switch self {
      case .getContacts, .getContactByKey: return true
      default: return false
      }
    case .selfInfo:
      if case .appStart = self { return true }
      return false
    case .deviceInfo:
      if case .deviceQuery = self { return true }
      return false
    case .sent:
      switch self {
      case .sendTextMessage, .sendLogin, .sendStatusRequest, .sendTelemetryRequest,
           .sendBinaryRequest, .sendAnonymousRequest, .sendPathDiscoveryRequest, .sendTracePath:
        return true
      default:
        return false
      }
    case .contactMessage, .channelMessage, .channelData, .noMoreMessages:
      if case .syncNextMessage = self { return true }
      return false
    case .currentTime:
      if case .getDeviceTime = self { return true }
      return false
    case .exportedContact:
      if case .exportContact = self { return true }
      return false
    case .batteryAndStorage:
      if case .getBatteryAndStorage = self { return true }
      return false
    case .privateKey:
      if case .exportPrivateKey = self { return true }
      return false
    case .channelInfo:
      if case .getChannel = self { return true }
      return false
    case .signStart:
      if case .signStart = self { return true }
      return false
    case .signature:
      if case .signFinish = self { return true }
      return false
    case .customVariables:
      if case .getCustomVariables = self { return true }
      return false
    case .advertPath:
      if case .getAdvertPath = self { return true }
      return false
    case .tuningParameters:
      if case .getTuningParameters = self { return true }
      return false
    case .stats:
      if case .getStats = self { return true }
      return false
    case .autoAddConfig:
      if case .getAutoAddConfig = self { return true }
      return false
    case .allowedRepeatFrequencies:
      if case .getAllowedRepeatFrequencies = self { return true }
      return false
    case .defaultFloodScope:
      if case .getDefaultFloodScope = self { return true }
      return false
    case .cliReply:
      if case .runCLICommand = self { return true }
      return false
    case .push:
      return false
    }
  }

  /// Whether a push frame is actually this command's reply. Requesting this
  /// radio's own telemetry is answered with `PUSH_CODE_TELEMETRY_RESPONSE`.
  public func acceptsAsReply(_ push: PushEvent) -> Bool {
    if case .sendTelemetryRequest(nil) = self, case .telemetryResponse = push {
      return true
    }
    return false
  }

  /// Suggested time to wait for the reply.
  public var timeout: Duration {
    switch self {
    case .getContacts: .seconds(60)
    case .signFinish, .importPrivateKey: .seconds(15)
    case .setRadioParameters: .seconds(10)
    default: .seconds(6)
    }
  }
}

public enum ResponseExpectation: Sendable {
  case none
  case single
  case multiple
}
