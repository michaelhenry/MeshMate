import Foundation
import MeshCoreProtocol

/// Identifies a radio the app can connect to.
public enum RadioIdentifier: Hashable, Sendable, Codable {
  case bluetooth(UUID)
  /// A simulated radio that runs entirely inside the app (useful in the
  /// Simulator, which has no Bluetooth).
  case demo

  public var storageValue: String {
    switch self {
    case let .bluetooth(uuid): uuid.uuidString
    case .demo: "demo"
    }
  }

  public init?(storageValue: String) {
    if storageValue == "demo" {
      self = .demo
    } else if let uuid = UUID(uuidString: storageValue) {
      self = .bluetooth(uuid)
    } else {
      return nil
    }
  }
}

/// A radio found while scanning.
public struct DiscoveredRadio: Hashable, Sendable, Identifiable {
  public var id: RadioIdentifier
  public var name: String
  public var rssi: Int?
  /// Already connected to iOS (e.g. by another app).
  public var isSystemConnected: Bool

  public init(id: RadioIdentifier, name: String, rssi: Int? = nil, isSystemConnected: Bool = false) {
    self.id = id
    self.name = name
    self.rssi = rssi
    self.isSystemConnected = isSystemConnected
  }

  public static let demo = DiscoveredRadio(id: .demo, name: "Demo Radio (simulated)")
}

public enum BluetoothState: Hashable, Sendable {
  case unknown
  case resetting
  case unsupported
  case unauthorized
  case poweredOff
  case poweredOn

  public var isUsable: Bool { self == .poweredOn }

  public var message: String {
    switch self {
    case .unknown, .resetting: "Starting Bluetooth…"
    case .unsupported: "This device doesn't support Bluetooth Low Energy."
    case .unauthorized: "Bluetooth access is off for MeshMate. Enable it in Settings › Privacy & Security › Bluetooth."
    case .poweredOff: "Bluetooth is turned off."
    case .poweredOn: "Bluetooth is on."
    }
  }
}

public enum ConnectionEvent: Hashable, Sendable {
  case connected(RadioIdentifier)
  case disconnected(RadioIdentifier, reason: String?)
}

public enum MeshCoreError: Error, Equatable, Sendable, LocalizedError {
  case notConnected
  case disconnected
  case timeout
  case bluetooth(BluetoothState)
  case peripheralNotFound
  case serviceNotFound
  case connectionFailed(String)
  case writeFailed(String)
  case device(DeviceErrorCode?)
  case disabled
  case unexpectedResponse(String)

  public var errorDescription: String? {
    switch self {
    case .notConnected: "No radio is connected."
    case .disconnected: "The radio disconnected."
    case .timeout: "The radio didn't respond in time."
    case let .bluetooth(state): state.message
    case .peripheralNotFound: "The radio couldn't be found. Make sure it's powered on and nearby."
    case .serviceNotFound: "This device doesn't look like a MeshCore companion radio. Flash the Companion (BLE) firmware."
    case let .connectionFailed(reason): "Couldn't connect: \(reason)"
    case let .writeFailed(reason): "Couldn't send to the radio: \(reason)"
    case let .device(code): code?.message ?? "The radio reported an error."
    case .disabled: "This feature is disabled in the radio firmware."
    case let .unexpectedResponse(detail): "Unexpected reply from the radio (\(detail))."
    }
  }
}
