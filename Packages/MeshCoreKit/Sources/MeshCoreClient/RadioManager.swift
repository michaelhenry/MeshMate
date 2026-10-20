import Foundation
import MeshCoreProtocol

/// Owns the active radio link and its command pipeline. One per process.
actor RadioManager {
  static let shared = RadioManager()

  let pushes = Broadcaster<PushEvent>()
  let connectionEvents = Broadcaster<ConnectionEvent>()

  #if canImport(CoreBluetooth)
  private var _central: BluetoothCentral?
  /// Created lazily so the Bluetooth permission prompt appears only once the
  /// user starts looking for a radio.
  private var central: BluetoothCentral {
    if let _central { return _central }
    let central = BluetoothCentral()
    _central = central
    return central
  }
  #endif

  private var session: Session?

  private struct Session {
    let id: RadioIdentifier
    let link: any RadioLink
    let pipeline: CommandPipeline
    let inbox: AsyncStream<Data>.Continuation
    let pump: Task<Void, Never>
  }

  // MARK: Bluetooth

  func bluetoothState() -> AsyncStream<BluetoothState> {
    #if canImport(CoreBluetooth)
    return central.stateBroadcaster.stream()
    #else
    return AsyncStream { $0.yield(.unsupported); $0.finish() }
    #endif
  }

  func scan() -> AsyncStream<[DiscoveredRadio]> {
    #if canImport(CoreBluetooth)
    return central.scan()
    #else
    return AsyncStream { $0.finish() }
    #endif
  }

  // MARK: Connection

  func connect(_ id: RadioIdentifier) async throws {
    await disconnect()

    // Frames are funnelled through a stream so they reach the pipeline in
    // the exact order they arrived.
    let (inbox, inboxContinuation) = AsyncStream<Data>.makeStream()
    let onFrame: @Sendable (Data) -> Void = { inboxContinuation.yield($0) }
    let onDisconnect: @Sendable (String?) -> Void = { [weak self] reason in
      Task { await self?.linkDropped(id, reason: reason) }
    }

    let link: any RadioLink
    switch id {
    case .demo:
      let radio = DemoRadio(emit: onFrame)
      await radio.start()
      link = radio
    case let .bluetooth(uuid):
      #if canImport(CoreBluetooth)
      link = try await central.connect(to: uuid, onFrame: onFrame, onDisconnect: onDisconnect)
      #else
      throw MeshCoreError.bluetooth(.unsupported)
      #endif
    }

    let pushes = self.pushes
    let pipeline = CommandPipeline(
      write: { try await link.write($0) },
      onPush: { pushes.yield($0) }
    )
    let pump = Task {
      for await frame in inbox {
        await pipeline.receive(frame)
      }
    }
    session = Session(id: id, link: link, pipeline: pipeline, inbox: inboxContinuation, pump: pump)
    connectionEvents.yield(.connected(id))
  }

  func disconnect() async {
    guard let session else { return }
    self.session = nil
    await teardown(session, reason: nil)
  }

  private func linkDropped(_ id: RadioIdentifier, reason: String?) async {
    guard let session, session.id == id else { return }
    self.session = nil
    await teardown(session, reason: reason ?? "Connection lost")
  }

  private func teardown(_ session: Session, reason: String?) async {
    await session.pipeline.close(with: .disconnected)
    session.inbox.finish()
    session.pump.cancel()
    await session.link.close()
    connectionEvents.yield(.disconnected(session.id, reason: reason))
  }

  // MARK: Commands

  func send(_ command: Command) async throws -> [ResponseFrame] {
    guard let session else { throw MeshCoreError.notConnected }
    return try await session.pipeline.send(command)
  }
}
