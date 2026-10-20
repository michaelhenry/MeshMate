import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Contact auto-add, telemetry permissions and ACK behaviour.
@Reducer
struct NetworkSettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.radioSession) var session
    var manualAdd = false
    var autoAddChat = true
    var autoAddRepeater = true
    var autoAddRoom = true
    var autoAddSensor = true
    var overwriteOldest = false
    var maxHops = 0
    var telemetryBase: TelemetryMode = .deny
    var telemetryLocation: TelemetryMode = .deny
    var telemetryEnvironment: TelemetryMode = .deny
    var multiAcks = 0
    var autoAddLoaded = false
    var isSaving = false
    var notice: String?

    init() {
      if let me = session.selfInfo {
        manualAdd = me.isManualContactAdd
        telemetryBase = me.telemetryModes.base
        telemetryLocation = me.telemetryModes.location
        telemetryEnvironment = me.telemetryModes.environment
        multiAcks = Int(me.multiAcks)
      }
    }

    var supportsAutoAddConfig: Bool { session.supports(12) }

    mutating func apply(_ config: AutoAddConfig) {
      autoAddChat = config.flags.contains(.chat)
      autoAddRepeater = config.flags.contains(.repeater)
      autoAddRoom = config.flags.contains(.roomServer)
      autoAddSensor = config.flags.contains(.sensor)
      overwriteOldest = config.flags.contains(.overwriteOldest)
      maxHops = Int(config.maxHops)
      autoAddLoaded = true
    }

    var autoAddConfig: AutoAddConfig {
      var flags: AutoAddConfig.Flags = []
      if autoAddChat { flags.insert(.chat) }
      if autoAddRepeater { flags.insert(.repeater) }
      if autoAddRoom { flags.insert(.roomServer) }
      if autoAddSensor { flags.insert(.sensor) }
      if overwriteOldest { flags.insert(.overwriteOldest) }
      return AutoAddConfig(flags: flags, maxHops: UInt8(clamping: maxHops))
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case autoAddLoaded(AutoAddConfig)
    case saveTapped
    case saved(SelfInfo)
    case failed(String)
  }

  @Dependency(\.meshCore) var meshCore

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        guard state.supportsAutoAddConfig else { return .none }
        return .run { send in
          if let config = try? await meshCore.autoAddConfig() {
            await send(.autoAddLoaded(config))
          }
        }

      case let .autoAddLoaded(config):
        state.apply(config)
        return .none

      case .saveTapped:
        guard let me = state.session.selfInfo else { return .none }
        state.isSaving = true
        state.notice = nil
        let manual: UInt8 = state.manualAdd ? (me.manualAddContacts | 0x01) : (me.manualAddContacts & ~0x01)
        let modes = TelemetryModes(base: state.telemetryBase, location: state.telemetryLocation, environment: state.telemetryEnvironment)
        let multiAcks = UInt8(clamping: state.multiAcks)
        let autoAdd: AutoAddConfig? = state.supportsAutoAddConfig && state.autoAddLoaded ? state.autoAddConfig : nil
        return .run { send in
          do {
            try await meshCore.perform(.setOtherParameters(
              manualAddContacts: manual,
              telemetryModes: modes,
              advertLocationPolicy: me.advertLocationPolicy,
              multiAcks: multiAcks
            ))
            if let autoAdd {
              try await meshCore.perform(.setAutoAddConfig(autoAdd))
            }
            await send(.saved(try await meshCore.appStart(appName: appName)))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .saved(info):
        state.isSaving = false
        state.$session.withLock { $0.selfInfo = info }
        state.notice = "Saved."
        return .none

      case let .failed(message):
        state.isSaving = false
        state.notice = message
        return .none
      }
    }
  }
}

struct NetworkSettingsView: View {
  @Bindable var store: StoreOf<NetworkSettingsFeature>

  var body: some View {
    Form {
      Section {
        Toggle("Add contacts manually", isOn: $store.manualAdd)
      } footer: {
        Text("When on, adverts from new nodes appear under Contacts › Heard Adverts instead of being added automatically.")
      }

      if store.manualAdd && store.supportsAutoAddConfig {
        Section {
          Toggle("Companions", isOn: $store.autoAddChat)
          Toggle("Repeaters", isOn: $store.autoAddRepeater)
          Toggle("Room servers", isOn: $store.autoAddRoom)
          Toggle("Sensors", isOn: $store.autoAddSensor)
          Stepper(store.maxHops == 0 ? "Any distance" : "Within \(store.maxHops) hops", value: $store.maxHops, in: 0...64)
        } header: {
          Text("Still add automatically")
        }
      }

      if store.supportsAutoAddConfig {
        Section {
          Toggle("Overwrite oldest when full", isOn: $store.overwriteOldest)
        } footer: {
          Text("When the radio's contact table is full, replace the least recently heard non-favourite contact.")
        }
      }

      Section {
        modePicker("Battery & basic", selection: $store.telemetryBase)
        modePicker("Location", selection: $store.telemetryLocation)
        modePicker("Environment sensors", selection: $store.telemetryEnvironment)
      } header: {
        Text("Who can request my telemetry")
      } footer: {
        Text("“Allowed contacts” uses per-contact permissions.")
      }

      Section {
        Stepper("Extra ACKs: \(store.multiAcks)", value: $store.multiAcks, in: 0...2)
      } footer: {
        Text("Send additional acknowledgements to improve delivery confirmation on lossy links, at the cost of airtime.")
      }

      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      Section {
        Button {
          store.send(.saveTapped)
        } label: {
          HStack {
            Text("Save to Radio")
            Spacer()
            if store.isSaving { ProgressView() }
          }
        }
        .disabled(store.isSaving)
      }
    }
    .navigationTitle("Contacts & Privacy")
    .task { await store.send(.task).finish() }
  }

  private func modePicker(_ title: String, selection: Binding<TelemetryMode>) -> some View {
    Picker(title, selection: selection) {
      ForEach(TelemetryMode.allCases, id: \.self) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
  }
}
