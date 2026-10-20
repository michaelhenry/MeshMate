import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Finds nearby companion radios and asks the parent to connect.
@Reducer
struct ConnectionFeature {
  @ObservableState
  struct State: Equatable {
    var radios: [DiscoveredRadio] = []
    var bluetoothState: BluetoothState = .unknown
    @Shared(.radioSession) var session
    @Shared(.lastRadio) var lastRadio
  }

  enum Action {
    case task
    case bluetoothStateChanged(BluetoothState)
    case radiosUpdated([DiscoveredRadio])
    case radioTapped(RadioIdentifier)
    case delegate(Delegate)

    enum Delegate {
      case connect(RadioIdentifier)
    }
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              for await bluetooth in await meshCore.bluetoothState() {
                await send(.bluetoothStateChanged(bluetooth))
              }
            }
            group.addTask {
              for await radios in await meshCore.scan() {
                await send(.radiosUpdated(radios))
              }
            }
          }
        }

      case let .bluetoothStateChanged(bluetooth):
        state.bluetoothState = bluetooth
        return .none

      case let .radiosUpdated(radios):
        state.radios = radios
        return .none

      case let .radioTapped(id):
        return .send(.delegate(.connect(id)))

      case .delegate:
        return .none
      }
    }
  }

  @Dependency(\.meshCore) var meshCore
}

struct ConnectionView: View {
  let store: StoreOf<ConnectionFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
              .font(.system(size: 44))
              .foregroundStyle(.tint)
            Text("Connect your radio")
              .font(.title2.bold())
            Text("Power on your Heltec V4 (or any MeshCore companion) running the **Companion BLE** firmware. The first time, iOS asks for the PIN shown on the radio's screen.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }

        if !store.bluetoothState.isUsable, store.bluetoothState != .unknown {
          Section {
            Label(store.bluetoothState.message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }

        if let error = store.session.lastError {
          Section {
            Label(error, systemImage: "xmark.octagon.fill")
              .foregroundStyle(.red)
          }
        }

        Section {
          if store.radios.isEmpty {
            HStack(spacing: 12) {
              ProgressView()
              Text("Searching for radios…")
                .foregroundStyle(.secondary)
            }
          }
          ForEach(store.radios) { radio in
            radioRow(radio)
          }
        } header: {
          Text("Nearby")
        }

        Section {
          radioRow(.demo)
        } header: {
          Text("No radio handy?")
        } footer: {
          Text("The demo radio simulates MeshCore firmware inside the app so you can explore every screen, including in the Simulator.")
        }
      }
      .navigationTitle("Radios")
      .toolbar {
        if store.lastRadio != nil {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
          }
        }
      }
      .task { await store.send(.task).finish() }
    }
  }

  @ViewBuilder
  private func radioRow(_ radio: DiscoveredRadio) -> some View {
    let isConnecting = store.session.status == .connecting(radio.id) || store.session.status == .syncing(radio.id)
    Button {
      store.send(.radioTapped(radio.id))
    } label: {
      HStack(spacing: 12) {
        Image(systemName: radio.id == .demo ? "wand.and.stars" : "dot.radiowaves.left.and.right")
          .frame(width: 28)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(radio.name)
            .foregroundStyle(.primary)
          if radio.isSystemConnected {
            Text("Connected to iPhone")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if let rssi = radio.rssi {
            Text("\(rssi) dBm")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if isConnecting {
          ProgressView()
        } else if store.session.status == .connected(radio.id) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
      }
    }
    .disabled(isConnecting)
  }
}
