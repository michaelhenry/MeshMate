import Foundation
import Testing
@testable import MeshCoreProtocol

private let keyA = PublicKey(Data((0..<32).map { UInt8($0) }))!
private let keyB = PublicKey(Data((0..<32).map { UInt8(0xA0 &+ $0) }))!

@Suite("Command encoding")
struct CommandEncodingTests {
  @Test func appStart() {
    let data = Command.appStart(appName: "MeshMate").encoded()
    #expect(data.prefix(2) == Data([0x01, 0x03]))
    #expect(data.count == 8 + "MeshMate".utf8.count)
    #expect(String(decoding: data.suffix(8), as: UTF8.self) == "MeshMate")
  }

  @Test func deviceQuery() {
    #expect(Command.deviceQuery(appTargetVersion: 3).encoded() == Data([22, 3]))
  }

  @Test func sendTextMessage() {
    let data = Command.sendTextMessage(
      type: .plain, attempt: 1, timestamp: 0x0102_0304,
      recipient: keyA.prefix(), text: "hi"
    ).encoded()
    #expect(Array(data) == [2, 0, 1, 0x04, 0x03, 0x02, 0x01, 0, 1, 2, 3, 4, 5, 0x68, 0x69])
  }

  @Test func textIsTruncatedOnCharacterBoundary() {
    let long = String(repeating: "é", count: 100) // 200 bytes
    let data = Command.sendChannelTextMessage(channelIndex: 0, timestamp: 0, text: long).encoded()
    #expect(data.count == 7 + 160)
  }

  @Test func setRadioParameters() throws {
    let radio = RadioParameters(frequencyMHz: 915.8, bandwidthKHz: 250, spreadingFactor: 10, codingRate: 5)
    let data = Command.setRadioParameters(radio, clientRepeat: false).encoded()
    var r = ByteReader(data)
    #expect(try r.u8() == 11)
    #expect(try r.u32() == 915_800)
    #expect(try r.u32() == 250_000)
    #expect(try r.u8() == 10)
    #expect(try r.u8() == 5)
    #expect(try r.u8() == 0)
    #expect(r.isAtEnd)
  }

  @Test func setChannel() {
    let channel = ChannelInfo(index: 2, name: "#test", secret: ChannelKeys.hashtagSecret(for: "#test"))
    let data = Command.setChannel(channel).encoded()
    #expect(data.count == 2 + 32 + 16)
    #expect(data[1] == 2)
    #expect(data.suffix(16) == channel.secret)
  }

  @Test func addUpdateContactLayout() {
    let contact = Contact(publicKey: keyA, type: .repeater, flags: 1, name: "Hill", lastAdvert: 10, latitude: -37.8, longitude: 144.9)
    let data = Command.addUpdateContact(contact).encoded()
    #expect(data.count == 1 + 32 + 3 + 64 + 32 + 4 + 8)
    #expect(data[33] == NodeType.repeater.rawValue)
    #expect(data[35] == 0xFF) // flood path
  }

  @Test func telemetryRequests() {
    #expect(Command.sendTelemetryRequest(nil).encoded() == Data([39, 0, 0, 0]))
    #expect(Command.sendTelemetryRequest(keyA).encoded().count == 4 + 32)
  }

  @Test func rebootAndReset() {
    #expect(Command.reboot.encoded() == Data([19]) + Data("reboot".utf8))
    #expect(Command.factoryReset.encoded() == Data([51]) + Data("reset".utf8))
  }

  @Test func floodScope() {
    #expect(Command.setFloodScopeKey(nil).encoded() == Data([54, 0]))
    #expect(Command.setUnscopedFlood.encoded() == Data([54, 1]))
    #expect(Command.setFloodScopeKey(Data(repeating: 7, count: 16)).encoded().count == 18)
  }

  @Test func neighboursRequest() {
    let data = BinaryRequest.neighbours(count: 10, offset: 2, order: .strongestFirst, prefixLength: 6)
    #expect(data.count == 11)
    #expect(Array(data.prefix(7)) == [6, 0, 10, 2, 0, 2, 6])
  }

  @Test func everyCommandFitsAFrame() {
    let contact = Contact(publicKey: keyA, type: .chat, name: String(repeating: "x", count: 40))
    let commands: [Command] = [
      .addUpdateContact(contact),
      .sendTextMessage(type: .plain, attempt: 0, timestamp: 0, recipient: keyA.prefix(), text: String(repeating: "a", count: 500)),
      .setChannel(ChannelInfo(index: 0, name: String(repeating: "n", count: 64), secret: Data(count: 16))),
      .setDefaultFloodScope(FloodScope(name: "melbourne", key: Data(count: 16))),
    ]
    for command in commands {
      #expect(command.encoded().count <= Command.maxFrameSize)
    }
  }
}

@Suite("Frame decoding")
struct FrameDecodingTests {
  @Test func contactRoundTrip() throws {
    let path = MeshPath(hopString: "a1,b2,c3")!
    let contact = Contact(
      publicKey: keyB, type: .room, flags: 0b0000_0011, outPath: path, name: "Room 1",
      lastAdvert: 1_700_000_000, latitude: -37.81, longitude: 144.96, lastModified: 42
    )
    let frame = Data([3]) + contact.encodedRecord()
    #expect(frame.count == 148)
    let decoded = try ResponseFrame(decoding: frame)
    #expect(decoded == .contact(contact))
    #expect(contact.isFavourite)
    #expect(contact.telemetryPermissions == .base)
  }

  @Test func newAdvertPush() throws {
    let contact = Contact(publicKey: keyA, type: .chat, name: "Kel")
    let decoded = try ResponseFrame(decoding: Data([0x8A]) + contact.encodedRecord())
    #expect(decoded == .push(.newAdvert(contact)))
  }

  @Test func selfInfo() throws {
    var w = ByteWriter(code: 5)
    w.u8(1); w.i8(22); w.i8(22)
    w.bytes(keyA.bytes)
    w.i32(-37_813_600); w.i32(144_963_100)
    w.u8(1); w.u8(1); w.u8(0b10_01_10); w.u8(1)
    w.u32(915_800); w.u32(250_000); w.u8(10); w.u8(5)
    w.string("Kel's Heltec")
    guard case let .selfInfo(info) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected self info"); return
    }
    #expect(info.publicKey == keyA)
    #expect(info.txPower == 22)
    #expect(abs(info.latitude + 37.8136) < 0.000_001)
    #expect(info.telemetryModes == TelemetryModes(base: .allowAll, location: .allowFlagged, environment: .allowAll))
    #expect(info.isManualContactAdd)
    #expect(info.radio.frequencyMHz == 915.8)
    #expect(info.radio.bandwidthKHz == 250)
    #expect(info.name == "Kel's Heltec")
  }

  @Test func deviceInfo() throws {
    var w = ByteWriter(code: 13)
    w.u8(14); w.u8(175); w.u8(40); w.u32(123_456)
    w.fixedBytes(Data("15 Oct 2026".utf8), width: 12)
    w.fixedBytes(Data("Heltec V4".utf8), width: 40)
    w.fixedBytes(Data("v1.18.0".utf8), width: 20)
    w.u8(0); w.u8(1)
    guard case let .deviceInfo(info) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected device info"); return
    }
    #expect(info.maxContacts == 350)
    #expect(info.maxChannels == 40)
    #expect(info.manufacturer == "Heltec V4")
    #expect(info.firmwareVersion == "v1.18.0")
    #expect(info.pathHashMode == 1)
  }

  @Test func legacyDeviceInfo() throws {
    guard case let .deviceInfo(info) = try ResponseFrame(decoding: Data([13, 2])) else {
      Issue.record("expected device info"); return
    }
    #expect(info.firmwareVersionCode == 2)
  }

  @Test func sent() throws {
    var w = ByteWriter(code: 6)
    w.u8(1); w.u32(0xDEAD_BEEF); w.u32(7_000)
    #expect(try ResponseFrame(decoding: w.data) == .sent(SentInfo(isFlood: true, expectedAck: 0xDEAD_BEEF, timeoutMilliseconds: 7_000)))
  }

  @Test func contactMessageV3() throws {
    var w = ByteWriter(code: 16)
    w.i8(-26); w.u8(0); w.u8(0)
    w.bytes(keyA.bytes.prefix(6))
    w.u8(2); w.u8(0); w.u32(1_700_000_000)
    w.string("hello 👋")
    guard case let .contactMessage(message) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected message"); return
    }
    #expect(message.snr == -6.5)
    #expect(message.senderPrefix.matches(keyA))
    #expect(message.pathLength.hopCount == 2)
    #expect(message.text == "hello 👋")
  }

  @Test func signedRoomMessage() throws {
    var w = ByteWriter(code: 16)
    w.i8(8); w.u8(0); w.u8(0)
    w.bytes(keyB.bytes.prefix(6))
    w.u8(0xFF); w.u8(TextType.signedPlain.rawValue); w.u32(5)
    w.bytes(keyA.bytes.prefix(4))
    w.string("post")
    guard case let .contactMessage(message) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected message"); return
    }
    #expect(message.pathLength.isFlood)
    #expect(message.authorPrefix?.matches(keyA) == true)
    #expect(message.text == "post")
  }

  @Test func channelMessage() throws {
    var w = ByteWriter(code: 17)
    w.i8(12); w.u8(0); w.u8(0)
    w.u8(0); w.u8(1); w.u8(0); w.u32(99)
    w.string("Alice: see you at 5: ok?")
    guard case let .channelMessage(message) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected channel message"); return
    }
    #expect(message.senderName == "Alice")
    #expect(message.body == "see you at 5: ok?")
    #expect(message.snr == 3)
  }

  @Test func errorFrame() throws {
    #expect(try ResponseFrame(decoding: Data([1, 2])) == .error(.notFound))
    #expect(try ResponseFrame(decoding: Data([1])) == .error(nil))
  }

  @Test func sendConfirmed() throws {
    var w = ByteWriter(code: 0x82)
    w.u32(77); w.u32(1_234)
    #expect(try ResponseFrame(decoding: w.data) == .push(.sendConfirmed(ackCode: 77, roundTripMilliseconds: 1_234)))
  }

  @Test func traceData() throws {
    var w = ByteWriter(code: 0x89)
    w.u8(0); w.u8(2); w.u8(0); w.u32(9); w.u32(0)
    w.bytes([0xAA, 0xBB])
    w.i8(20); w.i8(-8)
    w.i8(4)
    guard case let .push(.traceData(trace)) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected trace"); return
    }
    #expect(trace.hopHashes == [Data([0xAA]), Data([0xBB])])
    #expect(trace.hopSNRs == [5, -2])
    #expect(trace.finalSNR == 1)
  }

  @Test func pathDiscovery() throws {
    var w = ByteWriter(code: 0x8D)
    w.u8(0); w.bytes(keyA.bytes.prefix(6))
    w.u8(PathLength(hashSize: 2, hopCount: 1).rawValue); w.bytes([1, 2])
    w.u8(0)
    guard case let .push(.pathDiscoveryResponse(result)) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected path discovery"); return
    }
    #expect(result.outPath.hops == [Data([1, 2])])
    #expect(result.inPath.hops.isEmpty)
    #expect(result.inPath.isFlood == false)
  }

  @Test func repeaterStatus() throws {
    var w = ByteWriter(code: 0x87)
    w.u8(0); w.bytes(keyA.bytes.prefix(6))
    w.u16(4_100); w.u16(0); w.i16(-118); w.i16(-90)
    for value in [UInt32(10), 20, 30, 3_600, 1, 2, 3, 4] { w.u32(value) }
    w.u16(0); w.i16(-20); w.u16(5); w.u16(6); w.u32(7); w.u32(8)
    guard case let .push(.statusResponse(prefix, status)) = try ResponseFrame(decoding: w.data) else {
      Issue.record("expected status"); return
    }
    #expect(prefix.matches(keyA))
    #expect(status.batteryMillivolts == 4_100)
    #expect(status.noiseFloor == -118)
    #expect(status.uptimeSeconds == 3_600)
    #expect(status.lastSNR == -5)
    #expect(status.receiveErrors == 8)
  }

  @Test func stats() throws {
    var w = ByteWriter(code: 24)
    w.u8(1); w.i16(-110); w.i8(-80); w.i8(30); w.u32(5); w.u32(6)
    #expect(try ResponseFrame(decoding: w.data) == .stats(.radio(RadioStats(noiseFloor: -110, lastRSSI: -80, lastSNR: 7.5, txAirtimeSeconds: 5, rxAirtimeSeconds: 6))))
  }

  @Test func neighbours() throws {
    var w = ByteWriter()
    w.i16(3); w.i16(2)
    w.bytes([1, 2, 3, 4]); w.i32(60); w.i8(-12)
    w.bytes([5, 6, 7, 8]); w.i32(120); w.i8(40)
    let response = try NeighboursResponse(decoding: w.data, prefixLength: 4)
    #expect(response.totalCount == 3)
    #expect(response.neighbours.map(\.snr) == [-3, 10])
  }

  @Test func rxLogHeader() {
    let entry = RxLogEntry(snr: 1, rssi: -90, raw: Data([0x11, 0x02, 0xAB, 0xCD, 0x00]))
    #expect(entry.header?.payloadType == .advert)
    #expect(entry.header?.route == .flood)
    #expect(entry.path?.hops == [Data([0xAB]), Data([0xCD])])
  }
}

@Suite("Helpers")
struct HelperTests {
  @Test func pathLength() {
    let length = PathLength(rawValue: 0b01_000011)
    #expect(length.hashSize == 2)
    #expect(length.hopCount == 3)
    #expect(length.byteCount == 6)
    #expect(PathLength.flood.isFlood)
    #expect(PathLength(rawValue: 0b11_000001).isValid == false)
  }

  @Test func pathParsing() {
    #expect(MeshPath(hopString: "a1, b2 → c3")?.hops.count == 3)
    #expect(MeshPath(hopString: "a1b2,c3d4")?.length.hashSize == 2)
    #expect(MeshPath(hopString: "a1,b2c3") == nil)
    #expect(MeshPath(hopString: "zz") == nil)
  }

  @Test func hashtagKeyMatchesDocumentation() {
    #expect(ChannelKeys.hashtagSecret(for: "#test").hexString == "9cd8fcf22a47333b591d96a2b848b73f")
    #expect(ChannelKeys.hashtagSecret(for: "test") == ChannelKeys.hashtagSecret(for: "#test"))
  }

  @Test func shareLinks() {
    let contact = MeshCoreLink(string: "meshcore://contact/add?name=Example+Contact&public_key=\(keyA.hex)&type=2")
    #expect(contact == .contact(name: "Example Contact", publicKey: keyA, type: .repeater))

    let channel = MeshCoreLink(string: "meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72")
    #expect(channel == .channel(name: "Public", secret: ChannelInfo.publicSecret))

    let link = MeshCoreLink.channel(name: "#melb", secret: Data(repeating: 1, count: 16))
    #expect(MeshCoreLink(string: link.url.absoluteString) == link)

    #expect(MeshCoreLink(string: "https://example.com") == nil)
  }

  @Test func telemetry() {
    // ch1 voltage 4.12 V, ch1 temperature -3.5 °C, ch2 GPS
    var bytes: [UInt8] = [1, 116, 0x01, 0x9C, 1, 103, 0xFF, 0xDD]
    bytes += [2, 136, 0xFA, 0x3A, 0xF0, 0x16, 0x1E, 0xD0, 0x00, 0x27, 0x10]
    let readings = CayenneLPP.decode(Data(bytes))
    #expect(readings.count == 3)
    #expect(readings[0].value == .number(4.12))
    #expect(readings[1].value == .number(-3.5))
    if case let .location(lat, lon, alt) = readings[2].value {
      #expect(abs(lat - -37.8128) < 0.0001)
      #expect(abs(lon - 144.9680) < 0.0001)
      #expect(alt == 100)
    } else {
      Issue.record("expected location")
    }
  }

  @Test func customVariables() {
    #expect(CustomVariable.parseList("gps:1,gps_interval:60") == [
      CustomVariable(name: "gps", value: "1"),
      CustomVariable(name: "gps_interval", value: "60"),
    ])
  }

  @Test func presetsParse() {
    let json = #"{"config":{"suggested_radio_settings":{"entries":[{"title":"Australia","frequency":"915.800","spreading_factor":"10","bandwidth":"250","coding_rate":"5"},{"title":"NZ","frequency":"917.375","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":2}}]}}}"#
    let presets = RadioPreset.parseAPIResponse(Data(json.utf8))
    #expect(presets?.count == 2)
    #expect(presets?.first?.radio == RadioPreset.builtIn.first?.radio)
    #expect(presets?.last?.pathHashSize == 2)
  }
}
