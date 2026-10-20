#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth central speaking the Nordic UART Service used by MeshCore
/// companion firmware. Each BLE write carries exactly one command frame and
/// each notification exactly one response frame.
///
/// All CoreBluetooth state is confined to `queue`.
final class BluetoothCentral: NSObject, @unchecked Sendable {
  static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  /// App → radio (write).
  static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
  /// Radio → app (notify).
  static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

  private let queue = DispatchQueue(label: "MeshMate.bluetooth", qos: .userInitiated)
  private var central: CBCentralManager!

  let stateBroadcaster = Broadcaster<BluetoothState>(replaysLatest: true)
  private let scanBroadcaster = Broadcaster<[DiscoveredRadio]>()

  // Queue-confined state.
  private var discovered: [UUID: DiscoveredRadio] = [:]
  private var knownPeripherals: [UUID: CBPeripheral] = [:]
  private var scanSubscribers = 0
  private var powerWaiters: [CheckedContinuation<Void, Error>] = []

  private var connection: Connection?

  private final class Connection {
    let peripheral: CBPeripheral
    var rx: CBCharacteristic?
    var tx: CBCharacteristic?
    var connectContinuation: CheckedContinuation<Void, Error>?
    var writeContinuations: [CheckedContinuation<Void, Error>] = []
    var isReady = false
    let onFrame: @Sendable (Data) -> Void
    let onDisconnect: @Sendable (String?) -> Void

    init(peripheral: CBPeripheral, onFrame: @escaping @Sendable (Data) -> Void, onDisconnect: @escaping @Sendable (String?) -> Void) {
      self.peripheral = peripheral
      self.onFrame = onFrame
      self.onDisconnect = onDisconnect
    }
  }

  override init() {
    super.init()
    central = CBCentralManager(
      delegate: self,
      queue: queue,
      options: [CBCentralManagerOptionShowPowerAlertKey: true]
    )
  }

  // MARK: - Scanning

  func scan() -> AsyncStream<[DiscoveredRadio]> {
    let stream = scanBroadcaster.stream()
    queue.async { [self] in
      scanSubscribers += 1
      startScanIfPossible()
      publishDiscovered()
    }
    // Stop scanning when the subscriber goes away.
    return AsyncStream { continuation in
      let task = Task {
        for await radios in stream {
          continuation.yield(radios)
        }
        continuation.finish()
      }
      continuation.onTermination = { [weak self] _ in
        task.cancel()
        self?.queue.async {
          guard let self else { return }
          self.scanSubscribers = max(0, self.scanSubscribers - 1)
          if self.scanSubscribers == 0, self.central.isScanning {
            self.central.stopScan()
          }
        }
      }
    }
  }

  private func startScanIfPossible() {
    guard scanSubscribers > 0, central.state == .poweredOn, !central.isScanning else { return }
    // Radios already connected to iOS don't advertise; list them too.
    for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]) {
      knownPeripherals[peripheral.identifier] = peripheral
      discovered[peripheral.identifier] = DiscoveredRadio(
        id: .bluetooth(peripheral.identifier),
        name: peripheral.name ?? "MeshCore",
        isSystemConnected: true
      )
    }
    central.scanForPeripherals(
      withServices: [Self.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
  }

  private func publishDiscovered() {
    let radios = discovered.values.sorted {
      ($0.rssi ?? -200, $1.name) > ($1.rssi ?? -200, $0.name)
    }
    scanBroadcaster.yield(radios)
  }

  // MARK: - Connecting

  func connect(
    to identifier: UUID,
    onFrame: @escaping @Sendable (Data) -> Void,
    onDisconnect: @escaping @Sendable (String?) -> Void
  ) async throws -> any RadioLink {
    try await waitUntilPoweredOn()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.async { [self] in
          if let existing = connection {
            central.cancelPeripheralConnection(existing.peripheral)
            fail(existing, reason: nil)
          }
          let peripheral = knownPeripherals[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
          guard let peripheral else {
            continuation.resume(throwing: MeshCoreError.peripheralNotFound)
            return
          }
          knownPeripherals[identifier] = peripheral
          let connection = Connection(peripheral: peripheral, onFrame: onFrame, onDisconnect: onDisconnect)
          connection.connectContinuation = continuation
          self.connection = connection
          peripheral.delegate = self
          central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
          ])
        }
      }
    } onCancel: {
      queue.async { [self] in
        guard let connection, !connection.isReady else { return }
        central.cancelPeripheralConnection(connection.peripheral)
        if let continuation = connection.connectContinuation {
          connection.connectContinuation = nil
          continuation.resume(throwing: CancellationError())
        }
        self.connection = nil
      }
    }

    return Link(central: self, identifier: identifier)
  }

  private struct Link: RadioLink {
    let central: BluetoothCentral
    let identifier: UUID

    func write(_ frame: Data) async throws {
      try await central.write(frame, to: identifier)
    }

    func close() async {
      central.disconnect(identifier)
    }
  }

  private func write(_ frame: Data, to identifier: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard let connection, connection.peripheral.identifier == identifier,
              connection.isReady, let rx = connection.rx
        else {
          continuation.resume(throwing: MeshCoreError.notConnected)
          return
        }
        if rx.properties.contains(.write) {
          connection.writeContinuations.append(continuation)
          connection.peripheral.writeValue(frame, for: rx, type: .withResponse)
        } else {
          connection.peripheral.writeValue(frame, for: rx, type: .withoutResponse)
          continuation.resume()
        }
      }
    }
  }

  func disconnect(_ identifier: UUID) {
    queue.async { [self] in
      guard let connection, connection.peripheral.identifier == identifier else { return }
      central.cancelPeripheralConnection(connection.peripheral)
    }
  }

  private func waitUntilPoweredOn() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        switch central.state {
        case .poweredOn:
          continuation.resume()
        case .unknown, .resetting:
          powerWaiters.append(continuation)
        default:
          continuation.resume(throwing: MeshCoreError.bluetooth(Self.map(central.state)))
        }
      }
    }
  }

  /// Fails pending work on `connection` and notifies its owner.
  private func fail(_ connection: Connection, reason: String?) {
    if let continuation = connection.connectContinuation {
      connection.connectContinuation = nil
      continuation.resume(throwing: MeshCoreError.connectionFailed(reason ?? "disconnected"))
    }
    let writes = connection.writeContinuations
    connection.writeContinuations.removeAll()
    writes.forEach { $0.resume(throwing: MeshCoreError.disconnected) }
    if connection.isReady {
      connection.isReady = false
      connection.onDisconnect(reason)
    }
    if self.connection === connection {
      self.connection = nil
    }
  }

  private func finishConnecting(_ connection: Connection) {
    connection.isReady = true
    if let continuation = connection.connectContinuation {
      connection.connectContinuation = nil
      continuation.resume()
    }
  }

  static func map(_ state: CBManagerState) -> BluetoothState {
    switch state {
    case .unknown: .unknown
    case .resetting: .resetting
    case .unsupported: .unsupported
    case .unauthorized: .unauthorized
    case .poweredOff: .poweredOff
    case .poweredOn: .poweredOn
    @unknown default: .unknown
    }
  }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothCentral: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = Self.map(central.state)
    stateBroadcaster.yield(state)

    switch central.state {
    case .poweredOn:
      let waiters = powerWaiters
      powerWaiters.removeAll()
      waiters.forEach { $0.resume() }
      startScanIfPossible()
    case .unknown, .resetting:
      break
    default:
      let waiters = powerWaiters
      powerWaiters.removeAll()
      waiters.forEach { $0.resume(throwing: MeshCoreError.bluetooth(state)) }
      if let connection {
        fail(connection, reason: state.message)
      }
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    knownPeripherals[peripheral.identifier] = peripheral
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
    discovered[peripheral.identifier] = DiscoveredRadio(
      id: .bluetooth(peripheral.identifier),
      name: advertisedName ?? peripheral.name ?? "MeshCore",
      rssi: rssi
    )
    publishDiscovered()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let connection, connection.peripheral === peripheral else { return }
    peripheral.discoverServices([Self.serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard let connection, connection.peripheral === peripheral else { return }
    fail(connection, reason: error?.localizedDescription)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    guard let connection, connection.peripheral === peripheral else { return }
    fail(connection, reason: error?.localizedDescription)
  }
}

// MARK: - CBPeripheralDelegate

extension BluetoothCentral: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let connection, connection.peripheral === peripheral else { return }
    guard error == nil,
          let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
    else {
      central.cancelPeripheralConnection(peripheral)
      if let continuation = connection.connectContinuation {
        connection.connectContinuation = nil
        continuation.resume(throwing: MeshCoreError.serviceNotFound)
      }
      return
    }
    peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let connection, connection.peripheral === peripheral else { return }
    connection.rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
    connection.tx = service.characteristics?.first { $0.uuid == Self.txUUID }
    guard error == nil, connection.rx != nil, let tx = connection.tx else {
      central.cancelPeripheralConnection(peripheral)
      if let continuation = connection.connectContinuation {
        connection.connectContinuation = nil
        continuation.resume(throwing: MeshCoreError.serviceNotFound)
      }
      return
    }
    // Subscribing triggers iOS pairing (PIN entry) on first connection, as
    // the firmware requires an encrypted, MITM-protected link.
    peripheral.setNotifyValue(true, for: tx)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let connection, connection.peripheral === peripheral,
          characteristic.uuid == Self.txUUID
    else { return }
    if let error {
      central.cancelPeripheralConnection(peripheral)
      if let continuation = connection.connectContinuation {
        connection.connectContinuation = nil
        continuation.resume(throwing: MeshCoreError.connectionFailed(
          "\(error.localizedDescription). If you were asked for a PIN, check it on the radio's screen (default 123456)."
        ))
      }
      return
    }
    if characteristic.isNotifying, !connection.isReady {
      finishConnecting(connection)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let connection, connection.peripheral === peripheral,
          characteristic.uuid == Self.txUUID, error == nil,
          let value = characteristic.value, !value.isEmpty
    else { return }
    connection.onFrame(value)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let connection, connection.peripheral === peripheral,
          !connection.writeContinuations.isEmpty
    else { return }
    let continuation = connection.writeContinuations.removeFirst()
    if let error {
      continuation.resume(throwing: MeshCoreError.writeFailed(error.localizedDescription))
    } else {
      continuation.resume()
    }
  }
}
#endif
