import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// A single conversation: direct, room server or channel.
@Reducer
struct ChatFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var conversation: ConversationID
    var draft = ""
    @Shared(.messages) var messages
    @Shared(.contacts) var contacts
    @Shared(.channels) var channels
    @Shared(.radioSession) var session
    @Shared(.lastRead) var lastRead
    var shareChannel: ShareChannelState?

    var id: ConversationID { conversation }

    init(conversation: ConversationID) {
      self.conversation = conversation
    }

    var contact: Contact? {
      conversation.contactKeyHex.flatMap { contacts.matching(hex: $0) }
    }

    var channel: ChannelInfo? {
      conversation.channelSecretHex.flatMap { secret in
        channels.first { $0.secret.hexString == secret }
      }
    }

    var title: String {
      if let contact { return contact.displayName }
      if let channel { return channel.displayName }
      return conversation.contactKeyHex.map(Format.shortKey) ?? "Conversation"
    }

    var thread: [ChatMessage] {
      messages
        .filter { $0.conversation == conversation && $0.kind != .cli }
        .sorted { $0.timestamp < $1.timestamp }
    }

    /// UTF-8 bytes allowed for one message.
    var byteLimit: Int {
      channel != nil ? session.channelTextLimit : Command.maxTextBytes
    }

    var draftBytes: Int { draft.utf8.count }

    var canSend: Bool {
      let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && draftBytes <= byteLimit && session.status.isLinkUp
        && (contact != nil || channel != nil)
    }
  }

  struct ShareChannelState: Equatable, Identifiable {
    var name: String
    var link: String
    var id: String { link }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case sendTapped
    case retryTapped(ChatMessage.ID)
    case deleteMessage(ChatMessage.ID)
    case infoTapped
    case delegate(Delegate)

    enum Delegate {
      /// Ask the owner to deliver an outgoing direct message (with retries),
      /// independent of this screen's lifetime.
      case deliver(ChatMessage.ID)
      case showContact(PublicKey)
      case showRemoteNode(PublicKey)
    }
  }

  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now
  @Dependency(\.meshCore) var meshCore

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        markRead(&state)
        return .none

      case .sendTapped:
        guard state.canSend else { return .none }
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.draft = ""
        let message = ChatMessage(
          id: uuid(),
          conversation: state.conversation,
          direction: .outgoing,
          senderName: state.session.nodeName,
          text: text,
          timestamp: now,
          status: .sending
        )
        state.$messages.withLock { $0.append(message) }
        markRead(&state)

        if let channel = state.channel {
          let timestamp = UInt32(now.timeIntervalSince1970)
          let id = message.id
          return .run { [messages = state.$messages] _ in
            let status: ChatMessage.Status
            do {
              try await meshCore.perform(.sendChannelTextMessage(channelIndex: channel.index, timestamp: timestamp, text: text))
              status = .sent(flood: true)
            } catch {
              status = .failed(error.localizedDescription)
            }
            messages.withLock { $0[id: id]?.status = status }
          }
        }
        return .send(.delegate(.deliver(message.id)))

      case let .retryTapped(id):
        guard let message = state.messages[id: id], message.isOutgoing else { return .none }
        if state.channel != nil {
          // Channel messages have no ACKs; re-send as a new message.
          state.draft = message.text
          state.$messages.withLock { $0.remove(id: id) }
          return .send(.sendTapped)
        }
        state.$messages.withLock {
          $0[id: id]?.status = .sending
          $0[id: id]?.attempts = 0
        }
        return .send(.delegate(.deliver(id)))

      case let .deleteMessage(id):
        state.$messages.withLock { $0.remove(id: id) }
        return .none

      case .infoTapped:
        if let contact = state.contact {
          return .send(.delegate(contact.type.supportsLogin ? .showRemoteNode(contact.publicKey) : .showContact(contact.publicKey)))
        }
        if let channel = state.channel {
          state.shareChannel = ShareChannelState(
            name: channel.displayName,
            link: MeshCoreLink.channel(name: channel.name, secret: channel.secret).url.absoluteString
          )
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func markRead(_ state: inout State) {
    let key = state.conversation.rawValue
    let date = now
    state.$lastRead.withLock { $0[key] = date }
  }
}

struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  @FocusState private var isComposerFocused: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 6) {
          if store.thread.isEmpty {
            emptyState
          }
          ForEach(store.thread) { message in
            MessageBubble(
              message: message,
              showsSender: store.channel != nil || store.contact?.type == .room,
              onRetry: { store.send(.retryTapped(message.id)) }
            )
            .id(message.id)
            .contextMenu {
              Button {
                UIPasteboard.general.string = message.text
              } label: {
                Label("Copy", systemImage: "doc.on.doc")
              }
              if message.isOutgoing, case .failed = message.status {
                Button {
                  store.send(.retryTapped(message.id))
                } label: {
                  Label("Retry", systemImage: "arrow.clockwise")
                }
              }
              Button(role: .destructive) {
                store.send(.deleteMessage(message.id))
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: store.thread.last?.id) { _, id in
        if let id {
          withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        }
      }
    }
    .safeAreaInset(edge: .bottom) { composer }
    .navigationTitle(store.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.infoTapped)
        } label: {
          if store.channel != nil {
            Image(systemName: "qrcode")
          } else {
            Image(systemName: "info.circle")
          }
        }
        .accessibilityLabel(store.channel != nil ? "Share channel" : "Contact info")
      }
    }
    .sheet(item: $store.shareChannel) { share in
      ShareLinkSheet(
        title: share.name,
        subtitle: store.channel?.isPublic == true
          ? "The Public channel uses a well-known key."
          : "Anyone with this code can read and post in the channel.",
        link: share.link
      )
    }
    .onAppear { store.send(.onAppear) }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
    } description: {
      if store.channel != nil {
        Text("Messages on this channel are visible to everyone who has its key.")
      } else {
        Text("Messages are end-to-end encrypted and relayed by repeaters.")
      }
    }
    .padding(.top, 60)
  }

  private var composer: some View {
    VStack(spacing: 4) {
      if !store.session.status.isLinkUp {
        Text("Radio not connected — messages can't be sent.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Message", text: $store.draft, axis: .vertical)
          .lineLimit(1...5)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.background, in: RoundedRectangle(cornerRadius: 18))
          .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
          .focused($isComposerFocused)
          .onSubmit { store.send(.sendTapped) }
        Button {
          store.send(.sendTapped)
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 32))
        }
        .disabled(!store.canSend)
        .accessibilityLabel("Send")
      }
      if store.draftBytes > store.byteLimit * 3 / 4 {
        Text("\(store.draftBytes)/\(store.byteLimit) bytes")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(store.draftBytes > store.byteLimit ? .red : .secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

struct MessageBubble: View {
  let message: ChatMessage
  var showsSender = false
  var onRetry: () -> Void = {}

  var body: some View {
    HStack {
      if message.isOutgoing { Spacer(minLength: 48) }
      VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
        if showsSender, !message.isOutgoing, let sender = message.senderName {
          Text(sender)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(message.text)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .foregroundStyle(message.isOutgoing ? .white : .primary)
          .background(
            message.isOutgoing ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.tertiary),
            in: RoundedRectangle(cornerRadius: 18)
          )
        footer
      }
      if !message.isOutgoing { Spacer(minLength: 48) }
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      Text(message.timestamp, style: .time)
      if !message.isOutgoing {
        if let hops = Format.hops(message.hops) {
          Text(hops)
        }
        if let snr = message.snr {
          Text(Format.snr(snr))
        }
      }
      if message.isOutgoing {
        statusView
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var statusView: some View {
    switch message.status {
    case .sending:
      HStack(spacing: 2) {
        ProgressView().controlSize(.mini)
        if message.attempts > 1 { Text("retry \(message.attempts - 1)") }
      }
    case let .sent(flood):
      Label(flood ? "Sent (flood)" : "Sent", systemImage: "checkmark")
        .labelStyle(.titleAndIcon)
    case let .delivered(rtt):
      Label("Delivered · \(String(format: "%.1f", Double(rtt) / 1000))s", systemImage: "checkmark.circle.fill")
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.green)
    case let .failed(reason):
      Button(action: onRetry) {
        Label("Failed – tap to retry", systemImage: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.plain)
      .help(reason)
    case .received:
      EmptyView()
    }
  }
}
