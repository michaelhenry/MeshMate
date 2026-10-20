import ComposableArchitecture
import MeshCoreClient
import MeshCoreProtocol
import SwiftUI

/// Runs CLI commands on the connected radio itself (firmware protocol v14+).
@Reducer
struct ConsoleFeature {
  struct Entry: Equatable, Identifiable {
    var id: UUID
    var command: String
    var reply: String?
    var isError = false
  }

  @ObservableState
  struct State: Equatable {
    var entries: [Entry] = []
    var draft = ""
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case runTapped
    case suggestionTapped(String)
    case replied(UUID, String)
    case failed(UUID, String)
  }

  static let suggestions = ["ver", "board", "clock", "get name", "get radio", "get tx", "stats-core"]

  @Dependency(\.meshCore) var meshCore
  @Dependency(\.uuid) var uuid

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case let .suggestionTapped(command):
        state.draft = command
        return .send(.runTapped)

      case .runTapped:
        let command = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }
        state.draft = ""
        let id = uuid()
        state.entries.append(Entry(id: id, command: command))
        return .run { send in
          do {
            await send(.replied(id, try await meshCore.runCLI(command)))
          } catch {
            await send(.failed(id, error.localizedDescription))
          }
        }

      case let .replied(id, reply):
        if let index = state.entries.firstIndex(where: { $0.id == id }) {
          state.entries[index].reply = reply.isEmpty ? "(no output)" : reply
        }
        return .none

      case let .failed(id, message):
        if let index = state.entries.firstIndex(where: { $0.id == id }) {
          state.entries[index].reply = message
          state.entries[index].isError = true
        }
        return .none
      }
    }
  }
}

struct ConsoleView: View {
  @Bindable var store: StoreOf<ConsoleFeature>

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if store.entries.isEmpty {
            Text("Type a command such as `ver` or `get radio`. Changes made here apply to the radio immediately.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          ForEach(store.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text("> \(entry.command)")
                .foregroundStyle(Color.accentColor)
              if let reply = entry.reply {
                Text(reply)
                  .foregroundStyle(entry.isError ? .red : .primary)
                  .textSelection(.enabled)
              } else {
                ProgressView().controlSize(.small)
              }
            }
            .id(entry.id)
          }
        }
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .onChange(of: store.entries.last?.reply) { _, _ in
        if let id = store.entries.last?.id {
          withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 8) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(ConsoleFeature.suggestions, id: \.self) { suggestion in
              Button(suggestion) { store.send(.suggestionTapped(suggestion)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption.monospaced())
            }
          }
          .padding(.horizontal)
        }
        HStack {
          TextField("command", text: $store.draft)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { store.send(.runTapped) }
            .textFieldStyle(.roundedBorder)
          Button {
            store.send(.runTapped)
          } label: {
            Image(systemName: "return")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.draft.isEmpty)
        }
        .padding(.horizontal)
      }
      .padding(.vertical, 8)
      .background(.bar)
    }
    .navigationTitle("Radio Console")
    .navigationBarTitleDisplayMode(.inline)
  }
}
