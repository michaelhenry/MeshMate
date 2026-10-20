import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// LoRa frequency/modulation, transmit power, client repeat and path hashing.
@Reducer
struct RadioSettingsFeature {
  static let bandwidths: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

  @ObservableState
  struct State: Equatable {
    @Shared(.radioSession) var session
    var presets: [RadioPreset] = RadioPreset.builtIn
    var frequency = ""
    var bandwidth: Double = 250
    var spreadingFactor = 10
    var codingRate = 5
    var txPower = 20
    var maxTxPower = 22
    var clientRepeat = false
    var pathHashSize = 1
    var allowedRepeat: [FrequencyRange] = []
    var isSaving = false
    var notice: String?

    init() {
      if let me = session.selfInfo {
        frequency = String(format: "%.3f", me.radio.frequencyMHz)
        bandwidth = me.radio.bandwidthKHz
        spreadingFactor = Int(me.radio.spreadingFactor)
        codingRate = Int(me.radio.codingRate)
        txPower = Int(me.txPower)
        maxTxPower = Int(me.maxTxPower)
      }
      if let info = session.deviceInfo {
        clientRepeat = info.clientRepeat
        pathHashSize = Int(info.pathHashMode) + 1
      }
    }

    var radio: RadioParameters? {
      guard let mhz = Double(frequency) else { return nil }
      let radio = RadioParameters(
        frequencyMHz: mhz,
        bandwidthKHz: bandwidth,
        spreadingFactor: UInt8(clamping: spreadingFactor),
        codingRate: UInt8(clamping: codingRate)
      )
      return radio.isValid ? radio : nil
    }

    var matchingPreset: RadioPreset? {
      guard let radio else { return nil }
      return presets.first { $0.radio == radio }
    }

    var supportsClientRepeat: Bool { session.supports(9) }
    var supportsPathHash: Bool { session.supports(10) }

    var repeatAllowedHere: Bool {
      guard let radio else { return false }
      return allowedRepeat.isEmpty || allowedRepeat.contains { $0.contains(radio.frequencyKHz) }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case presetsLoaded([RadioPreset])
    case allowedRepeatLoaded([FrequencyRange])
    case presetSelected(RadioPreset)
    case applyTapped
    case applied(SelfInfo, DeviceInfo)
    case failed(String)
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.presets) var presetsClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let supportsRepeat = state.supportsClientRepeat
        return .merge(
          .run { send in
            if let presets = try? await presetsClient.fetch(), !presets.isEmpty {
              await send(.presetsLoaded(presets))
            }
          },
          .run { send in
            guard supportsRepeat, let ranges = try? await meshCore.allowedRepeatFrequencies() else { return }
            await send(.allowedRepeatLoaded(ranges))
          }
        )

      case let .presetsLoaded(presets):
        state.presets = presets
        return .none

      case let .allowedRepeatLoaded(ranges):
        state.allowedRepeat = ranges
        return .none

      case let .presetSelected(preset):
        state.frequency = String(format: "%.3f", preset.radio.frequencyMHz)
        state.bandwidth = preset.radio.bandwidthKHz
        state.spreadingFactor = Int(preset.radio.spreadingFactor)
        state.codingRate = Int(preset.radio.codingRate)
        if let size = preset.pathHashSize { state.pathHashSize = size }
        return .none

      case .applyTapped:
        guard let radio = state.radio else {
          state.notice = "Check the frequency (150–2500 MHz), SF (5–12) and CR (5–8)."
          return .none
        }
        if state.clientRepeat && !state.repeatAllowedHere {
          state.notice = "Client repeat isn't allowed on this frequency."
          return .none
        }
        state.isSaving = true
        state.notice = nil
        let repeatFlag: Bool? = state.supportsClientRepeat ? state.clientRepeat : nil
        let power = Int8(clamping: state.txPower)
        let hashMode: UInt8? = state.supportsPathHash ? UInt8(clamping: state.pathHashSize - 1) : nil
        let currentHashMode = state.session.deviceInfo?.pathHashMode
        let currentPower = state.session.selfInfo?.txPower
        return .run { send in
          do {
            try await meshCore.perform(.setRadioParameters(radio, clientRepeat: repeatFlag))
            if power != currentPower {
              try await meshCore.perform(.setTxPower(power))
            }
            if let hashMode, hashMode != currentHashMode {
              try await meshCore.perform(.setPathHashMode(hashMode))
            }
            let device = try await meshCore.deviceQuery()
            let me = try await meshCore.appStart(appName: appName)
            await send(.applied(me, device))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .applied(me, device):
        state.isSaving = false
        state.$session.withLock {
          $0.selfInfo = me
          $0.deviceInfo = device
        }
        state.notice = "Applied. Every node you talk to must use the same frequency, bandwidth, SF and CR."
        return .none

      case let .failed(message):
        state.isSaving = false
        state.notice = message
        return .none
      }
    }
  }
}

struct RadioSettingsView: View {
  @Bindable var store: StoreOf<RadioSettingsFeature>

  var body: some View {
    Form {
      Section {
        Menu {
          ForEach(store.presets) { preset in
            Button {
              store.send(.presetSelected(preset))
            } label: {
              Text(preset.title)
              Text(preset.radio.summary)
            }
          }
        } label: {
          LabeledContent("Preset") {
            Text(store.matchingPreset?.title ?? "Custom")
          }
        }
      } footer: {
        Text("Community presets from meshcore.nz. Use the one your local mesh uses.")
      }

      Section("LoRa") {
        LabeledContent("Frequency (MHz)") {
          TextField("915.800", text: $store.frequency)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
        }
        Picker("Bandwidth", selection: $store.bandwidth) {
          ForEach(RadioSettingsFeature.bandwidths, id: \.self) { bw in
            Text("\(bw, specifier: "%g") kHz").tag(bw)
          }
        }
        Stepper("Spreading factor: \(store.spreadingFactor)", value: $store.spreadingFactor, in: 5...12)
        Stepper("Coding rate: 4/\(store.codingRate)", value: $store.codingRate, in: 5...8)
      }

      Section {
        Stepper("TX power: \(store.txPower) dBm", value: $store.txPower, in: -9...store.maxTxPower)
      } footer: {
        Text("Maximum for this board: \(store.maxTxPower) dBm. Respect your local limits.")
      }

      if store.supportsPathHash {
        Section {
          Picker("Path hash size", selection: $store.pathHashSize) {
            Text("1 byte").tag(1)
            Text("2 bytes").tag(2)
            Text("3 bytes").tag(3)
          }
        } footer: {
          Text("Larger hashes reduce collisions in big meshes but shorten the maximum hop count. Match your network.")
        }
      }

      if store.supportsClientRepeat {
        Section {
          Toggle("Client repeat", isOn: $store.clientRepeat)
        } footer: {
          if store.allowedRepeat.isEmpty {
            Text("Lets this companion relay packets for others.")
          } else {
            Text("Only allowed on: " + store.allowedRepeat.map { String(format: "%.3f MHz", Double($0.lowerKHz) / 1000) }.joined(separator: ", "))
          }
        }
      }

      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      Section {
        Button {
          store.send(.applyTapped)
        } label: {
          HStack {
            Text("Apply to Radio")
            Spacer()
            if store.isSaving { ProgressView() }
          }
        }
        .disabled(store.isSaving || store.radio == nil)
      }
    }
    .navigationTitle("Radio")
    .task { await store.send(.task).finish() }
  }
}
