import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// The node's advertised name and position.
@Reducer
struct IdentitySettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.radioSession) var session
    var name = ""
    var latitude = ""
    var longitude = ""
    var sharesLocation = false
    var isSaving = false
    var isLocating = false
    var notice: String?

    init() {
      if let me = session.selfInfo {
        name = me.name
        latitude = me.latitude == 0 && me.longitude == 0 ? "" : String(format: "%.6f", me.latitude)
        longitude = me.latitude == 0 && me.longitude == 0 ? "" : String(format: "%.6f", me.longitude)
        sharesLocation = me.advertLocationPolicy != .none
      }
    }

    var coordinate: (Double, Double)? {
      if latitude.isEmpty && longitude.isEmpty { return (0, 0) }
      guard let lat = Double(latitude), let lon = Double(longitude),
            (-90...90).contains(lat), (-180...180).contains(lon)
      else { return nil }
      return (lat, lon)
    }

    var nameIsValid: Bool {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      return !trimmed.isEmpty && trimmed.utf8.count <= 31
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case useCurrentLocationTapped
    case locationFound(Coordinate)
    case clearLocationTapped
    case saveTapped
    case saved(SelfInfo)
    case failed(String)
    case advertTapped(flood: Bool)
    case advertSent(flood: Bool)
  }

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.location) var location

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .useCurrentLocationTapped:
        state.isLocating = true
        return .run { send in
          do {
            await send(.locationFound(try await location.currentLocation()))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .locationFound(coordinate):
        state.isLocating = false
        state.latitude = String(format: "%.6f", coordinate.latitude)
        state.longitude = String(format: "%.6f", coordinate.longitude)
        return .none

      case .clearLocationTapped:
        state.latitude = ""
        state.longitude = ""
        return .none

      case .saveTapped:
        guard let me = state.session.selfInfo else { return .none }
        guard state.nameIsValid else {
          state.notice = "Names must be 1–31 bytes."
          return .none
        }
        guard let coordinate = state.coordinate else {
          state.notice = "Enter latitude and longitude in decimal degrees."
          return .none
        }
        let lat = coordinate.0
        let lon = coordinate.1
        state.isSaving = true
        state.notice = nil
        let name = state.name.trimmingCharacters(in: .whitespaces)
        let policy: AdvertLocationPolicy = state.sharesLocation ? .share : .none
        return .run { send in
          do {
            if name != me.name {
              try await meshCore.perform(.setAdvertName(name))
            }
            try await meshCore.perform(.setAdvertLocation(latitude: lat, longitude: lon))
            if policy != me.advertLocationPolicy {
              try await meshCore.perform(.setOtherParameters(
                manualAddContacts: me.manualAddContacts,
                telemetryModes: me.telemetryModes,
                advertLocationPolicy: policy,
                multiAcks: me.multiAcks
              ))
            }
            await send(.saved(try await meshCore.appStart(appName: appName)))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .saved(info):
        state.isSaving = false
        state.$session.withLock { $0.selfInfo = info }
        state.notice = "Saved. Send an advert so others see the change."
        return .none

      case let .failed(message):
        state.isSaving = false
        state.isLocating = false
        state.notice = message
        return .none

      case let .advertTapped(flood):
        return .run { send in
          do {
            try await meshCore.perform(.sendSelfAdvert(flood: flood))
            await send(.advertSent(flood: flood))
          } catch {
            await send(.failed(error.localizedDescription))
          }
        }

      case let .advertSent(flood):
        state.notice = flood ? "Advert flooded across the mesh." : "Advert sent to nodes in range."
        return .none
      }
    }
  }
}

struct IdentitySettingsView: View {
  @Bindable var store: StoreOf<IdentitySettingsFeature>

  var body: some View {
    Form {
      Section {
        TextField("Node name", text: $store.name)
          .autocorrectionDisabled()
      } header: {
        Text("Name")
      } footer: {
        Text("\(store.name.utf8.count)/31 bytes. Shown to everyone who hears your adverts and in channel messages.")
      }

      Section {
        TextField("Latitude", text: $store.latitude)
          .keyboardType(.numbersAndPunctuation)
        TextField("Longitude", text: $store.longitude)
          .keyboardType(.numbersAndPunctuation)
        Button {
          store.send(.useCurrentLocationTapped)
        } label: {
          HStack {
            Label("Use iPhone Location", systemImage: "location")
            Spacer()
            if store.isLocating { ProgressView() }
          }
        }
        Button("Clear Location", role: .destructive) { store.send(.clearLocationTapped) }
        Toggle("Include location in adverts", isOn: $store.sharesLocation)
      } header: {
        Text("Location")
      } footer: {
        Text("Your position is only broadcast when included in adverts. It's also used for distances on the map.")
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

      Section("Advertise") {
        Button("Send Advert (nearby)") { store.send(.advertTapped(flood: false)) }
        Button("Send Advert (flood)") { store.send(.advertTapped(flood: true)) }
      }
    }
    .navigationTitle("Name & Location")
  }
}
