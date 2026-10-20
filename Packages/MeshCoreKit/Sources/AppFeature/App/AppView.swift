import ComposableArchitecture
import MeshCoreClient
import SwiftUI

/// The app's entry view. The store lives for the lifetime of the process.
@MainActor
public struct RootView: View {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  public init() {}

  public var body: some View {
    AppView(store: Self.store)
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TabView(selection: $store.selectedTab) {
      ChatsView(store: store.scope(state: \.chats, action: \.chats))
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
        .badge(store.chats.totalUnread)
        .tag(AppFeature.Tab.chats)

      ContactsView(store: store.scope(state: \.contactsTab, action: \.contactsTab))
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .tabItem { Label("Contacts", systemImage: "person.2") }
        .badge(store.contactsTab.pendingAdverts.count)
        .tag(AppFeature.Tab.contacts)

      MeshMapView(store: store.scope(state: \.map, action: \.map))
        .tabItem { Label("Map", systemImage: "map") }
        .tag(AppFeature.Tab.map)

      SettingsView(store: store.scope(state: \.settings, action: \.settings))
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(AppFeature.Tab.settings)
    }
    .sheet(item: $store.scope(state: \.connection, action: \.connection)) { store in
      ConnectionView(store: store)
        .interactiveDismissDisabled(self.store.lastRadio == nil)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .task { await store.send(.task).finish() }
    .onOpenURL { url in
      store.send(.openURL(url))
    }
    .onChange(of: scenePhase) { _, phase in
      store.send(.scenePhaseChanged(isActive: phase == .active))
    }
  }

  @ViewBuilder
  private var banner: some View {
    if let text = bannerText {
      Button {
        store.send(.showConnectionTapped)
      } label: {
        HStack(spacing: 8) {
          if store.session.status != .disconnected {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
          }
          Text(text)
          Spacer()
          Text("Radios")
            .fontWeight(.semibold)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
      }
      .buttonStyle(.plain)
    }
  }

  private var bannerText: String? {
    switch store.session.status {
    case .connected:
      return nil
    case .connecting:
      return "Connecting to radio…"
    case .syncing:
      return "Syncing with radio…"
    case .disconnected:
      if store.lastRadio == nil || store.suppressReconnect { return "No radio connected" }
      return "Radio out of reach — reconnecting"
    }
  }
}
