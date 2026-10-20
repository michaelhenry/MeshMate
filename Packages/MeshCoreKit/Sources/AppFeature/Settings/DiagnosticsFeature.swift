import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Live radio statistics, own telemetry and a log of packets heard on air.
@Reducer
struct DiagnosticsFeature {
  struct LogItem: Equatable, Identifiable {
    var id: UUID
    var date: Date
    var entry: RxLogEntry
  }

  @ObservableState
  struct State: Equatable {
    var core: CoreStats?
    var radio: RadioStats?
    var packets: PacketStats?
    var telemetry: [TelemetryReading] = []
    var log: [LogItem] = []
    var isPaused = false
    var notice: String?
    @Shared(.radioSession) var session

    var supportsStats: Bool { session.supports(8) }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case refresh
    case statsLoaded(DeviceStats)
    case telemetryTapped
    case telemetryLoaded([TelemetryReading])
    case push(PushEvent)
    case clearLogTapped
    case failed(String)
  }

  static let logLimit = 300

  @Dependency(\.meshCore) var meshCore
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
        return .merge(
          .run { send in
            for await push in await meshCore.pushes() {
              await send(.push(push))
            }
          },
          .run { send in
            await send(.refresh)
            for await _ in clock.timer(interval: .seconds(10)) {
              await send(.refresh)
            }
          }
        )

      case .refresh:
        guard state.supportsStats else { return .none }
        return .run { send in
          for type in StatsType.allCases {
            if let stats = try? await meshCore.stats(type) {
              await send(.statsLoaded(stats))
            }
          }
        }

      case let .statsLoaded(stats):
        switch stats {
        case let .core(value): state.core = value
        case let .radio(value): state.radio = value
        case let .packets(value): state.packets = value
        }
        return .none

      case .telemetryTapped:
        return .run { send in
          do {
            await send(.telemetryLoaded(try await meshCore.selfTelemetry()))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .telemetryLoaded(readings):
        state.telemetry = readings
        return .none

      case let .push(.logRxData(entry)):
        guard !state.isPaused else { return .none }
        state.log.insert(LogItem(id: uuid(), date: now, entry: entry), at: 0)
        if state.log.count > Self.logLimit {
          state.log.removeLast(state.log.count - Self.logLimit)
        }
        return .none

      case .push:
        return .none

      case .clearLogTapped:
        state.log.removeAll()
        return .none

      case let .failed(message):
        state.notice = message
        return .none
      }
    }
  }
}

struct DiagnosticsView: View {
  @Bindable var store: StoreOf<DiagnosticsFeature>

  var body: some View {
    List {
      if let notice = store.notice {
        Section { Label(notice, systemImage: "info.circle") }
      }

      if store.supportsStats {
        Section("Device") {
          if let core = store.core {
            LabeledContent("Battery", value: Format.voltage(core.batteryMillivolts))
            LabeledContent("Uptime", value: Format.duration(seconds: core.uptimeSeconds))
            LabeledContent("TX queue", value: "\(core.queueLength)")
            if core.errorFlags != 0 {
              LabeledContent("Error flags", value: String(format: "0x%04X", core.errorFlags))
            }
          } else {
            ProgressView()
          }
        }
        Section("Radio") {
          if let radio = store.radio {
            LabeledContent("Noise floor", value: "\(radio.noiseFloor) dBm")
            LabeledContent("Last RSSI", value: "\(radio.lastRSSI) dBm")
            LabeledContent("Last SNR", value: Format.snr(radio.lastSNR))
            LabeledContent("Airtime TX / RX", value: "\(Format.duration(seconds: radio.txAirtimeSeconds)) / \(Format.duration(seconds: radio.rxAirtimeSeconds))")
          }
        }
        Section("Packets") {
          if let packets = store.packets {
            LabeledContent("Received", value: "\(packets.received) (\(packets.receivedFlood) flood, \(packets.receivedDirect) direct)")
            LabeledContent("Sent", value: "\(packets.sent) (\(packets.sentFlood) flood, \(packets.sentDirect) direct)")
            LabeledContent("Receive errors", value: "\(packets.receiveErrors)")
          }
        }
      } else {
        Section {
          Text("Statistics need companion firmware v1.9 or newer.").foregroundStyle(.secondary)
        }
      }

      Section("My Telemetry") {
        Button("Read Sensors") { store.send(.telemetryTapped) }
        TelemetryList(readings: store.telemetry)
      }

      Section {
        if store.log.isEmpty {
          Text("Waiting for packets…").foregroundStyle(.secondary)
        }
        ForEach(store.log) { item in
          RxLogRow(item: item)
        }
      } header: {
        HStack {
          Text("RX Log (\(store.log.count))")
          Spacer()
          Toggle("Pause", isOn: $store.isPaused)
            .toggleStyle(.button)
            .controlSize(.mini)
          Button("Clear") { store.send(.clearLogTapped) }
            .controlSize(.mini)
        }
      }
    }
    .navigationTitle("Diagnostics")
    .task { await store.send(.task).finish() }
  }
}

private struct RxLogRow: View {
  let item: DiagnosticsFeature.LogItem

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(item.entry.header?.payloadType.displayName ?? "?")
          .font(.caption.bold().monospaced())
        if let route = item.entry.header?.route {
          InfoTag(text: route.isFlood ? "flood" : "direct")
        }
        if let path = item.entry.path, !path.hops.isEmpty {
          InfoTag(text: path.displayString, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
        Spacer()
        Text(item.date, style: .time)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack {
        Text("SNR \(Format.snr(item.entry.snr)) · RSSI \(item.entry.rssi) dBm · \(item.entry.raw.count) B")
        Spacer()
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Text(item.entry.raw.prefix(24).hexString)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
  }
}
