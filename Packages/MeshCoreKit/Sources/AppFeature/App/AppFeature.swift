import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Root reducer. Owns the radio connection lifecycle: connecting, the initial
/// sync (device info → identity → clock → contacts → channels → messages),
/// routing push events, storing incoming messages and reconnecting.
@Reducer
struct AppFeature {
  enum Tab: Hashable {
    case chats, contacts, map, settings
  }

  /// Everything fetched from the radio when a connection is established.
  struct SyncSnapshot: Equatable, Sendable {
    var deviceInfo: DeviceInfo
    var selfInfo: SelfInfo
    var contacts: [Contact]
    var channels: [ChannelInfo]
    var battery: BatteryAndStorage?
  }

  @ObservableState
  struct State: Equatable {
    var selectedTab: Tab = .chats
    var chats = ChatsFeature.State()
    var contactsTab = ContactsFeature.State()
    var map = MapFeature.State()
    var settings = SettingsFeature.State()
    @Presents var connection: ConnectionFeature.State?
    var isActive = true
    var isSyncingMessages = false
    var needsAnotherMessageSync = false
    var reconnectAttempt = 0
    /// Set when the user disconnects, so a dropped link isn't re-established.
    var suppressReconnect = false
    @Shared(.radioSession) var session
    @Shared(.contacts) var contacts
    @Shared(.channels) var channels
    @Shared(.messages) var messages
    @Shared(.pendingAdverts) var pendingAdverts
    @Shared(.lastRadio) var lastRadio
    @Shared(.notificationsEnabled) var notificationsEnabled
    @Presents var alert: AlertState<Never>?
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case scenePhaseChanged(isActive: Bool)
    case connectRequested(RadioIdentifier, automatic: Bool)
    case connectFailed(RadioIdentifier, String, automatic: Bool)
    case connectionEvent(ConnectionEvent)
    case syncCompleted(SyncSnapshot)
    case syncFailed(String)
    case syncMessages
    case messageSynced(SyncedMessage)
    case messageSyncFinished
    case push(PushEvent)
    case contactRefreshed(Contact)
    case advertHeard(Contact, isKnown: Bool)
    case reconnectTimerFired
    case showConnectionTapped
    case openURL(URL)
    case connection(PresentationAction<ConnectionFeature.Action>)
    case chats(ChatsFeature.Action)
    case contactsTab(ContactsFeature.Action)
    case map(MapFeature.Action)
    case settings(SettingsFeature.Action)
    case alert(PresentationAction<Never>)
  }

  private enum CancelID {
    case connect
    case sync
    case messageSync
    case reconnect
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.notifications) var notifications
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  var body: some ReducerOf<Self> {
    BindingReducer()
    Scope(state: \.chats, action: \.chats) { ChatsFeature() }
    Scope(state: \.contactsTab, action: \.contactsTab) { ContactsFeature() }
    Scope(state: \.map, action: \.map) { MapFeature() }
    Scope(state: \.settings, action: \.settings) { SettingsFeature() }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      // MARK: Lifecycle

      case .task:
        var effects: [Effect<Action>] = [
          .run { send in
            for await event in await meshCore.connectionEvents() {
              await send(.connectionEvent(event))
            }
          },
          .run { send in
            for await push in await meshCore.pushes() {
              await send(.push(push))
            }
          },
        ]
        // Reset anything left over from a previous launch.
        state.$session.withLock { $0 = RadioSession() }
        if let stored = state.lastRadio, let radio = RadioIdentifier(storageValue: stored) {
          effects.append(.send(.connectRequested(radio, automatic: true)))
        } else {
          state.connection = ConnectionFeature.State()
        }
        if state.notificationsEnabled {
          effects.append(.run { _ in _ = await notifications.requestAuthorization() })
        }
        return .merge(effects)

      case let .scenePhaseChanged(isActive):
        state.isActive = isActive
        guard isActive else { return .none }
        // Coming back to the foreground: reconnect immediately if needed.
        if state.session.status == .disconnected, !state.suppressReconnect,
           let stored = state.lastRadio, let radio = RadioIdentifier(storageValue: stored) {
          state.reconnectAttempt = 0
          return .merge(.cancel(id: CancelID.reconnect), .send(.connectRequested(radio, automatic: true)))
        }
        return state.session.status.isConnected ? .send(.syncMessages) : .none

      // MARK: Connecting

      case .showConnectionTapped:
        state.connection = ConnectionFeature.State()
        return .none

      case let .connection(.presented(.delegate(.connect(radio)))):
        return .send(.connectRequested(radio, automatic: false))

      case let .connectRequested(radio, automatic):
        if state.session.status.radio == radio, state.session.status != .disconnected {
          return .none
        }
        state.suppressReconnect = false
        state.$session.withLock {
          $0.status = .connecting(radio)
          $0.lastError = nil
        }
        return .run { send in
          do {
            try await withThrowingTaskGroup(of: Void.self) { group in
              group.addTask { try await meshCore.connect(radio) }
              group.addTask {
                try await clock.sleep(for: .seconds(automatic ? 20 : 60))
                throw MeshCoreError.timeout
              }
              _ = try await group.next()
              group.cancelAll()
            }
          } catch is CancellationError {
          } catch {
            await send(.connectFailed(radio, error.localizedDescription, automatic: automatic))
          }
        }
        .cancellable(id: CancelID.connect, cancelInFlight: true)

      case let .connectFailed(radio, message, automatic):
        guard state.session.status == .connecting(radio) else { return .none }
        state.$session.withLock {
          $0.status = .disconnected
          $0.lastError = automatic ? nil : message
        }
        return automatic ? scheduleReconnect(&state) : .none

      case let .connectionEvent(.connected(radio)):
        state.$lastRadio.withLock { $0 = radio.storageValue }
        state.$session.withLock { $0.status = .syncing(radio) }
        state.reconnectAttempt = 0
        return .merge(
          .cancel(id: CancelID.reconnect),
          .run { [now] send in
            do {
              await send(.syncCompleted(try await sync(now: now)))
            } catch {
              await send(.syncFailed(error.localizedDescription))
            }
          }
          .cancellable(id: CancelID.sync, cancelInFlight: true)
        )

      case let .connectionEvent(.disconnected(radio, _)):
        state.$session.withLock {
          $0.status = .disconnected
          $0.battery = nil
        }
        state.isSyncingMessages = false
        let effects: Effect<Action> = .merge(.cancel(id: CancelID.sync), .cancel(id: CancelID.messageSync))
        // Reconnect unless the user chose to disconnect from this radio.
        guard !state.suppressReconnect, state.lastRadio == radio.storageValue else { return effects }
        return .merge(effects, scheduleReconnect(&state))

      case .reconnectTimerFired:
        guard state.session.status == .disconnected, !state.suppressReconnect,
              let stored = state.lastRadio, let radio = RadioIdentifier(storageValue: stored)
        else { return .none }
        return .send(.connectRequested(radio, automatic: true))

      // MARK: Initial sync

      case let .syncCompleted(snapshot):
        let radio = state.session.status.radio
        state.$session.withLock {
          $0.deviceInfo = snapshot.deviceInfo
          $0.selfInfo = snapshot.selfInfo
          $0.battery = snapshot.battery
          if let radio { $0.status = .connected(radio) }
        }
        state.$contacts.withLock { $0 = IdentifiedArray(snapshot.contacts, uniquingIDsWith: { _, latest in latest }) }
        state.$channels.withLock { $0 = IdentifiedArray(snapshot.channels, uniquingIDsWith: { _, latest in latest }) }
        state.connection = nil
        return .send(.syncMessages)

      case let .syncFailed(message):
        state.$session.withLock { $0.lastError = message }
        return .run { _ in await meshCore.disconnect() }

      // MARK: Messages

      case .syncMessages:
        guard state.session.status.isLinkUp else { return .none }
        guard !state.isSyncingMessages else {
          state.needsAnotherMessageSync = true
          return .none
        }
        state.isSyncingMessages = true
        state.needsAnotherMessageSync = false
        return .run { send in
          while let message = try await meshCore.nextMessage() {
            await send(.messageSynced(message))
          }
          await send(.messageSyncFinished)
        } catch: { _, send in
          await send(.messageSyncFinished)
        }
        .cancellable(id: CancelID.messageSync)

      case .messageSyncFinished:
        state.isSyncingMessages = false
        if state.needsAnotherMessageSync {
          return .send(.syncMessages)
        }
        return .none

      case let .messageSynced(synced):
        guard let message = chatMessage(from: synced, state: state) else { return .none }
        let recent = state.messages.suffix(500)
        if recent.contains(where: { $0.dedupKey == message.dedupKey }) {
          return .none
        }
        state.$messages.withLock { messages in
          messages.append(message)
          if messages.count > messageHistoryLimit {
            messages = IdentifiedArray(uniqueElements: messages.suffix(messageHistoryLimit))
          }
        }
        return notify(for: message, state: state)

      // MARK: Push events

      case let .push(push):
        switch push {
        case .messageWaiting:
          return .send(.syncMessages)

        case let .sendConfirmed(ack, roundTrip):
          // Late ACKs (after the sender stopped waiting) still count.
          if let message = state.messages.last(where: { $0.expectedAck == ack && $0.isOutgoing }) {
            if case .delivered = message.status { return .none }
            state.$messages.withLock { $0[id: message.id]?.status = .delivered(roundTripMilliseconds: roundTrip) }
          }
          return .none

        case let .advert(key), let .pathUpdated(key):
          return .run { send in
            if let contact = try await meshCore.contact(key) {
              await send(.contactRefreshed(contact))
            }
          }

        case let .newAdvert(contact):
          return .run { send in
            let stored = try? await meshCore.contact(contact.publicKey)
            await send(.advertHeard(stored ?? contact, isKnown: stored != nil))
          }

        case let .contactDeleted(key):
          state.$contacts.withLock { _ = $0.remove(id: key) }
          return .none

        case .contactsFull:
          state.alert = AlertState {
            TextState("Contacts full")
          } message: {
            TextState("The radio's contact table is full, so new nodes can't be added. Remove some contacts, or enable “Overwrite oldest” in Settings › Contacts & Privacy.")
          }
          return .none

        default:
          return .none
        }

      case let .contactRefreshed(contact):
        state.$contacts.withLock { $0[id: contact.publicKey] = contact }
        return .none

      case let .advertHeard(contact, isKnown):
        if isKnown {
          state.$contacts.withLock { $0[id: contact.publicKey] = contact }
          state.$pendingAdverts.withLock { _ = $0.remove(id: contact.publicKey) }
        } else {
          let heardAt = now
          state.$pendingAdverts.withLock { $0[id: contact.publicKey] = PendingAdvert(contact: contact, heardAt: heardAt) }
        }
        return .none

      // MARK: Links

      case let .openURL(url):
        guard let link = MeshCoreLink(string: url.absoluteString) else { return .none }
        switch link {
        case .contact, .advert:
          state.selectedTab = .contacts
          return .send(.contactsTab(.linkScanned(url.absoluteString)))
        case .channel:
          state.selectedTab = .chats
          var add = AddChannelFeature.State()
          add.kind = .join
          add.link = url.absoluteString
          state.chats.destination = .addChannel(add)
          return .none
        }

      // MARK: Cross-tab navigation

      case let .contactsTab(.delegate(.openChat(key))),
           let .map(.delegate(.openChat(key))):
        state.selectedTab = .chats
        state.chats.path.removeAll()
        return .send(.chats(.openChat(.forContact(key))))

      case let .map(.delegate(.openContact(key))):
        state.selectedTab = .contacts
        state.contactsTab.path.removeAll()
        return .send(.contactsTab(.contactTapped(key)))

      case let .chats(.delegate(.showError(message))):
        state.alert = AlertState { TextState("Something went wrong") } message: { TextState(message) }
        return .none

      case let .settings(.delegate(.disconnect(forget))):
        if forget {
          state.$lastRadio.withLock { $0 = nil }
        }
        // A remembered radio reconnects on next launch, or via Settings.
        state.suppressReconnect = true
        state.reconnectAttempt = 0
        return .merge(
          .cancel(id: CancelID.reconnect),
          .cancel(id: CancelID.connect),
          .run { _ in await meshCore.disconnect() }
        )

      case .settings(.delegate(.showConnection)):
        state.connection = ConnectionFeature.State()
        return .none

      case .connection, .chats, .contactsTab, .map, .settings, .alert:
        return .none
      }
    }
    .ifLet(\.$connection, action: \.connection) { ConnectionFeature() }
    .ifLet(\.$alert, action: \.alert)
  }

  // MARK: - Helpers

  /// The connection handshake recommended by the companion protocol.
  private func sync(now: Date) async throws -> SyncSnapshot {
    let deviceInfo = try await meshCore.deviceQuery()
    let selfInfo = try await meshCore.appStart(appName: appName)
    try? await meshCore.syncTime(now)
    let contacts = try await meshCore.contacts().contacts

    var channels: [ChannelInfo] = []
    let slots = deviceInfo.maxChannels > 0 ? min(deviceInfo.maxChannels, 64) : 8
    for index in 0..<slots {
      guard let channel = try await meshCore.channel(UInt8(index)) else { break }
      if !channel.isEmpty { channels.append(channel) }
    }
    let battery = try? await meshCore.batteryAndStorage()
    return SyncSnapshot(deviceInfo: deviceInfo, selfInfo: selfInfo, contacts: contacts, channels: channels, battery: battery)
  }

  private func scheduleReconnect(_ state: inout State) -> Effect<Action> {
    state.reconnectAttempt += 1
    // 2, 4, 8, 16, 30, 30… seconds.
    let delay = min(30, 1 << min(state.reconnectAttempt, 5))
    return .run { send in
      try await clock.sleep(for: .seconds(delay))
      await send(.reconnectTimerFired)
    }
    .cancellable(id: CancelID.reconnect, cancelInFlight: true)
  }

  /// Converts a synced radio message into a stored chat message.
  private func chatMessage(from synced: SyncedMessage, state: State) -> ChatMessage? {
    switch synced {
    case let .contact(message):
      let contact = state.contacts.matching(message.senderPrefix)
      let conversation = contact.map { ConversationID.forContact($0.publicKey) } ?? .contact(message.senderPrefix.hex)
      var senderName: String?
      var authorHex: String?
      if message.textType == .signedPlain, let author = message.authorPrefix {
        authorHex = author.hex
        if let me = state.session.selfInfo, author.matches(me.publicKey) {
          senderName = "You"
        } else {
          senderName = state.contacts.matching(author)?.displayName ?? author.hex
        }
      } else {
        senderName = contact?.displayName
      }
      return ChatMessage(
        id: uuid(),
        conversation: conversation,
        direction: .incoming,
        kind: message.textType == .cliData ? .cli : .text,
        senderName: senderName,
        authorPrefix: authorHex,
        text: message.text,
        timestamp: plausibleDate(message.senderTimestamp),
        status: .received,
        hops: message.pathLength.messageHops,
        snr: message.snr
      )

    case let .channel(message):
      guard let channel = state.channels.first(where: { $0.index == message.channelIndex }) else { return nil }
      return ChatMessage(
        id: uuid(),
        conversation: channel.conversationID,
        direction: .incoming,
        senderName: message.senderName,
        text: message.body,
        timestamp: plausibleDate(message.senderTimestamp),
        status: .received,
        hops: message.pathLength.messageHops,
        snr: message.snr
      )

    case let .channelData(data):
      guard let channel = state.channels.first(where: { $0.index == data.channelIndex }) else { return nil }
      return ChatMessage(
        id: uuid(),
        conversation: channel.conversationID,
        direction: .incoming,
        kind: .data,
        text: "[data 0x\(String(data.dataType, radix: 16)) · \(data.payload.count) bytes] \(data.payload.hexString)",
        timestamp: now,
        status: .received,
        hops: data.pathLength.messageHops,
        snr: data.snr
      )
    }
  }

  /// Sender timestamps come from the sender's clock, which may be unset.
  /// Fall back to the receive time when it's more than a day off.
  private func plausibleDate(_ senderTimestamp: UInt32) -> Date {
    let date = Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
    return abs(date.timeIntervalSince(now)) > 86_400 ? now : date
  }

  private func notify(for message: ChatMessage, state: State) -> Effect<Action> {
    guard state.notificationsEnabled, !state.isActive, message.kind == .text else { return .none }
    let title: String
    switch message.conversation {
    case .contact:
      title = message.senderName ?? "New message"
    case let .channel(secret):
      let channel = state.channels.first { $0.secret.hexString == secret }
      title = "\(message.senderName ?? "Someone") in \(channel?.displayName ?? "channel")"
    }
    let id = message.id.uuidString
    let body = message.text
    let thread = message.conversation.rawValue
    return .run { _ in
      await notifications.post(id, title, body, thread)
    }
  }
}
