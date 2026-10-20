import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Tuning, flood scope (regions), Bluetooth PIN and board-specific variables.
@Reducer
struct AdvancedSettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.radioSession) var session
    var rxDelayBase = ""
    var airtimeFactor = ""
    var defaultScope: FloodScope?
    var defaultScopeDraft = ""
    var sessionScopeDraft = ""
    var sessionScopeLabel = "Default"
    var pin = ""
    var customVariables: [CustomVariable] = []
    var editingVariable: CustomVariable?
    var busy = false
    var notice: String?

    init() {
      if let pin = session.deviceInfo?.blePin, pin != 0 {
        self.pin = String(format: "%06d", Int(pin))
      }
    }

    var supportsDefaultScope: Bool { session.supports(13) }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case tuningLoaded(TuningParameters)
    case defaultScopeLoaded(FloodScope?)
    case customVariablesLoaded([CustomVariable])
    case saveTuningTapped
    case saveDefaultScopeTapped
    case clearDefaultScopeTapped
    case applySessionScopeTapped
    case unscopedTapped
    case savePinTapped
    case editVariableTapped(CustomVariable)
    case saveVariableTapped
    case done(String)
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
        let supportsScope = state.supportsDefaultScope
        return .run { send in
          if let tuning = try? await meshCore.tuningParameters() {
            await send(.tuningLoaded(tuning))
          }
          if supportsScope, let scope = try? await meshCore.defaultFloodScope() {
            await send(.defaultScopeLoaded(scope))
          }
          if let variables = try? await meshCore.customVariables() {
            await send(.customVariablesLoaded(variables))
          }
        }

      case let .tuningLoaded(tuning):
        state.rxDelayBase = String(format: "%g", tuning.rxDelayBase)
        state.airtimeFactor = String(format: "%g", tuning.airtimeFactor)
        return .none

      case let .defaultScopeLoaded(scope):
        state.defaultScope = scope
        state.defaultScopeDraft = scope?.name ?? ""
        return .none

      case let .customVariablesLoaded(variables):
        state.customVariables = variables
        return .none

      case .saveTuningTapped:
        guard let rx = Double(state.rxDelayBase), let af = Double(state.airtimeFactor),
              (0...20).contains(rx), (0...9).contains(af)
        else {
          state.notice = "RX delay base must be 0–20 and airtime factor 0–9."
          return .none
        }
        return perform(.setTuningParameters(TuningParameters(rxDelayBase: rx, airtimeFactor: af)), notice: "Tuning saved.", state: &state)

      case .saveDefaultScopeTapped:
        let name = state.defaultScopeDraft.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !name.isEmpty, name.utf8.count < 31 else {
          state.notice = "Enter a region name (up to 30 characters)."
          return .none
        }
        let scope = FloodScope(name: name, key: ChannelKeys.floodScopeKey(for: name))
        state.defaultScope = scope
        return perform(.setDefaultFloodScope(scope), notice: "Floods now default to region “\(name)”.", state: &state)

      case .clearDefaultScopeTapped:
        state.defaultScope = nil
        state.defaultScopeDraft = ""
        return perform(.setDefaultFloodScope(nil), notice: "Default region cleared.", state: &state)

      case .applySessionScopeTapped:
        let name = state.sessionScopeDraft.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        state.sessionScopeLabel = name.isEmpty ? "Default" : name
        let key: Data? = name.isEmpty ? nil : ChannelKeys.floodScopeKey(for: name)
        return perform(.setFloodScopeKey(key), notice: name.isEmpty ? "Using the default region." : "Floods scoped to “\(name)” until the radio restarts.", state: &state)

      case .unscopedTapped:
        state.sessionScopeLabel = "Unscoped"
        return perform(.setUnscopedFlood, notice: "Floods are unscoped (reach every region) until the radio restarts.", state: &state)

      case .savePinTapped:
        let trimmed = state.pin.trimmingCharacters(in: .whitespaces)
        let pin = UInt32(trimmed) ?? 0
        guard trimmed.isEmpty || (trimmed.count == 6 && (100_000...999_999).contains(pin)) else {
          state.notice = "Use a 6-digit PIN (not starting with 0), or leave empty for a random PIN shown on screen."
          return .none
        }
        return perform(.setDevicePin(trimmed.isEmpty ? 0 : pin), notice: "PIN saved. It takes effect after a reboot; re-pair in iOS Bluetooth settings if needed.", state: &state)

      case let .editVariableTapped(variable):
        state.editingVariable = variable
        return .none

      case .saveVariableTapped:
        guard let variable = state.editingVariable else { return .none }
        state.editingVariable = nil
        if let index = state.customVariables.firstIndex(where: { $0.name == variable.name }) {
          state.customVariables[index] = variable
        }
        return perform(.setCustomVariable(name: variable.name, value: variable.value), notice: "\(variable.name) set to \(variable.value).", state: &state)

      case let .done(notice):
        state.busy = false
        state.notice = notice
        return .none

      case let .failed(message):
        state.busy = false
        state.notice = message
        return .none
      }
    }
  }

  private func perform(_ command: Command, notice: String, state: inout State) -> Effect<Action> {
    state.busy = true
    state.notice = nil
    return .run { send in
      do {
        try await meshCore.perform(command)
        await send(.done(notice))
      } catch {
        await send(.failed(error.localizedDescription))
      }
    }
  }
}

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<AdvancedSettingsFeature>

  var body: some View {
    Form {
      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      Section {
        LabeledContent("RX delay base") {
          TextField("0", text: $store.rxDelayBase)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
        }
        LabeledContent("Airtime factor") {
          TextField("1", text: $store.airtimeFactor)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
        }
        Button("Save Tuning") { store.send(.saveTuningTapped) }
      } header: {
        Text("Tuning")
      } footer: {
        Text("Advanced radio timing. Leave at defaults unless your mesh operators advise otherwise.")
      }

      Section {
        if store.supportsDefaultScope {
          LabeledContent("Default region", value: store.defaultScope?.name ?? "None")
          TextField("Region name (e.g. melbourne)", text: $store.defaultScopeDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          HStack {
            Button("Save Default") { store.send(.saveDefaultScopeTapped) }
            Spacer()
            Button("Clear", role: .destructive) { store.send(.clearDefaultScopeTapped) }
          }
          .buttonStyle(.borderless)
        }
        LabeledContent("This session", value: store.sessionScopeLabel)
        TextField("Temporary region (blank = default)", text: $store.sessionScopeDraft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        HStack {
          Button("Apply") { store.send(.applySessionScopeTapped) }
          Spacer()
          Button("Unscoped") { store.send(.unscopedTapped) }
        }
        .buttonStyle(.borderless)
      } header: {
        Text("Flood Scope (Regions)")
      } footer: {
        Text("Regions limit how far flood messages travel: repeaters only forward floods for regions they serve.")
      }

      Section {
        TextField("6-digit PIN", text: $store.pin)
          .keyboardType(.numberPad)
        Button("Save PIN") { store.send(.savePinTapped) }
      } header: {
        Text("Bluetooth PIN")
      } footer: {
        Text("Leave empty to use a random PIN displayed on the radio's screen.")
      }

      Section {
        if store.customVariables.isEmpty {
          Text("No board variables reported.").foregroundStyle(.secondary)
        }
        ForEach(store.customVariables) { variable in
          Button {
            store.send(.editVariableTapped(variable))
          } label: {
            LabeledContent(variable.name, value: variable.value)
          }
          .foregroundStyle(.primary)
        }
      } header: {
        Text("Board Variables")
      } footer: {
        Text("Hardware-specific settings such as GPS (gps = 1 to enable) and its update interval.")
      }
    }
    .disabled(store.busy)
    .navigationTitle("Advanced")
    .task { await store.send(.task).finish() }
    .alert(
      store.editingVariable?.name ?? "",
      isPresented: Binding(
        get: { store.editingVariable != nil },
        set: { if !$0 { store.send(.binding(.set(\.editingVariable, nil))) } }
      )
    ) {
      TextField("Value", text: Binding(
        get: { store.editingVariable?.value ?? "" },
        set: { value in
          if var variable = store.editingVariable {
            variable.value = value
            store.send(.binding(.set(\.editingVariable, variable)))
          }
        }
      ))
      Button("Save") { store.send(.saveVariableTapped) }
      Button("Cancel", role: .cancel) {}
    }
  }
}
