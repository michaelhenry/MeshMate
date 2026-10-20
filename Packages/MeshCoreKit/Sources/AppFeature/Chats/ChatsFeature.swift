import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// The conversation list and its navigation stack. It also owns delivery of
/// outgoing direct messages, so retries continue after leaving a chat.
@Reducer
struct ChatsFeature {
  @Reducer
  enum Path {
    case chat(ChatFeature)
    case contactDetail(ContactDetailFeature)
    case remoteNode(RemoteNodeFeature)
  }

  @Reducer
  enum Destination {
    case addChannel(AddChannelFeature)
  }

  struct Summary: Equatable, Identifiable {
    var id: ConversationID
    var title: String
    var preview: String
    var date: Date?
    var unread: Int
    var nodeType: NodeType? = nil
    var channel: ChannelInfo? = nil
    var isFavourite: Bool
  }

  @ObservableState
  struct State: Equatable {
    var path = StackState<Path.State>()
    @Presents var destination: Destination.State?
    var isPickingContact = false
    var searchText = ""
    @Shared(.messages) var messages
    @Shared(.contacts) var contacts
    @Shared(.channels) var channels
    @Shared(.lastRead) var lastRead
    @Shared(.radioSession) var session

    var summaries: [Summary] {
      var latest: [ConversationID: ChatMessage] = [:]
      var unread: [ConversationID: Int] = [:]
      for message in messages where message.kind != .cli {
        if let current = latest[message.conversation], current.timestamp > message.timestamp {
          // keep current
        } else {
          latest[message.conversation] = message
        }
        if !message.isOutgoing {
          let readAt = lastRead[message.conversation.rawValue] ?? .distantPast
          if message.timestamp > readAt { unread[message.conversation, default: 0] += 1 }
        }
      }

      var result: [Summary] = channels.map { channel in
        let id = channel.conversationID
        let last = latest.removeValue(forKey: id)
        return Summary(
          id: id,
          title: channel.displayName,
          preview: last.map(Self.preview) ?? channel.kindLabel + " channel",
          date: last?.timestamp,
          unread: unread[id] ?? 0,
          channel: channel,
          isFavourite: false
        )
      }
      for (id, last) in latest {
        let contact = id.contactKeyHex.flatMap { contacts.matching(hex: $0) }
        if id.channelSecretHex != nil { continue } // channel since removed
        result.append(Summary(
          id: id,
          title: contact?.displayName ?? Format.shortKey(id.contactKeyHex ?? ""),
          preview: Self.preview(last),
          date: last.timestamp,
          unread: unread[id] ?? 0,
          nodeType: contact?.type ?? NodeType.none,
          isFavourite: contact?.isFavourite ?? false
        ))
      }
      if !searchText.isEmpty {
        result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.preview.localizedCaseInsensitiveContains(searchText) }
      }
      return result.sorted {
        switch ($0.date, $1.date) {
        case let (lhs?, rhs?): lhs > rhs
        case (.some, .none): true
        case (.none, .some): false
        case (.none, .none): $0.title < $1.title
        }
      }
    }

    var totalUnread: Int { summaries.reduce(0) { $0 + $1.unread } }

    static func preview(_ message: ChatMessage) -> String {
      let prefix = message.isOutgoing ? "You: " : (message.senderName.map { "\($0): " } ?? "")
      return prefix + message.text
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case path(StackActionOf<Path>)
    case destination(PresentationAction<Destination.Action>)
    case conversationTapped(ConversationID)
    case newMessageTapped
    case contactPicked(PublicKey)
    case addChannelTapped
    case removeChannelTapped(ChannelInfo)
    case channelRemoved(ChannelInfo)
    case clearConversationTapped(ConversationID)
    case markAllReadTapped
    case openChat(ConversationID)
    case outbox(Outbox)
    case removeFailed(String)
    case delegate(Delegate)

    @CasePathable
    enum Outbox {
      case deliver(ChatMessage.ID)
      case attempt(ChatMessage.ID, Int)
      case sent(ChatMessage.ID, SentInfo)
      case delivered(ChatMessage.ID, roundTrip: UInt32)
      case failed(ChatMessage.ID, String)
    }

    enum Delegate {
      case showError(String)
    }
  }

  private enum CancelID: Hashable {
    case delivery(ChatMessage.ID)
  }

  static let maxAttempts = 3

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case let .conversationTapped(id), let .openChat(id):
        state.path.append(.chat(ChatFeature.State(conversation: id)))
        return .none

      case .newMessageTapped:
        state.isPickingContact = true
        return .none

      case let .contactPicked(key):
        state.isPickingContact = false
        state.path.append(.chat(ChatFeature.State(conversation: .forContact(key))))
        return .none

      case .addChannelTapped:
        state.destination = .addChannel(AddChannelFeature.State())
        return .none

      case let .removeChannelTapped(channel):
        let empty = ChannelInfo(index: channel.index, name: "", secret: Data(count: ChannelInfo.secretLength))
        return .run { send in
          do {
            try await meshCore.perform(.setChannel(empty))
            await send(.channelRemoved(channel))
          } catch {
            await send(.removeFailed(error.localizedDescription))
          }
        }

      case let .channelRemoved(channel):
        state.$channels.withLock { _ = $0.remove(id: channel.index) }
        return .none

      case let .removeFailed(message):
        return .send(.delegate(.showError(message)))

      case let .clearConversationTapped(id):
        state.$messages.withLock { messages in
          messages.removeAll { $0.conversation == id && $0.kind != .cli }
        }
        return .none

      case .markAllReadTapped:
        let now = self.now
        let ids = state.summaries.map(\.id.rawValue)
        state.$lastRead.withLock { lastRead in
          for id in ids { lastRead[id] = now }
        }
        return .none

      // MARK: Navigation from children

      case let .path(.element(id: _, action: .chat(.delegate(.deliver(messageID))))):
        return .send(.outbox(.deliver(messageID)))

      case let .path(.element(id: _, action: .chat(.delegate(.showContact(key))))):
        state.path.append(.contactDetail(ContactDetailFeature.State(key: key)))
        return .none

      case let .path(.element(id: _, action: .chat(.delegate(.showRemoteNode(key))))),
           let .path(.element(id: _, action: .contactDetail(.delegate(.openRemoteNode(key))))):
        state.path.append(.remoteNode(RemoteNodeFeature.State(key: key)))
        return .none

      case let .path(.element(id: _, action: .contactDetail(.delegate(.openChat(key))))),
           let .path(.element(id: _, action: .remoteNode(.delegate(.openChat(key))))):
        let conversation = ConversationID.forContact(key)
        // Pop back to an existing chat with this contact if there is one.
        if let existing = state.path.ids.first(where: {
          if case let .chat(chat)? = state.path[id: $0] { return chat.conversation == conversation }
          return false
        }) {
          state.path.pop(to: existing)
        } else {
          state.path.append(.chat(ChatFeature.State(conversation: conversation)))
        }
        return .none

      case let .path(.element(id: id, action: .contactDetail(.delegate(.removed)))):
        state.path.pop(from: id)
        return .none

      case .path:
        return .none

      case let .destination(.presented(.addChannel(.delegate(.added(channel))))):
        state.path.append(.chat(ChatFeature.State(conversation: channel.conversationID)))
        return .none

      case .destination:
        return .none

      // MARK: Outbox

      case let .outbox(.deliver(id)):
        guard let message = state.messages[id: id],
              let keyHex = message.conversation.contactKeyHex,
              let contact = state.contacts.matching(hex: keyHex)
        else {
          return .send(.outbox(.failed(id, "Unknown contact")))
        }
        return .run { [messages = state.$messages] send in
          await deliver(message, to: contact, messages: messages, send: send)
        }
        .cancellable(id: CancelID.delivery(id), cancelInFlight: true)

      case let .outbox(.attempt(id, attempt)):
        state.$messages.withLock {
          $0[id: id]?.attempts = attempt
          $0[id: id]?.status = .sending
        }
        return .none

      case let .outbox(.sent(id, sent)):
        state.$messages.withLock {
          $0[id: id]?.status = .sent(flood: sent.isFlood)
          $0[id: id]?.expectedAck = sent.expectedAck
        }
        return .none

      case let .outbox(.delivered(id, roundTrip)):
        state.$messages.withLock { $0[id: id]?.status = .delivered(roundTripMilliseconds: roundTrip) }
        return .none

      case let .outbox(.failed(id, reason)):
        state.$messages.withLock { $0[id: id]?.status = .failed(reason) }
        return .none

      case .delegate:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
    .ifLet(\.$destination, action: \.destination)
  }

  /// Sends a direct message, waiting for the recipient's ACK and retrying.
  /// The final attempt resets the stored route so it goes out as a flood.
  private func deliver(
    _ message: ChatMessage,
    to contact: Contact,
    messages: Shared<IdentifiedArrayOf<ChatMessage>>,
    send: Send<Action>
  ) async {
    let timestamp = UInt32(message.timestamp.timeIntervalSince1970)
    for attempt in 0..<Self.maxAttempts {
      if attempt == Self.maxAttempts - 1, !contact.outPath.isFlood {
        try? await meshCore.perform(.resetPath(contact.publicKey))
      }
      await send(.outbox(.attempt(message.id, attempt + 1)))

      // Subscribe before sending so a fast ACK isn't missed.
      let pushes = await meshCore.pushes()
      let sent: SentInfo
      do {
        sent = try await meshCore.sendExpectingSent(.sendTextMessage(
          type: .plain,
          attempt: UInt8(attempt),
          timestamp: timestamp,
          recipient: contact.publicKey.prefix(),
          text: message.text
        ))
      } catch {
        await send(.outbox(.failed(message.id, error.localizedDescription)))
        return
      }
      await send(.outbox(.sent(message.id, sent)))

      let wait = Duration.milliseconds(max(Int(sent.timeoutMilliseconds) * 3 / 2, 4_000))
      if let roundTrip = await waitForAck(sent.expectedAck, in: pushes, timeout: wait) {
        await send(.outbox(.delivered(message.id, roundTrip: roundTrip)))
        return
      }
      if case .delivered = messages.wrappedValue[id: message.id]?.status {
        return // confirmed late, via the app-wide handler
      }
    }
    await send(.outbox(.failed(message.id, "No delivery confirmation")))
  }

  private func waitForAck(_ ack: UInt32, in pushes: AsyncStream<PushEvent>, timeout: Duration) async -> UInt32? {
    await withTaskGroup(of: UInt32?.self) { group in
      group.addTask {
        for await push in pushes {
          if case let .sendConfirmed(code, roundTrip) = push, code == ack {
            return roundTrip
          }
        }
        return nil
      }
      group.addTask {
        try? await clock.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}

extension ChatsFeature.Path.State: Equatable {}
extension ChatsFeature.Destination.State: Equatable {}

struct ChatsView: View {
  @Bindable var store: StoreOf<ChatsFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      list
        .navigationTitle("Chats")
        .searchable(text: $store.searchText)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button {
                store.send(.newMessageTapped)
              } label: {
                Label("New Message", systemImage: "square.and.pencil")
              }
              Button {
                store.send(.addChannelTapped)
              } label: {
                Label("Add Channel", systemImage: "number")
              }
              Divider()
              Button {
                store.send(.markAllReadTapped)
              } label: {
                Label("Mark All Read", systemImage: "checkmark.circle")
              }
            } label: {
              Image(systemName: "plus.circle.fill")
            }
            .accessibilityLabel("New")
          }
        }
    } destination: { store in
      switch store.case {
      case let .chat(store):
        ChatView(store: store)
      case let .contactDetail(store):
        ContactDetailView(store: store)
      case let .remoteNode(store):
        RemoteNodeView(store: store)
      }
    }
    .sheet(item: $store.scope(state: \.destination?.addChannel, action: \.destination.addChannel)) { store in
      AddChannelView(store: store)
    }
    .sheet(isPresented: $store.isPickingContact) {
      ContactPicker(contacts: store.contacts.filter { $0.type == .chat || $0.type == .room }) { key in
        store.send(.contactPicked(key))
      }
    }
  }

  @ViewBuilder
  private var list: some View {
    let summaries = store.summaries
    if summaries.isEmpty {
      ContentUnavailableView {
        Label("No conversations", systemImage: "bubble.left.and.bubble.right")
      } description: {
        Text("Connect your radio to sync channels and contacts, then start chatting.")
      } actions: {
        Button("Add Channel") { store.send(.addChannelTapped) }
      }
    } else {
      List(summaries) { summary in
        Button {
          store.send(.conversationTapped(summary.id))
        } label: {
          SummaryRow(summary: summary)
        }
        .swipeActions(edge: .trailing) {
          if let channel = summary.channel {
            Button(role: .destructive) {
              store.send(.removeChannelTapped(channel))
            } label: {
              Label("Remove", systemImage: "minus.circle")
            }
          }
          Button {
            store.send(.clearConversationTapped(summary.id))
          } label: {
            Label("Clear", systemImage: "trash")
          }
          .tint(.gray)
        }
      }
      .listStyle(.plain)
    }
  }
}

private struct SummaryRow: View {
  let summary: ChatsFeature.Summary

  var body: some View {
    HStack(spacing: 12) {
      if let channel = summary.channel {
        ChannelAvatar(channel: channel, size: 44)
      } else {
        NodeAvatar(type: summary.nodeType ?? .none, size: 44)
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(summary.title)
            .font(.headline)
            .lineLimit(1)
          if summary.isFavourite {
            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
          }
          Spacer()
          if let date = summary.date {
            Text(Format.relative(date))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          Text(summary.preview)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Spacer()
          if summary.unread > 0 {
            Text("\(summary.unread)")
              .font(.caption.bold())
              .foregroundStyle(.white)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(Color.accentColor, in: Capsule())
          }
        }
      }
    }
    .contentShape(Rectangle())
    .foregroundStyle(.primary)
  }
}

/// Picks a contact to start a conversation with.
struct ContactPicker: View {
  let contacts: [Contact]
  let onPick: (PublicKey) -> Void
  @State private var search = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(filtered) { contact in
        Button {
          onPick(contact.publicKey)
        } label: {
          HStack(spacing: 12) {
            NodeAvatar(type: contact.type, size: 32)
            Text(contact.displayName).foregroundStyle(.primary)
          }
        }
      }
      .overlay {
        if contacts.isEmpty {
          ContentUnavailableView("No contacts yet", systemImage: "person.2", description: Text("Contacts appear when other nodes advertise."))
        }
      }
      .searchable(text: $search)
      .navigationTitle("New Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private var filtered: [Contact] {
    let sorted = contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    guard !search.isEmpty else { return sorted }
    return sorted.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
  }
}
