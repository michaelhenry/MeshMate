import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Everything you can do with a single contact: routing tools, telemetry,
/// sharing and management.
@Reducer
struct ContactDetailFeature {
  enum Operation: String, Hashable, Sendable {
    case discover, trace, telemetry, advertPath, share, export, resetPath, favourite, savePath, remove
  }

  struct ShareSheet: Equatable, Identifiable {
    var title: String
    var subtitle: String
    var link: String
    var id: String { link }
  }

  @ObservableState
  struct State: Equatable, Identifiable {
    let key: PublicKey
    @Shared(.contacts) var contacts
    @Shared(.radioSession) var session
    var advertPath: AdvertPath?
    var advertPathChecked = false
    var discovery: PathDiscoveryResult?
    var trace: TraceResult?
    var traceTag: UInt32?
    var telemetry: [TelemetryReading] = []
    var busy: Set<Operation> = []
    var pathDraft = ""
    var isEditingPath = false
    var shareSheet: ShareSheet?
    var notice: String?
    @Presents var alert: AlertState<Action.Alert>?

    var id: PublicKey { key }
    var contact: Contact? { contacts[id: key] }

    init(key: PublicKey) {
      self.key = key
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case messageTapped
    case manageTapped
    case favouriteToggled
    case resetPathTapped
    case editPathTapped
    case savePathTapped
    case useDiscoveredPathTapped
    case removeTapped
    case shareZeroHopTapped
    case shareQRTapped
    case exportAdvertTapped
    case discoverPathTapped
    case traceTapped
    case telemetryTapped
    case advertPathTapped
    case push(PushEvent)
    case contactUpdated(Contact)
    case requestSent(Operation, SentInfo)
    case advertPathLoaded(AdvertPath?)
    case exported(Data)
    case succeeded(Operation, notice: String?)
    case failed(Operation, String)
    case timedOut(Operation)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    enum Alert: Equatable {
      case confirmRemove
    }

    enum Delegate {
      case openChat(PublicKey)
      case openRemoteNode(PublicKey)
      case removed(PublicKey)
    }
  }

  private enum CancelID: Hashable {
    case timeout(Operation)
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.continuousClock) var clock
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .run { send in
          for await push in await meshCore.pushes() {
            await send(.push(push))
          }
        }

      case .messageTapped:
        return .send(.delegate(.openChat(state.key)))

      case .manageTapped:
        return .send(.delegate(.openRemoteNode(state.key)))

      case .favouriteToggled:
        guard var contact = state.contact else { return .none }
        contact.isFavourite.toggle()
        return update(contact, operation: .favourite, state: &state)

      case .resetPathTapped:
        state.busy.insert(.resetPath)
        let key = state.key
        return .run { send in
          do {
            try await meshCore.perform(.resetPath(key))
            if let contact = try await meshCore.contact(key) {
              await send(.contactUpdated(contact))
            }
            await send(.succeeded(.resetPath, notice: "Path reset. The next message will flood."))
          } catch {
            await send(.failed(.resetPath, error.localizedDescription))
          }
        }

      case .editPathTapped:
        state.pathDraft = state.contact.map { $0.outPath.isFlood ? "" : $0.outPath.hops.map(\.hexString).joined(separator: ",") } ?? ""
        state.isEditingPath = true
        return .none

      case .savePathTapped:
        guard var contact = state.contact else { return .none }
        guard let path = MeshPath(hopString: state.pathDraft) else {
          state.notice = "Enter hop hashes like a3,7f (1–3 bytes each)."
          return .none
        }
        contact.outPath = path
        state.isEditingPath = false
        return update(contact, operation: .savePath, state: &state)

      case .useDiscoveredPathTapped:
        guard var contact = state.contact, let path = state.discovery?.outPath else { return .none }
        contact.outPath = path
        return update(contact, operation: .savePath, state: &state)

      case .removeTapped:
        let name = state.contact?.displayName ?? "contact"
        state.alert = AlertState {
          TextState("Remove \(name)?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemove) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("The contact is deleted from the radio. You can add it again when it next advertises.")
        }
        return .none

      case .alert(.presented(.confirmRemove)):
        state.busy.insert(.remove)
        let key = state.key
        return .run { send in
          do {
            try await meshCore.perform(.removeContact(key))
            await send(.succeeded(.remove, notice: nil))
          } catch {
            await send(.failed(.remove, error.localizedDescription))
          }
        }

      case .alert:
        return .none

      case .shareZeroHopTapped:
        state.busy.insert(.share)
        let key = state.key
        return .run { send in
          do {
            try await meshCore.perform(.shareContact(key))
            await send(.succeeded(.share, notice: "Shared with nodes in direct range."))
          } catch {
            await send(.failed(.share, error.localizedDescription))
          }
        }

      case .shareQRTapped:
        guard let contact = state.contact else { return .none }
        state.shareSheet = ShareSheet(
          title: contact.displayName,
          subtitle: "Scan with MeshMate or the MeshCore app to add this contact.",
          link: MeshCoreLink.contact(name: contact.name, publicKey: contact.publicKey, type: contact.type).url.absoluteString
        )
        return .none

      case .exportAdvertTapped:
        state.busy.insert(.export)
        let key = state.key
        return .run { send in
          do {
            await send(.exported(try await meshCore.exportContact(key)))
          } catch {
            await send(.failed(.export, error.localizedDescription))
          }
        }

      case let .exported(data):
        state.busy.remove(.export)
        state.shareSheet = ShareSheet(
          title: "Signed Advert",
          subtitle: "A signed advert others can import, even without hearing it over the air.",
          link: MeshCoreLink.advert(data).url.absoluteString
        )
        return .none

      case .discoverPathTapped:
        state.busy.insert(.discover)
        state.discovery = nil
        let key = state.key
        return .run { send in
          do {
            await send(.requestSent(.discover, try await meshCore.sendExpectingSent(.sendPathDiscoveryRequest(key))))
          } catch {
            await send(.failed(.discover, error.localizedDescription))
          }
        }

      case .traceTapped:
        guard let contact = state.contact else { return .none }
        guard let route = Self.tracePath(for: contact) else {
          state.notice = "No known route. Run Discover Path first, or trace once the contact has a direct path."
          return .none
        }
        let tag = withRandomNumberGenerator { UInt32.random(in: 1 ... .max, using: &$0) }
        state.busy.insert(.trace)
        state.trace = nil
        state.traceTag = tag
        return .run { send in
          do {
            let sent = try await meshCore.sendExpectingSent(.sendTracePath(tag: tag, authCode: 0, flags: route.flags, path: route.path))
            await send(.requestSent(.trace, sent))
          } catch {
            await send(.failed(.trace, error.localizedDescription))
          }
        }

      case .telemetryTapped:
        state.busy.insert(.telemetry)
        let key = state.key
        return .run { send in
          do {
            await send(.requestSent(.telemetry, try await meshCore.sendExpectingSent(.sendTelemetryRequest(key))))
          } catch {
            await send(.failed(.telemetry, error.localizedDescription))
          }
        }

      case .advertPathTapped:
        state.busy.insert(.advertPath)
        let key = state.key
        return .run { send in
          do {
            await send(.advertPathLoaded(try await meshCore.advertPath(key)))
          } catch {
            await send(.failed(.advertPath, error.localizedDescription))
          }
        }

      case let .advertPathLoaded(path):
        state.busy.remove(.advertPath)
        state.advertPath = path
        state.advertPathChecked = true
        return .none

      case let .requestSent(operation, sent):
        // Wait a generous multiple of the firmware's estimate for the reply.
        let wait = Duration.milliseconds(max(Int(sent.timeoutMilliseconds) * 2, 5_000) + 5_000)
        return .run { send in
          try await clock.sleep(for: wait)
          await send(.timedOut(operation))
        }
        .cancellable(id: CancelID.timeout(operation), cancelInFlight: true)

      case let .timedOut(operation):
        guard state.busy.contains(operation) else { return .none }
        state.busy.remove(operation)
        state.notice = "No response from \(state.contact?.displayName ?? "the node"). It may be out of range."
        return .none

      case let .push(push):
        switch push {
        case let .pathDiscoveryResponse(result) where result.nodePrefix.matches(state.key):
          state.busy.remove(.discover)
          state.discovery = result
          return .cancel(id: CancelID.timeout(.discover))

        case let .traceData(result) where result.tag == state.traceTag:
          state.busy.remove(.trace)
          state.trace = result
          return .cancel(id: CancelID.timeout(.trace))

        case let .telemetryResponse(prefix, readings) where prefix.matches(state.key):
          state.busy.remove(.telemetry)
          state.telemetry = readings
          return .cancel(id: CancelID.timeout(.telemetry))

        case let .pathUpdated(key) where key == state.key, let .advert(key) where key == state.key:
          return .run { send in
            if let contact = try await meshCore.contact(key) {
              await send(.contactUpdated(contact))
            }
          }

        default:
          return .none
        }

      case let .contactUpdated(contact):
        state.$contacts.withLock { $0[id: contact.publicKey] = contact }
        return .none

      case let .succeeded(operation, notice):
        state.busy.remove(operation)
        if let notice { state.notice = notice }
        if operation == .remove {
          let key = state.key
          state.$contacts.withLock { _ = $0.remove(id: key) }
          return .send(.delegate(.removed(key)))
        }
        return .none

      case let .failed(operation, message):
        state.busy.remove(operation)
        state.notice = message
        return .cancel(id: CancelID.timeout(operation))

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  /// Writes an edited contact to the radio, then mirrors it locally.
  private func update(_ contact: Contact, operation: Operation, state: inout State) -> Effect<Action> {
    state.busy.insert(operation)
    return .run { send in
      do {
        try await meshCore.perform(.addUpdateContact(contact))
        await send(.contactUpdated(try await meshCore.contact(contact.publicKey) ?? contact))
        await send(.succeeded(operation, notice: operation == .savePath ? "Route saved." : nil))
      } catch {
        await send(.failed(operation, error.localizedDescription))
      }
    }
  }

  /// Builds a round-trip trace route: out along the known path, through the
  /// target (when it is a repeater) and back.
  static func tracePath(for contact: Contact) -> (path: Data, flags: UInt8)? {
    guard !contact.outPath.isFlood else { return nil }
    // Trace hashes must be 1, 2 or 4 bytes; 3-byte paths fall back to 1 byte.
    let size = contact.outPath.length.hashSize == 2 ? 2 : 1
    let flags: UInt8 = size == 2 ? 1 : 0
    let outbound = contact.outPath.hops.map { $0.prefix(size) }
    var hops = outbound
    if contact.type == .repeater || contact.type == .room {
      hops.append(contact.publicKey.bytes.prefix(size))
      hops.append(contentsOf: outbound.reversed())
    } else {
      // Companions don't relay; trace to the last repeater and back.
      guard !outbound.isEmpty else { return nil }
      hops.append(contentsOf: outbound.dropLast().reversed())
    }
    guard !hops.isEmpty else { return nil }
    return (hops.reduce(into: Data()) { $0.append($1) }, flags)
  }
}

struct ContactDetailView: View {
  @Bindable var store: StoreOf<ContactDetailFeature>

  var body: some View {
    Group {
      if let contact = store.contact {
        form(contact)
      } else {
        ContentUnavailableView("Contact removed", systemImage: "person.crop.circle.badge.xmark")
      }
    }
    .navigationTitle(store.contact?.displayName ?? "Contact")
    .navigationBarTitleDisplayMode(.inline)
    .task { await store.send(.task).finish() }
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(item: $store.shareSheet) { sheet in
      ShareLinkSheet(title: sheet.title, subtitle: sheet.subtitle, link: sheet.link)
    }
    .alert("Edit Route", isPresented: $store.isEditingPath) {
      TextField("a3,7f,12", text: $store.pathDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Save") { store.send(.savePathTapped) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Comma-separated repeater hashes from you to the contact. Leave empty for a direct (zero-hop) route.")
    }
  }

  private func isBusy(_ operation: ContactDetailFeature.Operation) -> Bool {
    store.busy.contains(operation)
  }

  @ViewBuilder
  private func form(_ contact: Contact) -> some View {
    Form {
      Section {
        HStack(spacing: 14) {
          NodeAvatar(type: contact.type, size: 52)
          VStack(alignment: .leading, spacing: 4) {
            Text(contact.displayName).font(.title3.bold())
            Text(contact.type.displayName).foregroundStyle(.secondary)
            Text("Heard \(Format.relative(contact.lastAdvertDate))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            store.send(.favouriteToggled)
          } label: {
            Image(systemName: contact.isFavourite ? "star.fill" : "star")
              .font(.title2)
              .foregroundStyle(.yellow)
          }
          .buttonStyle(.plain)
          .disabled(isBusy(.favourite))
          .accessibilityLabel(contact.isFavourite ? "Remove from favourites" : "Add to favourites")
        }
        .padding(.vertical, 4)

        HStack {
          if contact.type != .repeater && contact.type != .sensor {
            Button {
              store.send(.messageTapped)
            } label: {
              Label("Message", systemImage: "bubble.left.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
          if contact.type.supportsLogin {
            Button {
              store.send(.manageTapped)
            } label: {
              Label(contact.type == .room ? "Log In" : "Manage", systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
          }
        }
      }

      if let notice = store.notice {
        Section {
          Label(notice, systemImage: "info.circle")
            .font(.callout)
        }
      }

      Section("Routing") {
        ValueRow(title: "Route", value: contact.outPath.displayString, monospaced: true)
        if !contact.outPath.isFlood {
          ValueRow(title: "Hops", value: "\(contact.outPath.length.hopCount) (\(contact.outPath.length.hashSize)-byte hashes)")
        }
        actionButton("Discover Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath", operation: .discover) {
          store.send(.discoverPathTapped)
        }
        if let discovery = store.discovery {
          ValueRow(title: "Path out", value: discovery.outPath.displayString, monospaced: true)
          ValueRow(title: "Path back", value: discovery.inPath.displayString, monospaced: true)
          if discovery.outPath != contact.outPath {
            Button("Use This Path") { store.send(.useDiscoveredPathTapped) }
          }
        }
        actionButton("Trace Route", systemImage: "waveform.path.ecg", operation: .trace) {
          store.send(.traceTapped)
        }
        if let trace = store.trace {
          ForEach(Array(zip(trace.hopHashes.indices, trace.hopHashes)), id: \.0) { index, hash in
            LabeledContent("Hop \(index + 1) · \(hash.hexString)") {
              Text(Format.snr(trace.hopSNRs.indices.contains(index) ? trace.hopSNRs[index] : nil))
                .monospacedDigit()
            }
          }
          LabeledContent("Back to you") {
            Text(Format.snr(trace.finalSNR)).monospacedDigit()
          }
        }
        actionButton("Last Advert Path", systemImage: "arrow.down.left.circle", operation: .advertPath) {
          store.send(.advertPathTapped)
        }
        if store.advertPathChecked {
          if let advertPath = store.advertPath {
            ValueRow(title: "Advert came via", value: advertPath.path.displayString, monospaced: true)
          } else {
            Text("No advert heard since the radio started.").foregroundStyle(.secondary)
          }
        }
        Button("Edit Route…") { store.send(.editPathTapped) }
        actionButton("Reset Route (use flood)", systemImage: "arrow.uturn.backward", operation: .resetPath) {
          store.send(.resetPathTapped)
        }
      }

      if contact.type == .sensor || contact.type == .repeater || contact.type == .chat || contact.type == .room {
        Section("Telemetry") {
          actionButton("Request Telemetry", systemImage: "gauge.with.dots.needle.33percent", operation: .telemetry) {
            store.send(.telemetryTapped)
          }
          TelemetryList(readings: store.telemetry)
        }
      }

      if contact.hasLocation {
        Section("Location") {
          ValueRow(title: "Position", value: Format.coordinate(contact.latitude, contact.longitude), monospaced: true)
          if let url = URL(string: "maps://?ll=\(contact.latitude),\(contact.longitude)&q=\(contact.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
            Link(destination: url) {
              Label("Open in Maps", systemImage: "map")
            }
          }
        }
      }

      Section("Share") {
        Button {
          store.send(.shareQRTapped)
        } label: {
          Label("Show QR Code", systemImage: "qrcode")
        }
        actionButton("Share Over the Air (zero hop)", systemImage: "dot.radiowaves.up.forward", operation: .share) {
          store.send(.shareZeroHopTapped)
        }
        actionButton("Export Signed Advert", systemImage: "square.and.arrow.up", operation: .export) {
          store.send(.exportAdvertTapped)
        }
      }

      Section("Identity") {
        ValueRow(title: "Public key", value: contact.publicKey.hex, monospaced: true)
        if let date = contact.lastAdvertDate {
          ValueRow(title: "Last advert", value: date.formatted(date: .abbreviated, time: .shortened))
        }
      }

      Section {
        Button(role: .destructive) {
          store.send(.removeTapped)
        } label: {
          Label("Remove Contact", systemImage: "trash")
        }
        .disabled(isBusy(.remove))
      }
    }
    .disabled(!store.session.status.isLinkUp)
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    operation: ContactDetailFeature.Operation,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer()
        if isBusy(operation) { ProgressView() }
      }
    }
    .disabled(isBusy(operation))
  }
}
