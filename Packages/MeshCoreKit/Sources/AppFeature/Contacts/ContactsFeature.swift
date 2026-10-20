import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

@Reducer
struct ContactsFeature {
  @Reducer
  enum Path {
    case contactDetail(ContactDetailFeature)
    case remoteNode(RemoteNodeFeature)
  }

  @Reducer
  enum Destination {
    case discovery(NodeDiscoveryFeature)
  }

  enum Filter: String, CaseIterable, Equatable {
    case all = "All"
    case companions = "People"
    case repeaters = "Repeaters"
    case rooms = "Rooms"
    case sensors = "Sensors"

    func includes(_ type: NodeType) -> Bool {
      switch self {
      case .all: true
      case .companions: type == .chat
      case .repeaters: type == .repeater
      case .rooms: type == .room
      case .sensors: type == .sensor
      }
    }
  }

  enum Sort: String, CaseIterable, Equatable {
    case recent = "Recently heard"
    case name = "Name"
  }

  @ObservableState
  struct State: Equatable {
    var path = StackState<Path.State>()
    @Presents var destination: Destination.State?
    var filter: Filter = .all
    var sort: Sort = .recent
    var searchText = ""
    var isScanning = false
    var isRefreshing = false
    var myShareLink: ContactDetailFeature.ShareSheet?
    var notice: String?
    @Shared(.contacts) var contacts
    @Shared(.pendingAdverts) var pendingAdverts
    @Shared(.radioSession) var session

    var visibleContacts: [Contact] {
      let filtered = contacts.filter { contact in
        filter.includes(contact.type)
          && (searchText.isEmpty || contact.displayName.localizedCaseInsensitiveContains(searchText))
      }
      return filtered.sorted { lhs, rhs in
        if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
        switch sort {
        case .recent: return lhs.lastAdvert > rhs.lastAdvert
        case .name: return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case path(StackActionOf<Path>)
    case destination(PresentationAction<Destination.Action>)
    case contactTapped(PublicKey)
    case scanTapped
    case linkScanned(String)
    case addPendingTapped(PendingAdvert)
    case dismissPendingTapped(PendingAdvert)
    case shareMyContactTapped
    case advertTapped(flood: Bool)
    case discoverTapped
    case refreshTapped
    case removeTapped(Contact)
    case favouriteTapped(Contact)
    case contactsLoaded([Contact])
    case contactAdded(Contact?)
    case finished(notice: String?)
    case delegate(Delegate)

    enum Delegate {
      case openChat(PublicKey)
    }
  }

  @Dependency(\.meshCore) var meshCore

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case let .contactTapped(key):
        state.path.append(.contactDetail(ContactDetailFeature.State(key: key)))
        return .none

      case .scanTapped:
        state.isScanning = true
        return .none

      case let .linkScanned(text):
        state.isScanning = false
        guard let link = MeshCoreLink(string: text) else {
          state.notice = "That isn't a MeshCore contact link."
          return .none
        }
        switch link {
        case let .contact(name, key, type):
          let contact = Contact(publicKey: key, type: type, name: name.isEmpty ? Format.shortKey(key.hex) : name)
          return .run { send in
            do {
              try await meshCore.perform(.addUpdateContact(contact))
              await send(.contactAdded(try await meshCore.contact(key) ?? contact))
            } catch {
              await send(.finished(notice: error.localizedDescription))
            }
          }
        case let .advert(data):
          return .run { send in
            do {
              try await meshCore.perform(.importContact(data))
              await send(.contactsLoaded(try await meshCore.contacts().contacts))
              await send(.finished(notice: "Contact imported."))
            } catch {
              await send(.finished(notice: error.localizedDescription))
            }
          }
        case .channel:
          state.notice = "That's a channel link. Add it from Chats › Add Channel."
          return .none
        }

      case let .addPendingTapped(pending):
        let contact = pending.contact
        return .run { send in
          do {
            try await meshCore.perform(.addUpdateContact(contact))
            await send(.contactAdded(try await meshCore.contact(contact.publicKey) ?? contact))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case let .dismissPendingTapped(pending):
        state.$pendingAdverts.withLock { _ = $0.remove(id: pending.id) }
        return .none

      case let .contactAdded(contact):
        guard let contact else { return .none }
        state.$contacts.withLock { $0[id: contact.publicKey] = contact }
        state.$pendingAdverts.withLock { _ = $0.remove(id: contact.publicKey) }
        state.notice = "Added \(contact.displayName)."
        return .none

      case .shareMyContactTapped:
        guard let me = state.session.selfInfo else { return .none }
        state.myShareLink = ContactDetailFeature.ShareSheet(
          title: me.name,
          subtitle: "Others can scan this to add you as a contact.",
          link: MeshCoreLink.contact(name: me.name, publicKey: me.publicKey, type: me.advertType).url.absoluteString
        )
        return .none

      case let .advertTapped(flood):
        return .run { send in
          do {
            try await meshCore.perform(.sendSelfAdvert(flood: flood))
            await send(.finished(notice: flood ? "Advert flooded across the mesh." : "Advert sent to nodes in range."))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case .discoverTapped:
        state.destination = .discovery(NodeDiscoveryFeature.State())
        return .none

      case .refreshTapped:
        state.isRefreshing = true
        return .run { send in
          do {
            await send(.contactsLoaded(try await meshCore.contacts().contacts))
            await send(.finished(notice: nil))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case let .removeTapped(contact):
        return .run { send in
          do {
            try await meshCore.perform(.removeContact(contact.publicKey))
            await send(.contactsLoaded(try await meshCore.contacts().contacts))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case let .favouriteTapped(contact):
        var updated = contact
        updated.isFavourite.toggle()
        return .run { [updated] send in
          do {
            try await meshCore.perform(.addUpdateContact(updated))
            await send(.contactAdded(try await meshCore.contact(updated.publicKey) ?? updated))
          } catch {
            await send(.finished(notice: error.localizedDescription))
          }
        }

      case let .contactsLoaded(contacts):
        state.$contacts.withLock { $0 = IdentifiedArray(contacts, uniquingIDsWith: { _, latest in latest }) }
        return .none

      case let .finished(notice):
        state.isRefreshing = false
        if let notice { state.notice = notice }
        return .none

      // MARK: Children

      case let .path(.element(id: _, action: .contactDetail(.delegate(.openChat(key))))),
           let .path(.element(id: _, action: .remoteNode(.delegate(.openChat(key))))):
        return .send(.delegate(.openChat(key)))

      case let .path(.element(id: _, action: .contactDetail(.delegate(.openRemoteNode(key))))):
        state.path.append(.remoteNode(RemoteNodeFeature.State(key: key)))
        return .none

      case let .path(.element(id: id, action: .contactDetail(.delegate(.removed)))):
        state.path.pop(from: id)
        return .none

      case .path, .destination, .delegate:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
    .ifLet(\.$destination, action: \.destination)
  }
}

extension ContactsFeature.Path.State: Equatable {}
extension ContactsFeature.Destination.State: Equatable {}

struct ContactsView: View {
  @Bindable var store: StoreOf<ContactsFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      list
        .navigationTitle("Contacts")
        .searchable(text: $store.searchText)
        .refreshable { await store.send(.refreshTapped).finish() }
        .toolbar { toolbar }
    } destination: { store in
      switch store.case {
      case let .contactDetail(store):
        ContactDetailView(store: store)
      case let .remoteNode(store):
        RemoteNodeView(store: store)
      }
    }
    .sheet(isPresented: $store.isScanning) {
      QRScannerView { store.send(.linkScanned($0)) }
    }
    .sheet(item: $store.myShareLink) { sheet in
      ShareLinkSheet(title: sheet.title, subtitle: sheet.subtitle, link: sheet.link)
    }
    .sheet(item: $store.scope(state: \.destination?.discovery, action: \.destination.discovery)) { store in
      NodeDiscoveryView(store: store)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Menu {
        Picker("Show", selection: $store.filter) {
          ForEach(ContactsFeature.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker("Sort", selection: $store.sort) {
          ForEach(ContactsFeature.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
      } label: {
        Image(systemName: store.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
      }
      .accessibilityLabel("Filter")
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button {
          store.send(.scanTapped)
        } label: {
          Label("Add from QR / Link", systemImage: "qrcode.viewfinder")
        }
        Button {
          store.send(.shareMyContactTapped)
        } label: {
          Label("My QR Code", systemImage: "qrcode")
        }
        Divider()
        Button {
          store.send(.advertTapped(flood: false))
        } label: {
          Label("Advertise (nearby)", systemImage: "dot.radiowaves.right")
        }
        Button {
          store.send(.advertTapped(flood: true))
        } label: {
          Label("Advertise (flood)", systemImage: "dot.radiowaves.up.forward")
        }
        Button {
          store.send(.discoverTapped)
        } label: {
          Label("Discover Nearby Nodes", systemImage: "binoculars")
        }
      } label: {
        Image(systemName: "plus.circle.fill")
      }
      .disabled(!store.session.status.isLinkUp)
      .accessibilityLabel("Add")
    }
  }

  @ViewBuilder
  private var list: some View {
    List {
      if let notice = store.notice {
        Section {
          Label(notice, systemImage: "info.circle")
            .font(.callout)
        }
      }

      if !store.pendingAdverts.isEmpty {
        Section {
          ForEach(store.pendingAdverts) { pending in
            HStack(spacing: 12) {
              NodeAvatar(type: pending.contact.type, size: 32)
              VStack(alignment: .leading) {
                Text(pending.contact.displayName)
                Text("\(pending.contact.type.displayName) · \(Format.relative(pending.heardAt))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("Add") { store.send(.addPendingTapped(pending)) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .swipeActions {
              Button("Ignore", role: .destructive) { store.send(.dismissPendingTapped(pending)) }
            }
          }
        } header: {
          Text("Heard Adverts")
        } footer: {
          Text("Manual-add mode is on, so new nodes wait here until you add them.")
        }
      }

      Section {
        let contacts = store.visibleContacts
        if contacts.isEmpty {
          Text(store.contacts.isEmpty ? "No contacts yet. They appear as other nodes advertise." : "No matches.")
            .foregroundStyle(.secondary)
        }
        ForEach(contacts) { contact in
          Button {
            store.send(.contactTapped(contact.publicKey))
          } label: {
            ContactRow(contact: contact)
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              store.send(.removeTapped(contact))
            } label: {
              Label("Remove", systemImage: "trash")
            }
          }
          .swipeActions(edge: .leading) {
            Button {
              store.send(.favouriteTapped(contact))
            } label: {
              Label(contact.isFavourite ? "Unfavourite" : "Favourite", systemImage: contact.isFavourite ? "star.slash" : "star")
            }
            .tint(.yellow)
          }
        }
      } header: {
        if !store.contacts.isEmpty {
          Text("\(store.contacts.count) of \(store.session.deviceInfo?.maxContacts ?? 0) slots")
        }
      }
    }
  }
}

struct ContactRow: View {
  let contact: Contact

  var body: some View {
    HStack(spacing: 12) {
      NodeAvatar(type: contact.type, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(contact.displayName)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
          if contact.isFavourite {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
          }
        }
        HStack(spacing: 6) {
          Text(contact.type.displayName)
          Text("·")
          Text(contact.outPath.isFlood ? "flood" : (contact.outPath.length.hopCount == 0 ? "direct" : "\(contact.outPath.length.hopCount) hops"))
          if contact.hasLocation {
            Image(systemName: "location.fill")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(Format.relative(contact.lastAdvertDate))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
  }
}
