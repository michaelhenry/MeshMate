import ComposableArchitecture
import Foundation
import MeshCoreProtocol
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Keychain (repeater / room passwords)

@DependencyClient
struct KeychainClient: Sendable {
  var load: @Sendable (_ account: String) -> String? = { _ in nil }
  var save: @Sendable (_ account: String, _ value: String) -> Void
  var delete: @Sendable (_ account: String) -> Void
}

extension KeychainClient: DependencyKey {
  static let liveValue: KeychainClient = {
    #if canImport(Security)
    let service = "MeshMate.node-passwords"
    func query(_ account: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
    }
    return KeychainClient(
      load: { account in
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
      },
      save: { account, value in
        let q = query(account)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
      },
      delete: { account in
        SecItemDelete(query(account) as CFDictionary)
      }
    )
    #else
    return KeychainClient()
    #endif
  }()

  static let testValue = KeychainClient()

  static let previewValue = KeychainClient(load: { _ in nil }, save: { _, _ in }, delete: { _ in })
}

// MARK: - Local notifications

@DependencyClient
struct NotificationClient: Sendable {
  var requestAuthorization: @Sendable () async -> Bool = { false }
  var post: @Sendable (_ id: String, _ title: String, _ body: String, _ threadID: String) async -> Void
}

extension NotificationClient: DependencyKey {
  static let liveValue: NotificationClient = {
    #if canImport(UserNotifications)
    return NotificationClient(
      requestAuthorization: {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      },
      post: { id, title, body, thread in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
      }
    )
    #else
    return NotificationClient(requestAuthorization: { false }, post: { _, _, _, _ in })
    #endif
  }()

  static let testValue = NotificationClient()
  static let previewValue = NotificationClient(requestAuthorization: { true }, post: { _, _, _, _ in })
}

// MARK: - Location (for setting the advert position)

struct Coordinate: Equatable, Sendable {
  var latitude: Double
  var longitude: Double
}

@DependencyClient
struct LocationClient: Sendable {
  var currentLocation: @Sendable () async throws -> Coordinate
}

extension LocationClient: DependencyKey {
  static let liveValue: LocationClient = {
    #if canImport(CoreLocation)
    return LocationClient(currentLocation: {
      try await OneShotLocation().fetch()
    })
    #else
    return LocationClient()
    #endif
  }()

  static let testValue = LocationClient()
  static let previewValue = LocationClient(currentLocation: { Coordinate(latitude: -37.8136, longitude: 144.9631) })
}

#if canImport(CoreLocation)
private final class OneShotLocation: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  private var manager: CLLocationManager?
  private var continuation: CheckedContinuation<Coordinate, Error>?

  struct Denied: LocalizedError {
    var errorDescription: String? { "Location access is off for MeshMate. Enable it in Settings to use your current position." }
  }

  @MainActor
  func fetch() async throws -> Coordinate {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let manager = CLLocationManager()
      manager.delegate = self
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      self.manager = manager
      switch manager.authorizationStatus {
      case .notDetermined:
        manager.requestWhenInUseAuthorization()
      case .denied, .restricted:
        finish(.failure(Denied()))
      default:
        manager.requestLocation()
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      manager.requestLocation()
    case .denied, .restricted:
      finish(.failure(Denied()))
    default:
      break
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    finish(.success(Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Coordinate, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
    manager?.delegate = nil
    manager = nil
  }
}
#endif

// MARK: - Radio presets

@DependencyClient
struct PresetsClient: Sendable {
  var fetch: @Sendable () async throws -> [RadioPreset]
}

extension PresetsClient: DependencyKey {
  static let liveValue = PresetsClient(fetch: {
    var request = URLRequest(url: URL(string: "https://api.meshcore.nz/api/v1/config")!)
    request.setValue("MeshMate-iOS/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10
    let (data, _) = try await URLSession.shared.data(for: request)
    return RadioPreset.parseAPIResponse(data) ?? RadioPreset.builtIn
  })

  static let testValue = PresetsClient()
  static let previewValue = PresetsClient(fetch: { RadioPreset.builtIn })
}

extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }

  var notifications: NotificationClient {
    get { self[NotificationClient.self] }
    set { self[NotificationClient.self] = newValue }
  }

  var location: LocationClient {
    get { self[LocationClient.self] }
    set { self[LocationClient.self] = newValue }
  }

  var presets: PresetsClient {
    get { self[PresetsClient.self] }
    set { self[PresetsClient.self] = newValue }
  }
}
