import Foundation
import IdentifiedCollections
import MeshCoreClient
import MeshCoreProtocol

/// Identifies a conversation thread.
enum ConversationID: Hashable, Codable, Sendable {
  /// A direct thread, keyed by the contact's full public key (hex). For a
  /// sender not (yet) in contacts this holds the 6-byte prefix instead.
  case contact(String)
  /// A group thread, keyed by the channel secret (hex) so it survives the
  /// channel moving between slots on the radio.
  case channel(String)

  var rawValue: String {
    switch self {
    case let .contact(key): "c:\(key)"
    case let .channel(secret): "g:\(secret)"
    }
  }

  static func forContact(_ key: PublicKey) -> Self { .contact(key.hex) }
  static func forChannel(_ channel: ChannelInfo) -> Self { .channel(channel.secret.hexString) }

  var contactKeyHex: String? {
    if case let .contact(key) = self { return key }
    return nil
  }

  var channelSecretHex: String? {
    if case let .channel(secret) = self { return secret }
    return nil
  }

  /// Whether this thread belongs to the contact identified by `prefix`.
  func matches(_ prefix: KeyPrefix) -> Bool {
    guard let key = contactKeyHex else { return false }
    return key.hasPrefix(prefix.hex) || prefix.hex.hasPrefix(key)
  }
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
  enum Direction: String, Codable, Sendable {
    case incoming
    case outgoing
  }

  enum Kind: String, Codable, Sendable {
    case text
    /// Remote administration traffic with a repeater/room (CLI commands and replies).
    case cli
    /// Binary channel datagram.
    case data
  }

  enum Status: Hashable, Codable, Sendable {
    case received
    case sending
    case sent(flood: Bool)
    case delivered(roundTripMilliseconds: UInt32)
    case failed(String)
  }

  var id: UUID
  var conversation: ConversationID
  var direction: Direction
  var kind: Kind = .text
  /// Channel sender name, or room-server author name.
  var senderName: String?
  /// Room-server author key prefix.
  var authorPrefix: String?
  var text: String
  /// Sender's timestamp for incoming messages; creation time for outgoing.
  var timestamp: Date
  var status: Status
  var expectedAck: UInt32?
  var attempts: Int = 0
  /// Hops travelled (nil when received directly / unknown).
  var hops: Int?
  var snr: Double?

  var isOutgoing: Bool { direction == .outgoing }

  /// Used to drop duplicates (the mesh can deliver a message more than once).
  var dedupKey: String {
    "\(conversation.rawValue)|\(Int(timestamp.timeIntervalSince1970))|\(senderName ?? "")|\(text)"
  }
}

enum ConnectionStatus: Equatable, Sendable {
  case disconnected
  case connecting(RadioIdentifier)
  case syncing(RadioIdentifier)
  case connected(RadioIdentifier)

  var radio: RadioIdentifier? {
    switch self {
    case .disconnected: nil
    case let .connecting(id), let .syncing(id), let .connected(id): id
    }
  }

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  /// Commands can be sent (fully connected or still syncing).
  var isLinkUp: Bool {
    switch self {
    case .connected, .syncing: true
    default: false
    }
  }
}

/// Live information about the connected radio.
struct RadioSession: Equatable, Sendable {
  var status: ConnectionStatus = .disconnected
  var selfInfo: SelfInfo?
  var deviceInfo: DeviceInfo?
  var battery: BatteryAndStorage?
  var lastError: String?

  var nodeName: String { selfInfo?.name ?? "" }

  /// Bytes left for message text on a channel, after the firmware prepends
  /// `"<name>: "`.
  var channelTextLimit: Int {
    max(0, Command.maxTextBytes - nodeName.utf8.count - 2)
  }

  var pathHashSize: Int { Int(deviceInfo?.pathHashMode ?? 0) + 1 }

  func supports(_ protocolVersion: UInt8) -> Bool {
    deviceInfo?.supports(protocolVersion: protocolVersion) ?? false
  }
}

/// A heard advert from a node that isn't in contacts (manual-add mode).
struct PendingAdvert: Identifiable, Hashable, Sendable {
  var contact: Contact
  var heardAt: Date
  var id: PublicKey { contact.publicKey }
}

extension Contact {
  var conversationID: ConversationID { .forContact(publicKey) }

  var lastAdvertDate: Date? {
    lastAdvert == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(lastAdvert))
  }
}

extension IdentifiedArray where Element == Contact, ID == PublicKey {
  func matching(_ prefix: KeyPrefix) -> Contact? {
    first { prefix.matches($0.publicKey) }
  }

  func matching(hex: String) -> Contact? {
    if let key = PublicKey(hex: hex) { return self[id: key] }
    guard let prefix = KeyPrefix(hex: hex) else { return nil }
    return matching(prefix)
  }
}
