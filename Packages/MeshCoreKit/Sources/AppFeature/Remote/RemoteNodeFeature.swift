import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Log in to and administer a repeater, room server or sensor.
@Reducer
struct RemoteNodeFeature {
  enum Request: String, Hashable, Sendable {
    case login, status, telemetry, neighbours, accessList
  }

  enum LoginState: Equatable {
    case loggedOut
    case loggingIn
    case loggedIn(LoginResult)
    case failed(String)

    var result: LoginResult? {
      if case let .loggedIn(result) = self { return result }
      return nil
    }
  }

  @ObservableState
  struct State: Equatable, Identifiable {
    let key: PublicKey
    var password = ""
    var rememberPassword = true
    var login: LoginState = .loggedOut
    var status: RemoteNodeStatus?
    var telemetry: [TelemetryReading] = []
    var neighbours: NeighboursResponse?
    var accessList: [AccessListEntry]?
    var pendingTags: [Request: UInt32] = [:]
    var busy: Set<Request> = []
    var cliDraft = ""
    var notice: String?
    @Shared(.contacts) var contacts
    @Shared(.messages) var messages
    @Shared(.radioSession) var session

    var id: PublicKey { key }
    var contact: Contact? { contacts[id: key] }

    var cliLog: [ChatMessage] {
      messages
        .filter { $0.kind == .cli && $0.conversation == .forContact(key) }
        .sorted { $0.timestamp < $1.timestamp }
    }

    init(key: PublicKey) {
      self.key = key
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case passwordLoaded(String?)
    case loginTapped
    case logoutTapped
    case statusTapped
    case telemetryTapped
    case neighboursTapped
    case accessListTapped
    case sendCLITapped
    case openChatTapped
    case requestSent(Request, SentInfo)
    case requestFailed(Request, String)
    case timedOut(Request)
    case push(PushEvent)
    case delegate(Delegate)

    enum Delegate {
      case openChat(PublicKey)
    }
  }

  private enum CancelID: Hashable {
    case timeout(Request)
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.keychain) var keychain
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let account = state.key.hex
        return .merge(
          .run { send in
            await send(.passwordLoaded(keychain.load(account)))
          },
          .run { send in
            for await push in await meshCore.pushes() {
              await send(.push(push))
            }
          }
        )

      case let .passwordLoaded(password):
        if let password, state.password.isEmpty {
          state.password = password
        }
        return .none

      case .loginTapped:
        state.login = .loggingIn
        state.busy.insert(.login)
        let key = state.key
        let password = state.password
        let remember = state.rememberPassword
        return .run { send in
          if remember {
            keychain.save(key.hex, password)
          } else {
            keychain.delete(key.hex)
          }
          do {
            await send(.requestSent(.login, try await meshCore.sendExpectingSent(.sendLogin(key, password: password))))
          } catch {
            await send(.requestFailed(.login, error.localizedDescription))
          }
        }

      case .logoutTapped:
        state.login = .loggedOut
        state.status = nil
        state.neighbours = nil
        state.accessList = nil
        let key = state.key
        return .run { _ in
          try? await meshCore.perform(.logout(key))
        }

      case .statusTapped:
        return startRequest(.status, .sendStatusRequest(state.key), state: &state)

      case .telemetryTapped:
        return startRequest(.telemetry, .sendTelemetryRequest(state.key), state: &state)

      case .neighboursTapped:
        return startRequest(.neighbours, .sendBinaryRequest(state.key, data: BinaryRequest.neighbours(prefixLength: 6)), state: &state)

      case .accessListTapped:
        return startRequest(.accessList, .sendBinaryRequest(state.key, data: BinaryRequest.accessList()), state: &state)

      case .sendCLITapped:
        let command = state.cliDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }
        state.cliDraft = ""
        let message = ChatMessage(
          id: uuid(),
          conversation: .forContact(state.key),
          direction: .outgoing,
          kind: .cli,
          text: command,
          timestamp: now,
          status: .sending
        )
        state.$messages.withLock { $0.append(message) }
        let key = state.key
        let timestamp = UInt32(now.timeIntervalSince1970)
        let id = message.id
        return .run { [messages = state.$messages] _ in
          let status: ChatMessage.Status
          do {
            let sent = try await meshCore.sendExpectingSent(
              .sendTextMessage(type: .cliData, attempt: 0, timestamp: timestamp, recipient: key.prefix(), text: command)
            )
            status = .sent(flood: sent.isFlood)
          } catch {
            status = .failed(error.localizedDescription)
          }
          messages.withLock { $0[id: id]?.status = status }
        }

      case .openChatTapped:
        return .send(.delegate(.openChat(state.key)))

      case let .requestSent(request, sent):
        state.pendingTags[request] = sent.expectedAck
        let wait = Duration.milliseconds(max(Int(sent.timeoutMilliseconds) * 2, 6_000) + 4_000)
        return .run { send in
          try await clock.sleep(for: wait)
          await send(.timedOut(request))
        }
        .cancellable(id: CancelID.timeout(request), cancelInFlight: true)

      case let .requestFailed(request, message):
        state.busy.remove(request)
        state.pendingTags[request] = nil
        if request == .login { state.login = .failed(message) } else { state.notice = message }
        return .cancel(id: CancelID.timeout(request))

      case let .timedOut(request):
        guard state.busy.contains(request) else { return .none }
        state.busy.remove(request)
        state.pendingTags[request] = nil
        let message = "No response. The node may be out of range — try again."
        if request == .login { state.login = .failed(message) } else { state.notice = message }
        return .none

      case let .push(push):
        return handle(push, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  private func startRequest(_ request: Request, _ command: Command, state: inout State) -> Effect<Action> {
    state.busy.insert(request)
    state.notice = nil
    return .run { send in
      do {
        await send(.requestSent(request, try await meshCore.sendExpectingSent(command)))
      } catch {
        await send(.requestFailed(request, error.localizedDescription))
      }
    }
  }

  private func finish(_ request: Request, state: inout State) -> Effect<Action> {
    state.busy.remove(request)
    state.pendingTags[request] = nil
    return .cancel(id: CancelID.timeout(request))
  }

  private func handle(_ push: PushEvent, state: inout State) -> Effect<Action> {
    let key = state.key
    switch push {
    case let .loginSuccess(result) where result.nodePrefix.matches(key):
      state.login = .loggedIn(result)
      let effect = finish(.login, state: &state)
      // Room servers deliver missed posts after login; fetch status for repeaters.
      if state.contact?.type == .repeater {
        return .merge(effect, startRequest(.status, .sendStatusRequest(key), state: &state))
      }
      return effect

    case let .loginFailed(prefix) where prefix.matches(key):
      state.login = .failed("Wrong password, or the node rejected the login.")
      return finish(.login, state: &state)

    case let .statusResponse(prefix, status) where prefix.matches(key):
      state.status = status
      return finish(.status, state: &state)

    case let .telemetryResponse(prefix, readings) where prefix.matches(key):
      state.telemetry = readings
      return finish(.telemetry, state: &state)

    case let .binaryResponse(tag, data):
      if tag == state.pendingTags[.neighbours] {
        state.neighbours = try? NeighboursResponse(decoding: data, prefixLength: 6)
        return finish(.neighbours, state: &state)
      }
      if tag == state.pendingTags[.accessList] {
        state.accessList = AccessListEntry.decodeList(data)
        return finish(.accessList, state: &state)
      }
      return .none

    default:
      return .none
    }
  }
}

struct RemoteNodeView: View {
  @Bindable var store: StoreOf<RemoteNodeFeature>

  var body: some View {
    Form {
      header
      loginSection
      if store.login.result != nil {
        if store.contact?.type == .room {
          Section {
            Button {
              store.send(.openChatTapped)
            } label: {
              Label("Open Room", systemImage: "bubble.left.and.bubble.right.fill")
            }
          } footer: {
            Text("Posts you missed are delivered after logging in.")
          }
        }
        statusSection
        telemetrySection
        neighboursSection
        if store.login.result?.isAdmin == true {
          accessListSection
          consoleSection
        }
      } else if store.contact?.type == .sensor || store.contact?.type == .repeater {
        telemetrySection
      }
      if let notice = store.notice {
        Section {
          Label(notice, systemImage: "info.circle")
        }
      }
    }
    .navigationTitle(store.contact?.displayName ?? "Node")
    .navigationBarTitleDisplayMode(.inline)
    .disabled(!store.session.status.isLinkUp)
    .task { await store.send(.task).finish() }
  }

  private var header: some View {
    Section {
      HStack(spacing: 14) {
        NodeAvatar(type: store.contact?.type ?? .none, size: 48)
        VStack(alignment: .leading) {
          Text(store.contact?.displayName ?? Format.shortKey(store.key.hex)).font(.headline)
          Text(store.contact?.type.displayName ?? "").foregroundStyle(.secondary)
          if let path = store.contact?.outPath {
            Text("Route: \(path.displayString)").font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var loginSection: some View {
    Section {
      switch store.login {
      case let .loggedIn(result):
        LabeledContent("Logged in as", value: result.isAdmin ? "Admin" : "Guest")
        if let level = result.firmwareLevel {
          LabeledContent("Firmware level", value: "\(level)")
        }
        Button("Log Out", role: .destructive) { store.send(.logoutTapped) }
      default:
        SecureField("Password (blank for guest)", text: $store.password)
          .textContentType(.password)
        Toggle("Remember password", isOn: $store.rememberPassword)
        Button {
          store.send(.loginTapped)
        } label: {
          HStack {
            Text("Log In")
            Spacer()
            if store.busy.contains(.login) { ProgressView() }
          }
        }
        .disabled(store.busy.contains(.login))
        if case let .failed(message) = store.login {
          Text(message).foregroundStyle(.red).font(.callout)
        }
      }
    } header: {
      Text("Login")
    } footer: {
      if store.login.result == nil {
        Text("Repeater admin password defaults to “password”; guests use the guest password or none.")
      }
    }
  }

  private var statusSection: some View {
    Section {
      requestButton("Refresh Status", systemImage: "arrow.clockwise", request: .status) {
        store.send(.statusTapped)
      }
      if let status = store.status {
        LabeledContent("Battery", value: Format.voltage(status.batteryMillivolts))
        LabeledContent("Uptime", value: Format.duration(seconds: status.uptimeSeconds))
        LabeledContent("Noise floor", value: "\(status.noiseFloor) dBm")
        LabeledContent("Last RSSI / SNR", value: "\(status.lastRSSI) dBm / \(Format.snr(status.lastSNR))")
        LabeledContent("Packets rx / tx", value: "\(status.packetsReceived) / \(status.packetsSent)")
        LabeledContent("Flood rx / tx", value: "\(status.receivedFlood) / \(status.sentFlood)")
        LabeledContent("Direct rx / tx", value: "\(status.receivedDirect) / \(status.sentDirect)")
        LabeledContent("Duplicates (flood / direct)", value: "\(status.floodDuplicates) / \(status.directDuplicates)")
        LabeledContent("Airtime tx / rx", value: "\(Format.duration(seconds: status.airtimeSeconds)) / \(Format.duration(seconds: status.rxAirtimeSeconds))")
        LabeledContent("TX queue", value: "\(status.txQueueLength)")
        if let errors = status.receiveErrors {
          LabeledContent("Receive errors", value: "\(errors)")
        }
      }
    } header: {
      Text("Status")
    }
  }

  private var telemetrySection: some View {
    Section("Telemetry") {
      requestButton("Request Telemetry", systemImage: "gauge.with.dots.needle.33percent", request: .telemetry) {
        store.send(.telemetryTapped)
      }
      TelemetryList(readings: store.telemetry)
    }
  }

  private var neighboursSection: some View {
    Section("Neighbours") {
      requestButton("Fetch Neighbours", systemImage: "point.3.connected.trianglepath.dotted", request: .neighbours) {
        store.send(.neighboursTapped)
      }
      if let neighbours = store.neighbours {
        if neighbours.neighbours.isEmpty {
          Text("No neighbours heard yet.").foregroundStyle(.secondary)
        }
        ForEach(neighbours.neighbours) { neighbour in
          let match = store.contacts.matching(neighbour.keyPrefix)
          LabeledContent {
            VStack(alignment: .trailing) {
              Text(Format.snr(neighbour.snr)).monospacedDigit()
              Text(Format.relative(Date().addingTimeInterval(-TimeInterval(neighbour.secondsAgo))))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } label: {
            Text(match?.displayName ?? neighbour.keyPrefix.hex)
              .font(match == nil ? .callout.monospaced() : .callout)
          }
        }
      }
    }
  }

  private var accessListSection: some View {
    Section("Access List") {
      requestButton("Fetch Access List", systemImage: "person.2.badge.key", request: .accessList) {
        store.send(.accessListTapped)
      }
      if let entries = store.accessList {
        ForEach(entries) { entry in
          LabeledContent(store.contacts.matching(entry.keyPrefix)?.displayName ?? entry.keyPrefix.hex, value: entry.roleName)
        }
      }
    }
  }

  private var consoleSection: some View {
    Section {
      ForEach(store.cliLog.suffix(30)) { message in
        HStack(alignment: .top, spacing: 6) {
          Text(message.isOutgoing ? ">" : "<")
            .foregroundStyle(message.isOutgoing ? Color.accentColor : .green)
          Text(message.text)
            .textSelection(.enabled)
        }
        .font(.caption.monospaced())
      }
      HStack {
        TextField("e.g. ver, clock, get name, neighbors", text: $store.cliDraft)
          .font(.callout.monospaced())
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { store.send(.sendCLITapped) }
        Button {
          store.send(.sendCLITapped)
        } label: {
          Image(systemName: "paperplane.fill")
        }
        .disabled(store.cliDraft.isEmpty)
      }
    } header: {
      Text("Remote Console")
    } footer: {
      Text("Runs CLI commands on the node. Replies arrive over the mesh and may take a few seconds.")
    }
  }

  private func requestButton(
    _ title: String,
    systemImage: String,
    request: RemoteNodeFeature.Request,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer()
        if store.busy.contains(request) { ProgressView() }
      }
    }
    .disabled(store.busy.contains(request))
  }
}
