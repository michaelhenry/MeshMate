import ComposableArchitecture
import Foundation
import MeshCoreProtocol

/// The app's interface to a MeshCore companion radio.
///
/// Features talk to the radio exclusively through this dependency, so every
/// reducer can be tested by overriding just the endpoints it uses.
@DependencyClient
public struct MeshCoreClient: Sendable {
  /// Bluetooth power/authorisation state. Replays the current value.
  public var bluetoothState: @Sendable () async -> AsyncStream<BluetoothState> = { AsyncStream { $0.finish() } }
  /// Radios advertising the MeshCore service. Scanning stops when the
  /// consuming task is cancelled.
  public var scan: @Sendable () async -> AsyncStream<[DiscoveredRadio]> = { AsyncStream { $0.finish() } }
  /// Connects and returns once the link is ready for commands (after any
  /// Bluetooth pairing / PIN entry).
  public var connect: @Sendable (_ radio: RadioIdentifier) async throws -> Void
  public var disconnect: @Sendable () async -> Void
  public var connectionEvents: @Sendable () async -> AsyncStream<ConnectionEvent> = { AsyncStream { $0.finish() } }
  /// Sends a command and returns every frame of its reply (usually one).
  public var send: @Sendable (_ command: Command) async throws -> [ResponseFrame]
  /// Asynchronous events from the radio. Each call creates a new subscriber.
  public var pushes: @Sendable () async -> AsyncStream<PushEvent> = { AsyncStream { $0.finish() } }
}

extension MeshCoreClient: DependencyKey {
  public static let liveValue: MeshCoreClient = {
    let manager = RadioManager.shared
    return MeshCoreClient(
      bluetoothState: { await manager.bluetoothState() },
      scan: { await manager.scan() },
      connect: { try await manager.connect($0) },
      disconnect: { await manager.disconnect() },
      connectionEvents: { await manager.connectionEvents.stream() },
      send: { try await manager.send($0) },
      pushes: { await manager.pushes.stream() }
    )
  }()

  public static let testValue = MeshCoreClient()

  /// Previews run against an in-process demo radio.
  public static let previewValue: MeshCoreClient = liveValue
}

extension DependencyValues {
  public var meshCore: MeshCoreClient {
    get { self[MeshCoreClient.self] }
    set { self[MeshCoreClient.self] = newValue }
  }
}

// MARK: - Typed requests

/// A message pulled from the radio's offline queue.
public enum SyncedMessage: Hashable, Sendable {
  case contact(ReceivedContactMessage)
  case channel(ReceivedChannelMessage)
  case channelData(ReceivedChannelData)
}

extension MeshCoreClient {
  /// Sends `command` and returns its final reply frame, converting firmware
  /// errors into thrown `MeshCoreError`s.
  @discardableResult
  public func request(_ command: Command) async throws -> ResponseFrame {
    let frames = try await send(command)
    guard let last = frames.last else {
      if command.responseExpectation == .none { return .ok }
      throw MeshCoreError.unexpectedResponse("no reply")
    }
    switch last {
    case let .error(code): throw MeshCoreError.device(code)
    case .disabled: throw MeshCoreError.disabled
    default: return last
    }
  }

  /// For commands answered by a plain `OK`.
  public func perform(_ command: Command) async throws {
    let reply = try await request(command)
    guard reply == .ok || command.responseExpectation == .none else {
      throw MeshCoreError.unexpectedResponse("\(reply)")
    }
  }

  public func deviceQuery() async throws -> DeviceInfo {
    guard case let .deviceInfo(info) = try await request(.deviceQuery(appTargetVersion: Command.appProtocolVersion)) else {
      throw MeshCoreError.unexpectedResponse("device info")
    }
    return info
  }

  public func appStart(appName: String) async throws -> SelfInfo {
    guard case let .selfInfo(info) = try await request(.appStart(appName: appName)) else {
      throw MeshCoreError.unexpectedResponse("self info")
    }
    return info
  }

  /// Contacts changed since `since` (all when nil), plus the newest
  /// `lastModified` value to use for the next incremental sync.
  public func contacts(since: UInt32? = nil) async throws -> (contacts: [Contact], mostRecent: UInt32) {
    let frames = try await send(.getContacts(since: since))
    var contacts: [Contact] = []
    var mostRecent: UInt32 = since ?? 0
    for frame in frames {
      switch frame {
      case let .contact(contact): contacts.append(contact)
      case let .endOfContacts(value): mostRecent = max(mostRecent, value)
      case let .error(code): throw MeshCoreError.device(code)
      default: break
      }
    }
    return (contacts, mostRecent)
  }

  public func contact(_ key: PublicKey) async throws -> Contact? {
    do {
      guard case let .contact(contact) = try await request(.getContactByKey(key)) else { return nil }
      return contact
    } catch MeshCoreError.device(.some(.notFound)) {
      return nil
    }
  }

  /// The channel in slot `index`, or nil past the radio's last slot.
  public func channel(_ index: UInt8) async throws -> ChannelInfo? {
    do {
      guard case let .channelInfo(info) = try await request(.getChannel(index)) else { return nil }
      return info
    } catch MeshCoreError.device(.some(.notFound)) {
      return nil
    }
  }

  /// Pops the next queued message, or nil when the queue is empty.
  public func nextMessage() async throws -> SyncedMessage? {
    switch try await request(.syncNextMessage) {
    case let .contactMessage(message): return .contact(message)
    case let .channelMessage(message): return .channel(message)
    case let .channelData(data): return .channelData(data)
    case .noMoreMessages: return nil
    case let other: throw MeshCoreError.unexpectedResponse("\(other)")
    }
  }

  /// Sends any command answered with `RESP_CODE_SENT`.
  public func sendExpectingSent(_ command: Command) async throws -> SentInfo {
    guard case let .sent(info) = try await request(command) else {
      throw MeshCoreError.unexpectedResponse("sent")
    }
    return info
  }

  public func batteryAndStorage() async throws -> BatteryAndStorage {
    guard case let .batteryAndStorage(value) = try await request(.getBatteryAndStorage) else {
      throw MeshCoreError.unexpectedResponse("battery")
    }
    return value
  }

  public func stats(_ type: StatsType) async throws -> DeviceStats {
    guard case let .stats(value) = try await request(.getStats(type)) else {
      throw MeshCoreError.unexpectedResponse("stats")
    }
    return value
  }

  public func deviceTime() async throws -> UInt32 {
    guard case let .currentTime(value) = try await request(.getDeviceTime) else {
      throw MeshCoreError.unexpectedResponse("time")
    }
    return value
  }

  /// Sets the radio clock. The firmware refuses to move its clock backwards,
  /// which is reported as success since the radio is already ahead.
  public func syncTime(_ date: Date) async throws {
    do {
      try await perform(.setDeviceTime(UInt32(date.timeIntervalSince1970)))
    } catch MeshCoreError.device(.some(.illegalArgument)) {
      return
    }
  }

  public func tuningParameters() async throws -> TuningParameters {
    guard case let .tuningParameters(value) = try await request(.getTuningParameters) else {
      throw MeshCoreError.unexpectedResponse("tuning")
    }
    return value
  }

  public func autoAddConfig() async throws -> AutoAddConfig {
    guard case let .autoAddConfig(value) = try await request(.getAutoAddConfig) else {
      throw MeshCoreError.unexpectedResponse("auto-add")
    }
    return value
  }

  public func allowedRepeatFrequencies() async throws -> [FrequencyRange] {
    guard case let .allowedRepeatFrequencies(value) = try await request(.getAllowedRepeatFrequencies) else {
      throw MeshCoreError.unexpectedResponse("repeat frequencies")
    }
    return value
  }

  public func defaultFloodScope() async throws -> FloodScope? {
    guard case let .defaultFloodScope(value) = try await request(.getDefaultFloodScope) else {
      throw MeshCoreError.unexpectedResponse("flood scope")
    }
    return value
  }

  public func customVariables() async throws -> [CustomVariable] {
    guard case let .customVariables(value) = try await request(.getCustomVariables) else {
      throw MeshCoreError.unexpectedResponse("custom vars")
    }
    return value
  }

  public func advertPath(_ key: PublicKey) async throws -> AdvertPath? {
    do {
      guard case let .advertPath(value) = try await request(.getAdvertPath(key)) else { return nil }
      return value
    } catch MeshCoreError.device(.some(.notFound)) {
      return nil
    }
  }

  /// Exports a contact (or this radio when `key` is nil) as a signed advert.
  public func exportContact(_ key: PublicKey?) async throws -> Data {
    guard case let .exportedContact(data) = try await request(.exportContact(key)) else {
      throw MeshCoreError.unexpectedResponse("export")
    }
    return data
  }

  public func exportPrivateKey() async throws -> Data {
    guard case let .privateKey(data) = try await request(.exportPrivateKey) else {
      throw MeshCoreError.unexpectedResponse("private key")
    }
    return data
  }

  public func runCLI(_ command: String) async throws -> String {
    guard case let .cliReply(text) = try await request(.runCLICommand(command)) else {
      throw MeshCoreError.unexpectedResponse("cli")
    }
    return text
  }

  /// This radio's own sensor readings.
  public func selfTelemetry() async throws -> [TelemetryReading] {
    guard case let .push(.telemetryResponse(_, readings)) = try await request(.sendTelemetryRequest(nil)) else {
      throw MeshCoreError.unexpectedResponse("telemetry")
    }
    return readings
  }

  /// Signs arbitrary data with the radio's private key (chunked).
  public func sign(_ data: Data) async throws -> Data {
    guard case let .signStart(maxLength) = try await request(.signStart) else {
      throw MeshCoreError.unexpectedResponse("sign start")
    }
    guard data.count <= Int(maxLength) else { throw MeshCoreError.device(.tableFull) }
    var offset = 0
    let chunk = Command.maxFrameSize - 1
    while offset < data.count {
      let end = min(offset + chunk, data.count)
      try await perform(.signData(data.subdata(in: offset..<end)))
      offset = end
    }
    guard case let .signature(signature) = try await request(.signFinish) else {
      throw MeshCoreError.unexpectedResponse("signature")
    }
    return signature
  }
}
