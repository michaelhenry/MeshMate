import ComposableArchitecture
import Foundation
import MeshCoreProtocol

// Live state about the connected radio (not persisted).
extension SharedReaderKey where Self == InMemoryKey<RadioSession>.Default {
  static var radioSession: Self {
    Self[.inMemory("radioSession"), default: RadioSession()]
  }
}

// Adverts heard from nodes not in contacts.
extension SharedReaderKey where Self == InMemoryKey<IdentifiedArrayOf<PendingAdvert>>.Default {
  static var pendingAdverts: Self {
    Self[.inMemory("pendingAdverts"), default: []]
  }
}

// Contacts, channels and message history are cached on disk so the app is
// usable (read-only) while the radio is out of range.
extension SharedReaderKey where Self == FileStorageKey<IdentifiedArrayOf<Contact>>.Default {
  static var contacts: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "contacts.json")), default: []]
  }
}

extension SharedReaderKey where Self == FileStorageKey<IdentifiedArrayOf<ChannelInfo>>.Default {
  static var channels: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "channels.json")), default: []]
  }
}

extension SharedReaderKey where Self == FileStorageKey<IdentifiedArrayOf<ChatMessage>>.Default {
  static var messages: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "messages.json")), default: []]
  }
}

/// Last time each conversation was viewed, keyed by `ConversationID.rawValue`.
extension SharedReaderKey where Self == FileStorageKey<[String: Date]>.Default {
  static var lastRead: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "last-read.json")), default: [:]]
  }
}

/// The radio to reconnect to automatically.
extension SharedReaderKey where Self == AppStorageKey<String?> {
  static var lastRadio: Self { .appStorage("lastRadioID") }
}

extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  static var notificationsEnabled: Self {
    Self[.appStorage("notificationsEnabled"), default: true]
  }
}

/// Maximum number of messages kept on device.
let messageHistoryLimit = 10_000
