import Foundation
import Testing
@testable import MeshCoreClient
import MeshCoreProtocol

/// Records writes and lets the test feed replies.
private actor FakeLink {
  var written: [Data] = []
  func record(_ data: Data) { written.append(data) }
}

private final class PushRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [PushEvent] = []
  func append(_ event: PushEvent) { lock.withLock { events.append(event) } }
  var all: [PushEvent] { lock.withLock { events } }
}

@Suite("Command pipeline")
struct CommandPipelineTests {
  @Test func singleReply() async throws {
    let link = FakeLink()
    let pipeline = CommandPipeline(write: { await link.record($0) }, onPush: { _ in })

    async let reply = pipeline.send(.getBatteryAndStorage)
    try await Task.sleep(for: .milliseconds(20))
    var w = ByteWriter(code: 12)
    w.u16(3_900)
    await pipeline.receive(w.data)

    #expect(try await reply == [.batteryAndStorage(BatteryAndStorage(batteryMillivolts: 3_900))])
    #expect(await link.written == [Data([20])])
  }

  @Test func contactsCollectUntilEnd() async throws {
    let pipeline = CommandPipeline(write: { _ in }, onPush: { _ in })
    let key = PublicKey(Data(repeating: 9, count: 32))!
    let contact = Contact(publicKey: key, type: .chat, name: "A")

    async let reply = pipeline.send(.getContacts(since: nil))
    try await Task.sleep(for: .milliseconds(20))
    await pipeline.receive(Data([2, 1, 0, 0, 0]))
    await pipeline.receive(Data([3]) + contact.encodedRecord())
    await pipeline.receive(Data([4, 5, 0, 0, 0]))

    let frames = try await reply
    #expect(frames.count == 3)
    #expect(frames[1] == .contact(contact))
    #expect(frames[2] == .endOfContacts(mostRecentLastModified: 5))
  }

  @Test func pushesAreRoutedSeparately() async throws {
    let pushes = PushRecorder()
    let pipeline = CommandPipeline(write: { _ in }, onPush: { pushes.append($0) })

    async let reply = pipeline.send(.sendSelfAdvert(flood: false))
    try await Task.sleep(for: .milliseconds(20))
    await pipeline.receive(Data([0x83])) // message waiting, mid-command
    await pipeline.receive(Data([0]))

    #expect(try await reply == [.ok])
    #expect(pushes.all == [.messageWaiting])
  }

  @Test func selfTelemetryAcceptsPushAsReply() async throws {
    let pushes = PushRecorder()
    let pipeline = CommandPipeline(write: { _ in }, onPush: { pushes.append($0) })

    async let reply = pipeline.send(.sendTelemetryRequest(nil))
    try await Task.sleep(for: .milliseconds(20))
    await pipeline.receive(Data([0x8B, 0, 1, 2, 3, 4, 5, 6, 1, 116, 0x01, 0x9C]))

    let frames = try await reply
    #expect(frames.count == 1)
    #expect(pushes.all.isEmpty)
  }

  @Test func commandsRunOneAtATime() async throws {
    let link = FakeLink()
    let pipeline = CommandPipeline(write: { await link.record($0) }, onPush: { _ in })

    async let first = pipeline.send(.getDeviceTime)
    try await Task.sleep(for: .milliseconds(20))
    async let second = pipeline.send(.getBatteryAndStorage)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await link.written.count == 1)

    await pipeline.receive(Data([9, 1, 0, 0, 0]))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await link.written.count == 2)
    await pipeline.receive(Data([12, 0x10, 0x0F]))

    #expect(try await first == [.currentTime(1)])
    #expect(try await second == [.batteryAndStorage(BatteryAndStorage(batteryMillivolts: 0x0F10))])
  }

  @Test func implausibleFramesAreIgnored() async throws {
    let pipeline = CommandPipeline(write: { _ in }, onPush: { _ in })

    async let reply = pipeline.send(.getDeviceTime)
    try await Task.sleep(for: .milliseconds(20))
    await pipeline.receive(Data([4, 0, 0, 0, 0])) // straggling END_OF_CONTACTS
    await pipeline.receive(Data([9, 2, 0, 0, 0]))

    #expect(try await reply == [.currentTime(2)])
  }

  @Test func closeFailsPendingCommand() async throws {
    let pipeline = CommandPipeline(write: { _ in }, onPush: { _ in })

    let reply = Task { try await pipeline.send(.getDeviceTime) }
    try await Task.sleep(for: .milliseconds(20))
    await pipeline.close()

    await #expect(throws: MeshCoreError.disconnected) {
      try await reply.value
    }
  }
}
