import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Adds a channel to the first free slot on the radio.
@Reducer
struct AddChannelFeature {
  enum Kind: String, CaseIterable, Equatable {
    case hashtag = "Hashtag"
    case privateChannel = "Private"
    case join = "Join"
  }

  @ObservableState
  struct State: Equatable {
    var kind: Kind = .hashtag
    var name = ""
    var secretHex = ""
    var link = ""
    var isSaving = false
    var isScanning = false
    var errorMessage: String?
    @Shared(.channels) var channels
    @Shared(.radioSession) var session

    var resolved: (name: String, secret: Data)? {
      switch kind {
      case .hashtag:
        let trimmed = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").lowercased()
        guard trimmed.count > (trimmed.hasPrefix("#") ? 1 : 0) else { return nil }
        let tagged = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        return (tagged, ChannelKeys.hashtagSecret(for: tagged))
      case .privateChannel:
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let secret = Data(hexString: secretHex), secret.count == 16 else { return nil }
        return (trimmed, secret)
      case .join:
        if case let .channel(linkName, secret) = MeshCoreLink(string: link) {
          return (linkName.isEmpty ? "Channel" : linkName, secret)
        }
        return nil
      }
    }

    /// The lowest slot index not holding a channel.
    var freeSlot: UInt8? {
      let used = Set(channels.map(\.index))
      let maxSlots = max(session.deviceInfo?.maxChannels ?? 8, 1)
      return (0..<maxSlots).map(UInt8.init).first { !used.contains($0) }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case regenerateSecret
    case scanned(String)
    case saveTapped
    case saved(ChannelInfo)
    case failed(String)
    case delegate(Delegate)

    enum Delegate {
      case added(ChannelInfo)
    }
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.dismiss) var dismiss

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        return .none

      case .onAppear:
        if state.secretHex.isEmpty {
          state.secretHex = ChannelKeys.randomSecret().hexString
        }
        return .none

      case .regenerateSecret:
        state.secretHex = ChannelKeys.randomSecret().hexString
        return .none

      case let .scanned(text):
        state.kind = .join
        state.link = text
        state.isScanning = false
        if MeshCoreLink(string: text) == nil {
          state.errorMessage = "That isn't a MeshCore channel link."
        }
        return .none

      case .saveTapped:
        guard let resolved = state.resolved else {
          state.errorMessage = "Enter a channel name and key."
          return .none
        }
        let name = resolved.name
        let secret = resolved.secret
        if state.channels.contains(where: { $0.secret == secret }) {
          state.errorMessage = "This channel is already on your radio."
          return .none
        }
        guard let slot = state.freeSlot else {
          state.errorMessage = "All channel slots on the radio are in use. Remove a channel first."
          return .none
        }
        state.isSaving = true
        let channel = ChannelInfo(index: slot, name: String(name.prefix(31)), secret: secret)
        return .run { send in
          do {
            try await meshCore.perform(.setChannel(channel))
            await send(.saved(channel))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .saved(channel):
        state.isSaving = false
        state.$channels.withLock { channels in
          channels[id: channel.index] = channel
          channels.sort { $0.index < $1.index }
        }
        return .run { send in
          await send(.delegate(.added(channel)))
          await dismiss()
        }

      case let .failed(message):
        state.isSaving = false
        state.errorMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

struct AddChannelView: View {
  @Bindable var store: StoreOf<AddChannelFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Picker("Type", selection: $store.kind) {
          ForEach(AddChannelFeature.Kind.allCases, id: \.self) { kind in
            Text(kind.rawValue).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)

        switch store.kind {
        case .hashtag:
          Section {
            TextField("#channel-name", text: $store.name)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } footer: {
            Text("Hashtag channels are public topics: the key is derived from the name, so anyone who knows the name can join.")
          }
        case .privateChannel:
          Section("Name") {
            TextField("Family", text: $store.name)
          }
          Section {
            HStack {
              TextField("32 hex characters", text: $store.secretHex)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              Button {
                store.send(.regenerateSecret)
              } label: {
                Image(systemName: "dice")
              }
              .accessibilityLabel("Generate new key")
            }
          } header: {
            Text("Secret key")
          } footer: {
            Text("Share the channel's QR code with the people you want in it. Keep the key private.")
          }
        case .join:
          Section {
            TextField("meshcore://channel/add?…", text: $store.link, axis: .vertical)
              .font(.callout.monospaced())
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Button {
              store.isScanning = true
            } label: {
              Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
          } footer: {
            if let resolved = store.resolved {
              Text("Joins “\(resolved.name)”.")
            } else {
              Text("Paste or scan a channel link shared from another MeshCore app.")
            }
          }
        }

        if let error = store.errorMessage {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if let slot = store.freeSlot {
          Section {
          } footer: {
            Text("Will be saved to slot \(slot) on the radio.")
          }
        }
      }
      .navigationTitle("Add Channel")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if store.isSaving {
            ProgressView()
          } else {
            Button("Add") { store.send(.saveTapped) }
              .disabled(store.resolved == nil || !store.session.status.isLinkUp)
          }
        }
      }
      .sheet(isPresented: $store.isScanning) {
        QRScannerView { store.send(.scanned($0)) }
      }
      .onAppear { store.send(.onAppear) }
    }
  }
}
