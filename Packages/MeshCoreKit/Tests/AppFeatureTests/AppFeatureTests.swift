import ComposableArchitecture
import Foundation
import MeshCoreClient
import MeshCoreProtocol
import Testing
@testable import AppFeature

private let alice = Contact(
  publicKey: PublicKey(Data((0..<32).map { UInt8($0) }))!,
  type: .chat,
  outPath: MeshPath(hopString: "a3,7f")!,
  name: "Alice",
  lastAdvert: 1_700_000_000
)

private let repeater = Contact(
  publicKey: PublicKey(Data((0..<32).map { UInt8(0xB0 &+ $0) }))!,
  type: .repeater,
  outPath: MeshPath(hopString: "a3")!,
  name: "Hill RPT"
)

private let publicChannel = ChannelInfo(index: 0, name: "Public", secret: ChannelInfo.publicSecret)

@MainActor
@Suite("AppFeature")
struct AppFeatureTests {
  @Test func incomingDirectMessageIsStoredOnce() async {
    @Shared(.contacts) var contacts
    $contacts.withLock { $0 = [alice] }

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_300)
    }

    let received = ReceivedContactMessage(
      senderPrefix: alice.publicKey.prefix(),
      pathLength: PathLength(hashSize: 1, hopCount: 2),
      textType: .plain,
      senderTimestamp: 1_700_000_100,
      text: "hello",
      snr: 6.5
    )

    await store.send(.messageSynced(.contact(received))) {
      $0.$messages.withLock {
        $0 = [ChatMessage(
          id: UUID(0),
          conversation: .forContact(alice.publicKey),
          direction: .incoming,
          senderName: "Alice",
          text: "hello",
          timestamp: Date(timeIntervalSince1970: 1_700_000_100),
          status: .received,
          hops: 2,
          snr: 6.5
        )]
      }
    }

    // The mesh can deliver the same message twice; it is stored once.
    await store.send(.messageSynced(.contact(received)))
  }

  @Test func channelMessageSplitsSenderName() async {
    @Shared(.channels) var channels
    $channels.withLock { $0 = [publicChannel] }

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_300)
    }

    let received = ReceivedChannelMessage(
      channelIndex: 0,
      pathLength: .flood,
      senderTimestamp: 1_700_000_200,
      text: "Bob: anyone on?",
      snr: 2
    )

    await store.send(.messageSynced(.channel(received))) {
      $0.$messages.withLock {
        $0 = [ChatMessage(
          id: UUID(0),
          conversation: publicChannel.conversationID,
          direction: .incoming,
          senderName: "Bob",
          text: "anyone on?",
          timestamp: Date(timeIntervalSince1970: 1_700_000_200),
          status: .received,
          hops: nil,
          snr: 2
        )]
      }
    }
  }

  @Test func lateAckMarksMessageDelivered() async {
    let id = UUID(7)
    @Shared(.messages) var messages
    $messages.withLock {
      $0 = [ChatMessage(
        id: id,
        conversation: .forContact(alice.publicKey),
        direction: .outgoing,
        text: "ping",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        status: .failed("No delivery confirmation"),
        expectedAck: 0xABCD
      )]
    }

    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.push(.sendConfirmed(ackCode: 0xABCD, roundTripMilliseconds: 2_100))) {
      $0.$messages.withLock { $0[id: id]?.status = .delivered(roundTripMilliseconds: 2_100) }
    }
  }

  @Test func newAdvertInManualModeIsPending() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0.meshCore.send = { _ in [.error(.notFound)] }
    }

    await store.send(.push(.newAdvert(repeater)))
    await store.receive(\.advertHeard) {
      $0.$pendingAdverts.withLock {
        $0 = [PendingAdvert(contact: repeater, heardAt: Date(timeIntervalSince1970: 1_700_000_000))]
      }
    }
  }

  @Test func disconnectSchedulesReconnect() async {
    @Shared(.lastRadio) var lastRadio
    $lastRadio.withLock { $0 = RadioIdentifier.demo.storageValue }
    let clock = TestClock()

    var initial = AppFeature.State()
    initial.$session.withLock { $0.status = .connected(.demo) }

    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.meshCore.connect = { _ in try await Task.never() }
    }

    await store.send(.connectionEvent(.disconnected(.demo, reason: "Connection lost"))) {
      $0.$session.withLock { $0.status = .disconnected }
      $0.reconnectAttempt = 1
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.reconnectTimerFired)
    await store.receive(\.connectRequested) {
      $0.$session.withLock { $0.status = .connecting(.demo) }
    }
    await store.skipInFlightEffects()
  }
}

@MainActor
@Suite("Chats")
struct ChatsTests {
  @Test func directMessageIsDeliveredWhenAckArrives() async {
    let id = UUID(1)
    @Shared(.contacts) var contacts
    $contacts.withLock { $0 = [alice] }
    @Shared(.messages) var messages
    $messages.withLock {
      $0 = [ChatMessage(
        id: id,
        conversation: .forContact(alice.publicKey),
        direction: .outgoing,
        text: "hi",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        status: .sending
      )]
    }
    let sent = SentInfo(isFlood: false, expectedAck: 42, timeoutMilliseconds: 3_000)
    let commands = LockIsolated<[Command]>([])

    let store = TestStore(initialState: ChatsFeature.State()) {
      ChatsFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.meshCore.pushes = {
        AsyncStream {
          $0.yield(.sendConfirmed(ackCode: 42, roundTripMilliseconds: 900))
          $0.finish()
        }
      }
      $0.meshCore.send = { command in
        commands.withValue { $0.append(command) }
        return [.sent(sent)]
      }
    }

    await store.send(.outbox(.deliver(id)))
    await store.receive(\.outbox.attempt) {
      $0.$messages.withLock { $0[id: id]?.attempts = 1 }
    }
    await store.receive(\.outbox.sent) {
      $0.$messages.withLock {
        $0[id: id]?.status = .sent(flood: false)
        $0[id: id]?.expectedAck = 42
      }
    }
    await store.receive(\.outbox.delivered) {
      $0.$messages.withLock { $0[id: id]?.status = .delivered(roundTripMilliseconds: 900) }
    }

    #expect(commands.value == [
      .sendTextMessage(type: .plain, attempt: 0, timestamp: 1_700_000_000, recipient: alice.publicKey.prefix(), text: "hi"),
    ])
  }

  @Test func channelMessageIsSentWithoutAck() async {
    @Shared(.channels) var channels
    $channels.withLock { $0 = [publicChannel] }
    @Shared(.radioSession) var session
    $session.withLock { $0.status = .connected(.demo) }

    var state = ChatFeature.State(conversation: publicChannel.conversationID)
    state.draft = "  hello mesh  "

    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_500)
      $0.meshCore.send = { _ in [.ok] }
    }
    store.exhaustivity = .off

    await store.send(.sendTapped) {
      $0.draft = ""
    }
    await store.finish()
    #expect(store.state.messages.first?.text == "hello mesh")
    #expect(store.state.messages.first?.status == .sent(flood: true))
  }
}

@Suite("Trace route")
struct TraceRouteTests {
  @Test func repeaterRoundTrip() {
    let route = ContactDetailFeature.tracePath(for: repeater)
    #expect(route?.flags == 0)
    #expect(route?.path == Data([0xA3, 0xB0, 0xA3]))
  }

  @Test func companionTracesToLastRepeater() {
    let route = ContactDetailFeature.tracePath(for: alice)
    #expect(route?.path == Data([0xA3, 0x7F, 0xA3]))
  }

  @Test func floodContactCannotBeTraced() {
    var contact = alice
    contact.outPath = .flood
    #expect(ContactDetailFeature.tracePath(for: contact) == nil)
  }
}
