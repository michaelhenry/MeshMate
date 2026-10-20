import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Zero-hop node discovery: asks nodes in direct radio range to identify
/// themselves (repeaters and sensors answer, with signal reports).
@Reducer
struct NodeDiscoveryFeature {
  @ObservableState
  struct State: Equatable {
    var includeRepeaters = true
    var includeSensors = true
    var tag: UInt32?
    var isScanning = false
    var results: IdentifiedArrayOf<NodeDiscoveryResponse> = []
    var errorMessage: String?
    @Shared(.contacts) var contacts

    var filter: UInt8 {
      var value: UInt8 = 0
      if includeRepeaters { value |= 1 << NodeType.repeater.rawValue }
      if includeSensors { value |= 1 << NodeType.sensor.rawValue }
      return value
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case scanTapped
    case push(PushEvent)
    case scanFinished
    case failed(String)
  }

  private enum CancelID { case scanWindow }

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
        return .merge(
          .send(.scanTapped),
          .run { send in
            for await push in await meshCore.pushes() {
              await send(.push(push))
            }
          }
        )

      case .scanTapped:
        guard state.filter != 0 else { return .none }
        let tag = withRandomNumberGenerator { UInt32.random(in: 1 ... .max, using: &$0) }
        state.tag = tag
        state.isScanning = true
        state.results = []
        state.errorMessage = nil
        var w = ByteWriter()
        w.u8(ControlType.nodeDiscoverRequest) // full keys (prefix-only flag clear)
        w.u8(state.filter)
        w.u32(tag)
        let payload = w.data
        return .run { send in
          do {
            try await meshCore.perform(.sendControlData(payload))
            try await clock.sleep(for: .seconds(12))
            await send(.scanFinished)
          } catch is CancellationError {
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.scanWindow, cancelInFlight: true)

      case let .push(.controlData(data)):
        guard let response = data.discoveryResponse, response.tag == state.tag else { return .none }
        state.results[id: response.id] = response
        return .none

      case .push:
        return .none

      case .scanFinished:
        state.isScanning = false
        return .none

      case let .failed(message):
        state.isScanning = false
        state.errorMessage = message
        return .none
      }
    }
  }
}

struct NodeDiscoveryView: View {
  @Bindable var store: StoreOf<NodeDiscoveryFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Toggle("Repeaters", isOn: $store.includeRepeaters)
          Toggle("Sensors", isOn: $store.includeSensors)
          Button {
            store.send(.scanTapped)
          } label: {
            HStack {
              Label("Discover", systemImage: "dot.radiowaves.left.and.right")
              Spacer()
              if store.isScanning { ProgressView() }
            }
          }
          .disabled(store.isScanning || store.filter == 0)
        } footer: {
          Text("Only nodes within direct radio range (zero hop) respond. SNR shows how well each side hears the other.")
        }

        if let error = store.errorMessage {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }

        Section("Found \(store.results.count)") {
          ForEach(store.results) { node in
            let contact = node.publicKey.flatMap { store.contacts[id: $0] }
            HStack(spacing: 12) {
              NodeAvatar(type: node.nodeType, size: 32)
              VStack(alignment: .leading) {
                Text(contact?.displayName ?? Format.shortKey(node.keyBytes.hexString))
                Text("Heard us \(Format.snr(node.snrIn)) · we heard \(Format.snr(node.snrOut)) · \(node.rssi) dBm")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle("Nearby Nodes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await store.send(.task).finish() }
    }
  }
}
