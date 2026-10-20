import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

let appName = "MeshMate"

@Reducer
struct SettingsFeature {
  @Reducer
  enum Path {
    case identity(IdentitySettingsFeature)
    case radio(RadioSettingsFeature)
    case network(NetworkSettingsFeature)
    case advanced(AdvancedSettingsFeature)
    case diagnostics(DiagnosticsFeature)
    case console(ConsoleFeature)
    case security(SecurityFeature)
  }

  @ObservableState
  struct State: Equatable {
    var path = StackState<Path.State>()
    var isWorking = false
    var notice: String?
    @Presents var alert: AlertState<Action.Alert>?
    @Shared(.radioSession) var session
    @Shared(.notificationsEnabled) var notificationsEnabled
    @Shared(.lastRadio) var lastRadio
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case path(StackActionOf<Path>)
    case refreshTapped
    case notificationsToggled(Bool)
    case batteryLoaded(BatteryAndStorage)
    case syncClockTapped
    case rebootTapped
    case factoryResetTapped
    case disconnectTapped
    case forgetTapped
    case connectTapped
    case finished(notice: String?)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    enum Alert: Equatable {
      case confirmReboot
      case confirmFactoryReset
      case confirmForget
    }

    enum Delegate {
      case disconnect(forget: Bool)
      case showConnection
    }
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.date.now) var now
  @Dependency(\.notifications) var notifications

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case let .notificationsToggled(enabled):
        state.$notificationsEnabled.withLock { $0 = enabled }
        guard enabled else { return .none }
        return .run { _ in _ = await notifications.requestAuthorization() }

      case .refreshTapped:
        return .run { send in
          do {
            await send(.batteryLoaded(try await meshCore.batteryAndStorage()))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case let .batteryLoaded(battery):
        state.$session.withLock { $0.battery = battery }
        return .none

      case .syncClockTapped:
        state.isWorking = true
        let date = now
        return .run { send in
          do {
            try await meshCore.syncTime(date)
            let radioTime = try await meshCore.deviceTime()
            let drift = Int(radioTime) - Int(date.timeIntervalSince1970)
            await send(.finished(notice: "Radio clock set (drift \(drift)s)."))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case .rebootTapped:
        state.alert = AlertState {
          TextState("Reboot radio?")
        } actions: {
          ButtonState(action: .confirmReboot) { TextState("Reboot") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("The app reconnects automatically once the radio is back.")
        }
        return .none

      case .factoryResetTapped:
        state.alert = AlertState {
          TextState("Factory reset radio?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmFactoryReset) { TextState("Erase Everything") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("Erases the radio's identity, contacts, channels and settings. This can't be undone. Messages stored in this app are kept.")
        }
        return .none

      case .forgetTapped:
        state.alert = AlertState {
          TextState("Forget this radio?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmForget) { TextState("Forget") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("Disconnects and stops reconnecting automatically. To also remove the Bluetooth pairing, forget the device in iOS Settings › Bluetooth.")
        }
        return .none

      case .alert(.presented(.confirmReboot)):
        return .run { send in
          try? await meshCore.perform(.reboot)
          await send(.finished(notice: "Rebooting…"))
        }

      case .alert(.presented(.confirmFactoryReset)):
        return .run { send in
          try? await meshCore.perform(.factoryReset)
          await send(.delegate(.disconnect(forget: true)))
        }

      case .alert(.presented(.confirmForget)):
        return .send(.delegate(.disconnect(forget: true)))

      case .disconnectTapped:
        return .send(.delegate(.disconnect(forget: false)))

      case .connectTapped:
        return .send(.delegate(.showConnection))

      case let .finished(notice):
        state.isWorking = false
        state.notice = notice
        return .none

      case .alert, .path, .delegate:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
    .ifLet(\.$alert, action: \.alert)
  }
}

extension SettingsFeature.Path.State: Equatable {}

struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      form
        .navigationTitle("Settings")
        .refreshable { await store.send(.refreshTapped).finish() }
    } destination: { store in
      switch store.case {
      case let .identity(store): IdentitySettingsView(store: store)
      case let .radio(store): RadioSettingsView(store: store)
      case let .network(store): NetworkSettingsView(store: store)
      case let .advanced(store): AdvancedSettingsView(store: store)
      case let .diagnostics(store): DiagnosticsView(store: store)
      case let .console(store): ConsoleView(store: store)
      case let .security(store): SecurityView(store: store)
      }
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  private var linkUp: Bool { store.session.status.isLinkUp }

  @ViewBuilder
  private var form: some View {
    Form {
      deviceSection

      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      Section("Configure") {
        NavigationLink(state: SettingsFeature.Path.State.identity(IdentitySettingsFeature.State())) {
          Label("Name & Location", systemImage: "person.text.rectangle")
        }
        NavigationLink(state: SettingsFeature.Path.State.radio(RadioSettingsFeature.State())) {
          Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
        }
        NavigationLink(state: SettingsFeature.Path.State.network(NetworkSettingsFeature.State())) {
          Label("Contacts & Privacy", systemImage: "hand.raised")
        }
        NavigationLink(state: SettingsFeature.Path.State.advanced(AdvancedSettingsFeature.State())) {
          Label("Advanced", systemImage: "gearshape.2")
        }
      }
      .disabled(!linkUp)

      Section("Tools") {
        NavigationLink(state: SettingsFeature.Path.State.diagnostics(DiagnosticsFeature.State())) {
          Label("Diagnostics & RX Log", systemImage: "waveform.path.ecg.rectangle")
        }
        NavigationLink(state: SettingsFeature.Path.State.console(ConsoleFeature.State())) {
          Label("Radio Console", systemImage: "terminal")
        }
        .disabled(!store.session.supports(14))
        NavigationLink(state: SettingsFeature.Path.State.security(SecurityFeature.State())) {
          Label("Keys & Signing", systemImage: "key")
        }
        Button {
          store.send(.syncClockTapped)
        } label: {
          Label("Sync Radio Clock", systemImage: "clock.arrow.2.circlepath")
        }
      }
      .disabled(!linkUp)

      Section("App") {
        Toggle(isOn: Binding(
          get: { store.notificationsEnabled },
          set: { store.send(.notificationsToggled($0)) }
        )) {
          Label("Message Notifications", systemImage: "bell.badge")
        }
      }

      Section {
        if linkUp {
          Button("Disconnect") { store.send(.disconnectTapped) }
          Button("Reboot Radio") { store.send(.rebootTapped) }
          Button("Factory Reset Radio…", role: .destructive) { store.send(.factoryResetTapped) }
        } else {
          Button("Connect a Radio") { store.send(.connectTapped) }
        }
        if store.lastRadio != nil {
          Button("Forget This Radio", role: .destructive) { store.send(.forgetTapped) }
        }
      }

      Section {
      } footer: {
        Text("MeshMate · MeshCore companion protocol v\(Command.appProtocolVersion)+ · supports firmware up to v1.18")
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private var deviceSection: some View {
    Section {
      if let me = store.session.selfInfo {
        HStack(spacing: 14) {
          NodeAvatar(type: .chat, size: 48)
          VStack(alignment: .leading, spacing: 2) {
            Text(me.name).font(.headline)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let info = store.session.deviceInfo {
          ValueRow(title: "Hardware", value: info.manufacturer)
          ValueRow(title: "Firmware", value: "\(info.firmwareVersion) (\(info.firmwareBuildDate))")
        }
        if let battery = store.session.battery {
          LabeledContent("Battery") {
            HStack {
              Text("\(battery.estimatedPercent)% · \(Format.voltage(battery.batteryMillivolts))")
              Image(systemName: batterySymbol(battery.estimatedPercent))
            }
          }
          if let storage = Format.storage(usedKB: battery.storageUsedKB, totalKB: battery.storageTotalKB) {
            ValueRow(title: "Storage", value: storage)
          }
        }
        ValueRow(title: "Radio", value: me.radio.summary)
        ValueRow(title: "TX power", value: "\(me.txPower) dBm")
        ValueRow(title: "Public key", value: Format.shortKey(me.publicKey.hex), monospaced: true)
      } else {
        Label(statusText, systemImage: "antenna.radiowaves.left.and.right.slash")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Radio")
    }
  }

  private var statusText: String {
    switch store.session.status {
    case .disconnected: "Not connected"
    case .connecting: "Connecting…"
    case .syncing: "Syncing…"
    case .connected(.demo): "Connected (demo)"
    case .connected: "Connected via Bluetooth"
    }
  }

  private func batterySymbol(_ percent: Int) -> String {
    switch percent {
    case ..<10: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
  }
}
