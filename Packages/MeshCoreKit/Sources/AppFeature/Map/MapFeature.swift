import ComposableArchitecture
import MapKit
import MeshCoreProtocol
import SwiftUI

/// Contacts that advertise a position, plotted on a map.
@Reducer
struct MapFeature {
  @ObservableState
  struct State: Equatable {
    var selectedKey: PublicKey?
    var showRepeaters = true
    var showCompanions = true
    var showOthers = true
    @Shared(.contacts) var contacts
    @Shared(.radioSession) var session

    var located: [Contact] {
      contacts.filter { contact in
        guard contact.hasLocation else { return false }
        switch contact.type {
        case .repeater: return showRepeaters
        case .chat: return showCompanions
        default: return showOthers
        }
      }
    }

    var selected: Contact? { selectedKey.flatMap { contacts[id: $0] } }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case messageTapped(PublicKey)
    case detailsTapped(PublicKey)
    case delegate(Delegate)

    enum Delegate {
      case openChat(PublicKey)
      case openContact(PublicKey)
    }
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case let .messageTapped(key):
        state.selectedKey = nil
        return .send(.delegate(.openChat(key)))
      case let .detailsTapped(key):
        state.selectedKey = nil
        return .send(.delegate(.openContact(key)))
      case .delegate:
        return .none
      }
    }
  }
}

struct MeshMapView: View {
  @Bindable var store: StoreOf<MapFeature>
  @State private var position: MapCameraPosition = .automatic

  var body: some View {
    NavigationStack {
      Map(position: $position, selection: $store.selectedKey) {
        if let me = store.session.selfInfo, me.latitude != 0 || me.longitude != 0 {
          Annotation(me.name, coordinate: CLLocationCoordinate2D(latitude: me.latitude, longitude: me.longitude)) {
            Image(systemName: "dot.radiowaves.left.and.right")
              .font(.caption.bold())
              .foregroundStyle(.white)
              .padding(7)
              .background(Color.accentColor, in: Circle())
              .overlay(Circle().stroke(.white, lineWidth: 2))
          }
        }
        ForEach(store.located) { contact in
          Annotation(contact.displayName, coordinate: CLLocationCoordinate2D(latitude: contact.latitude, longitude: contact.longitude)) {
            NodeAvatar(type: contact.type, size: 30)
              .overlay(Circle().stroke(.white, lineWidth: 2))
          }
          .tag(contact.publicKey)
        }
        UserAnnotation()
      }
      .mapControls {
        MapUserLocationButton()
        MapCompass()
        MapScaleView()
      }
      .navigationTitle("Map")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Toggle("Repeaters", isOn: $store.showRepeaters)
            Toggle("Companions", isOn: $store.showCompanions)
            Toggle("Rooms & Sensors", isOn: $store.showOthers)
          } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if let contact = store.selected {
          card(for: contact)
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .overlay {
        if store.located.isEmpty {
          ContentUnavailableView(
            "No locations yet",
            systemImage: "map",
            description: Text("Nodes appear here when their adverts include a position.")
          )
          .allowsHitTesting(false)
        }
      }
      .animation(.default, value: store.selectedKey)
    }
  }

  private func card(for contact: Contact) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        NodeAvatar(type: contact.type, size: 40)
        VStack(alignment: .leading) {
          Text(contact.displayName).font(.headline)
          Text("\(contact.type.displayName) · heard \(Format.relative(contact.lastAdvertDate))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let me = store.session.selfInfo, me.latitude != 0 || me.longitude != 0 {
          let distance = CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: contact.latitude, longitude: contact.longitude))
          Text(Measurement(value: distance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
            .font(.callout.monospacedDigit())
        }
      }
      HStack {
        if contact.type == .chat || contact.type == .room {
          Button {
            store.send(.messageTapped(contact.publicKey))
          } label: {
            Label("Message", systemImage: "bubble.left.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
        Button {
          store.send(.detailsTapped(contact.publicKey))
        } label: {
          Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding()
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
  }
}
