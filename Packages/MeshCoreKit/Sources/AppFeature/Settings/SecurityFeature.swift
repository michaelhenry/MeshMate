import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Identity key backup/restore and message signing.
@Reducer
struct SecurityFeature {
  @ObservableState
  struct State: Equatable {
    var privateKeyHex: String?
    var importHex = ""
    var signText = ""
    var signatureHex: String?
    var busy = false
    var notice: String?
    @Presents var alert: AlertState<Action.Alert>?
    @Shared(.radioSession) var session
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case exportTapped
    case importTapped
    case signTapped
    case exported(Data)
    case imported(SelfInfo)
    case signed(Data)
    case failed(String)
    case alert(PresentationAction<Alert>)

    enum Alert: Equatable {
      case confirmExport
      case confirmImport
    }
  }

  @Dependency(\.meshCore) var meshCore

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .exportTapped:
        state.alert = AlertState {
          TextState("Show private key?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmExport) { TextState("Show Key") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("Anyone with this key can impersonate your node and read your direct messages. Store it somewhere safe.")
        }
        return .none

      case .alert(.presented(.confirmExport)):
        state.busy = true
        return .run { send in
          do {
            await send(.exported(try await meshCore.exportPrivateKey()))
          } catch MeshCoreError.disabled {
            await send(.failed("This firmware was built without private key export."))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .exported(key):
        state.busy = false
        state.privateKeyHex = key.hexString
        return .none

      case .importTapped:
        guard let key = Data(hexString: state.importHex), key.count == 64 else {
          state.notice = "A private key is 64 bytes (128 hex characters)."
          return .none
        }
        state.alert = AlertState {
          TextState("Replace this radio's identity?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmImport) { TextState("Import") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("The radio takes on the imported identity. Contacts will need your new public key unless this is a restore.")
        }
        return .none

      case .alert(.presented(.confirmImport)):
        guard let key = Data(hexString: state.importHex) else { return .none }
        state.busy = true
        return .run { send in
          do {
            try await meshCore.perform(.importPrivateKey(key))
            await send(.imported(try await meshCore.appStart(appName: appName)))
          } catch MeshCoreError.disabled {
            await send(.failed("This firmware was built without private key import."))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .imported(info):
        state.busy = false
        state.importHex = ""
        state.$session.withLock { $0.selfInfo = info }
        state.notice = "Identity imported. Public key is now \(Format.shortKey(info.publicKey.hex))."
        return .none

      case .signTapped:
        let data = Data(state.signText.utf8)
        guard !data.isEmpty else { return .none }
        state.busy = true
        state.signatureHex = nil
        return .run { send in
          do {
            await send(.signed(try await meshCore.sign(data)))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .signed(signature):
        state.busy = false
        state.signatureHex = signature.hexString
        return .none

      case let .failed(message):
        state.busy = false
        state.notice = message
        return .none

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

struct SecurityView: View {
  @Bindable var store: StoreOf<SecurityFeature>

  var body: some View {
    Form {
      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      Section {
        if let me = store.session.selfInfo {
          ValueRow(title: "Public key", value: me.publicKey.hex, monospaced: true)
        }
        if let key = store.privateKeyHex {
          Text(key)
            .font(.caption.monospaced())
            .textSelection(.enabled)
          Button("Copy Private Key") { UIPasteboard.general.string = key }
        } else {
          Button("Export Private Key…") { store.send(.exportTapped) }
        }
      } header: {
        Text("Identity")
      }

      Section {
        TextField("128 hex characters", text: $store.importHex, axis: .vertical)
          .font(.caption.monospaced())
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Import Private Key…", role: .destructive) { store.send(.importTapped) }
          .disabled(store.importHex.isEmpty)
      } header: {
        Text("Restore")
      } footer: {
        Text("Restores a backed-up identity, e.g. after a factory reset or when moving to new hardware.")
      }

      Section {
        TextField("Text to sign", text: $store.signText, axis: .vertical)
        Button("Sign with Radio Key") { store.send(.signTapped) }
          .disabled(store.signText.isEmpty)
        if let signature = store.signatureHex {
          Text(signature)
            .font(.caption.monospaced())
            .textSelection(.enabled)
          Button("Copy Signature") { UIPasteboard.general.string = signature }
        }
      } header: {
        Text("Sign")
      } footer: {
        Text("Produces an Ed25519 signature anyone can verify against your public key.")
      }
    }
    .disabled(store.busy)
    .navigationTitle("Keys & Signing")
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}
