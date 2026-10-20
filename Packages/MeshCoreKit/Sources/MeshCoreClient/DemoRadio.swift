import Foundation
import MeshCoreProtocol

/// A single open connection to a radio.
protocol RadioLink: Sendable {
  func write(_ frame: Data) async throws
  func close() async
}

/// An in-app simulation of MeshCore companion firmware. It speaks the real
/// wire protocol, so the whole stack (codec, pipeline, features) is exercised
/// in the Simulator and in SwiftUI previews.
actor DemoRadio: RadioLink {
  private let emit: @Sendable (Data) -> Void
  private var isOpen = true

  private var selfInfo: SelfInfo
  private var contacts: [Contact]
  private var channels: [ChannelInfo]
  private var queue: [Data] = []
  private var clock = UInt32(Date().timeIntervalSince1970)
  private var backgroundTask: Task<Void, Never>?
  private var nextAck: UInt32 = 0x1000

  static let selfKey = PublicKey(Data((0..<32).map { UInt8(truncatingIfNeeded: 0x5A &+ $0 &* 7) }))!

  init(emit: @escaping @Sendable (Data) -> Void) {
    self.emit = emit
    let now = UInt32(Date().timeIntervalSince1970)
    selfInfo = SelfInfo(
      advertType: .chat,
      txPower: 22,
      maxTxPower: 22,
      publicKey: Self.selfKey,
      latitude: -37.8136,
      longitude: 144.9631,
      multiAcks: 0,
      advertLocationPolicy: .share,
      telemetryModes: TelemetryModes(base: .allowAll, location: .allowFlagged, environment: .allowFlagged),
      manualAddContacts: 0,
      radio: RadioPreset.builtIn[0].radio,
      name: "Demo Heltec V4"
    )
    func key(_ seed: UInt8) -> PublicKey {
      PublicKey(Data((0..<32).map { UInt8(truncatingIfNeeded: Int(seed) * 31 + $0 * 13) }))!
    }
    contacts = [
      Contact(publicKey: key(1), type: .chat, flags: 0x01, outPath: MeshPath(hopString: "a3,7f")!, name: "Alice", lastAdvert: now - 300, latitude: -37.8102, longitude: 144.9628, lastModified: now - 300),
      Contact(publicKey: key(2), type: .chat, name: "Bob 📻", lastAdvert: now - 3_600, latitude: -37.8226, longitude: 144.9689, lastModified: now - 3_600),
      Contact(publicKey: key(3), type: .repeater, outPath: MeshPath(hopString: "")!, name: "Mt Dandenong RPT", lastAdvert: now - 900, latitude: -37.8327, longitude: 145.3511, lastModified: now - 900),
      Contact(publicKey: key(4), type: .room, outPath: MeshPath(hopString: "a3")!, name: "Melbourne Room", lastAdvert: now - 7_200, latitude: -37.8180, longitude: 144.9525, lastModified: now - 7_200),
      Contact(publicKey: key(5), type: .sensor, name: "Garden Sensor", lastAdvert: now - 86_400, latitude: -37.7990, longitude: 144.9800, lastModified: now - 86_400),
    ]
    channels = (0..<8).map { ChannelInfo(index: UInt8($0), name: "", secret: Data(count: 16)) }
    channels[0] = ChannelInfo(index: 0, name: "Public", secret: ChannelInfo.publicSecret)
    channels[1] = ChannelInfo(index: 1, name: "#melbourne", secret: ChannelKeys.hashtagSecret(for: "#melbourne"))
  }

  func start() {
    // Simulate on-air traffic for the RX log and an incoming message.
    backgroundTask = Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(4))
        tick += 1
        await self?.backgroundTick(tick)
      }
    }
    queueChannelMessage(index: 0, from: "Alice", text: "Morning all! Anyone on the Dandenong repeater?", delay: 0)
  }

  func write(_ frame: Data) async throws {
    guard isOpen else { throw MeshCoreError.notConnected }
    try await Task.sleep(for: .milliseconds(25))
    handle(frame)
  }

  func close() async {
    isOpen = false
    backgroundTask?.cancel()
  }

  // MARK: - Command handling

  private func handle(_ frame: Data) {
    guard let first = frame.first, let code = Command.Code(rawValue: first) else {
      reply(Data([1, DeviceErrorCode.unsupportedCommand.rawValue]))
      return
    }
    var r = ByteReader(frame)
    _ = try? r.skip(1)

    switch code {
    case .deviceQuery:
      var w = ByteWriter(code: 13)
      w.u8(14); w.u8(175); w.u8(UInt8(channels.count)); w.u32(123_456)
      w.fixedString("15 Oct 2026", width: 12)
      w.fixedString("Heltec V4 (demo)", width: 40)
      w.fixedString("v1.18.0", width: 20)
      w.u8(0); w.u8(0)
      reply(w.data)

    case .appStart:
      reply(selfInfoFrame())

    case .getDeviceTime:
      var w = ByteWriter(code: 9)
      w.u32(clock)
      reply(w.data)

    case .setDeviceTime:
      clock = (try? r.u32()) ?? clock
      ok()

    case .getContacts:
      var start = ByteWriter(code: 2)
      start.u32(UInt32(contacts.count))
      reply(start.data)
      for contact in contacts {
        reply(Data([3]) + contact.encodedRecord())
      }
      var end = ByteWriter(code: 4)
      end.u32(contacts.map(\.lastModified).max() ?? 0)
      reply(end.data)

    case .getContactByKey:
      if let key = try? r.bytes(32), let contact = contacts.first(where: { $0.publicKey.bytes == key }) {
        reply(Data([3]) + contact.encodedRecord())
      } else {
        error(.notFound)
      }

    case .addUpdateContact:
      if let contact = try? Contact(reading: &r) {
        var updated = contact
        updated.lastModified = clock
        if let index = contacts.firstIndex(where: { $0.publicKey == contact.publicKey }) {
          contacts[index] = updated
        } else {
          contacts.append(updated)
        }
        ok()
      } else {
        error(.illegalArgument)
      }

    case .removeContact:
      let key = (try? r.bytes(32)) ?? Data()
      let before = contacts.count
      contacts.removeAll { $0.publicKey.bytes == key }
      before == contacts.count ? error(.notFound) : ok()

    case .resetPath:
      let key = (try? r.bytes(32)) ?? Data()
      if let index = contacts.firstIndex(where: { $0.publicKey.bytes == key }) {
        contacts[index].outPath = .flood
        ok()
      } else {
        error(.notFound)
      }

    case .getChannel:
      let index = Int((try? r.u8()) ?? 255)
      if channels.indices.contains(index) {
        var w = ByteWriter(code: 18)
        w.u8(UInt8(index))
        w.fixedString(channels[index].name, width: 32)
        w.bytes(channels[index].secret)
        reply(w.data)
      } else {
        error(.notFound)
      }

    case .setChannel:
      if let index = try? r.u8(), let name = try? r.fixedString(32), let secret = try? r.bytes(16),
         channels.indices.contains(Int(index)) {
        channels[Int(index)] = ChannelInfo(index: index, name: name, secret: secret)
        ok()
      } else {
        error(.notFound)
      }

    case .syncNextMessage:
      if queue.isEmpty {
        reply(Data([10]))
      } else {
        reply(queue.removeFirst())
      }

    case .sendTextMessage:
      let type = (try? r.u8()) ?? 0
      _ = try? r.u8()
      let timestamp = (try? r.u32()) ?? clock
      let prefix = (try? r.bytes(6)) ?? Data()
      let text = r.restString()
      guard let contact = contacts.first(where: { KeyPrefix(prefix).matches($0.publicKey) }) else {
        error(.notFound)
        return
      }
      let ack = nextAckCode()
      var w = ByteWriter(code: 6)
      w.u8(contact.outPath.isFlood ? 1 : 0)
      w.u32(type == TextType.plain.rawValue ? ack : 0)
      w.u32(4_000)
      reply(w.data)
      if type == TextType.plain.rawValue {
        later(.milliseconds(1_400)) { radio in
          var confirm = ByteWriter(code: 0x82)
          confirm.u32(ack)
          confirm.u32(1_380)
          await radio.push(confirm.data)
        }
        later(.seconds(3)) { radio in
          await radio.queueContactMessage(from: contact, text: Self.reply(to: text, timestamp: timestamp))
        }
      } else {
        later(.seconds(1)) { radio in
          await radio.queueContactMessage(from: contact, type: .cliData, text: Self.cliReply(to: text))
        }
      }

    case .sendChannelTextMessage:
      _ = try? r.u8()
      let index = (try? r.u8()) ?? 0
      _ = try? r.u32()
      let text = r.restString()
      ok()
      later(.seconds(4)) { radio in
        await radio.queueChannelMessage(index: index, from: "Bob 📻", text: "Copy that: “\(text.prefix(40))”", delay: 0)
      }

    case .getBatteryAndStorage:
      var w = ByteWriter(code: 12)
      w.u16(4_020); w.u32(212); w.u32(1_408)
      reply(w.data)

    case .getStats:
      let type = StatsType(rawValue: (try? r.u8()) ?? 0) ?? .core
      var w = ByteWriter(code: 24)
      w.u8(type.rawValue)
      switch type {
      case .core:
        w.u16(4_020); w.u32(clock % 86_400); w.u16(0); w.u8(0)
      case .radio:
        w.i16(-117); w.i8(-92); w.i8(26); w.u32(48); w.u32(311)
      case .packets:
        for value: UInt32 in [1_204, 233, 120, 113, 980, 224, 3] { w.u32(value) }
      }
      reply(w.data)

    case .sendLogin:
      let key = (try? r.bytes(32)) ?? Data()
      let password = r.restString()
      sent(tag: UInt32(littleEndianPrefix: key))
      later(.milliseconds(1_200)) { radio in
        var w = ByteWriter(code: password == "wrong" ? 0x86 : 0x85)
        w.u8(password == "wrong" ? 0 : 1)
        w.bytes(key.prefix(6))
        if password != "wrong" {
          w.u32(UInt32(Date().timeIntervalSince1970)); w.u8(3); w.u8(2)
        }
        await radio.push(w.data)
      }

    case .sendStatusRequest:
      let key = (try? r.bytes(32)) ?? Data()
      sent(tag: nextAckCode())
      later(.milliseconds(1_500)) { radio in
        var w = ByteWriter(code: 0x87)
        w.u8(0); w.bytes(key.prefix(6))
        w.u16(4_110); w.u16(0); w.i16(-116); w.i16(-88)
        for value: UInt32 in [5_210, 1_830, 412, 604_800, 900, 930, 3_900, 1_310] { w.u32(value) }
        w.u16(1); w.i16(34); w.u16(12); w.u16(220); w.u32(2_900); w.u32(17)
        await radio.push(w.data)
      }

    case .sendTelemetryRequest:
      try? r.skip(3)
      let key = (try? r.bytes(32)) ?? Self.selfKey.bytes
      let telemetry = Data([1, 116, 0x01, 0x9C, 1, 103, 0x00, 0xD2, 2, 104, 0x78, 2, 115, 0x27, 0x9B])
      var w = ByteWriter(code: 0x8B)
      w.u8(0); w.bytes(key.prefix(6)); w.bytes(telemetry)
      if frame.count == 4 {
        reply(w.data) // self telemetry is answered with the push frame
      } else {
        sent(tag: nextAckCode())
        let pushFrame = w.data
        later(.seconds(1)) { radio in await radio.push(pushFrame) }
      }

    case .sendBinaryRequest:
      _ = try? r.bytes(32)
      let requestType = (try? r.u8()) ?? 0
      let tag = nextAckCode()
      sent(tag: tag)
      later(.seconds(1)) { radio in
        var w = ByteWriter(code: 0x8C)
        w.u8(0); w.u32(tag)
        if requestType == BinaryRequestType.neighbours.rawValue {
          let neighbours = await radio.neighbourSample()
          w.i16(Int16(neighbours.count)); w.i16(Int16(neighbours.count))
          for (key, secs, snr) in neighbours {
            w.bytes(key.prefix(6)); w.i32(secs); w.i8(snr)
          }
        } else if requestType == BinaryRequestType.accessList.rawValue {
          w.bytes(Self.selfKey.bytes.prefix(6)); w.u8(3)
          w.bytes(Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45])); w.u8(1)
        }
        await radio.push(w.data)
      }

    case .sendPathDiscoveryRequest:
      try? r.skip(1)
      let key = (try? r.bytes(32)) ?? Data()
      sent(tag: nextAckCode())
      later(.seconds(2)) { radio in
        var w = ByteWriter(code: 0x8D)
        w.u8(0); w.bytes(key.prefix(6))
        w.u8(2); w.bytes([0xA3, 0x7F])
        w.u8(3); w.bytes([0x7F, 0x12, 0xA3])
        await radio.push(w.data)
      }

    case .sendTracePath:
      let tag = (try? r.u32()) ?? 0
      let auth = (try? r.u32()) ?? 0
      let flags = (try? r.u8()) ?? 0
      let path = r.rest()
      var w = ByteWriter(code: 6)
      w.u8(0); w.u32(tag); w.u32(3_000)
      reply(w.data)
      later(.milliseconds(1_800)) { radio in
        var t = ByteWriter(code: 0x89)
        t.u8(0); t.u8(UInt8(path.count)); t.u8(flags); t.u32(tag); t.u32(auth)
        t.bytes(path)
        let hops = path.count >> Int(flags & 0x03)
        for i in 0..<hops { t.i8(Int8(clamping: 40 - i * 14)) }
        t.i8(22)
        await radio.push(t.data)
      }

    case .exportContact:
      var w = ByteWriter(code: 11)
      w.u8(0x11) // flood advert header
      w.u8(0)
      w.bytes(Self.selfKey.bytes)
      w.u32(clock)
      w.bytes(Data(repeating: 0xEE, count: 64)) // signature
      w.u8(0x81)
      w.string(selfInfo.name)
      reply(w.data)

    case .exportPrivateKey, .importPrivateKey:
      reply(Data([15])) // disabled, as in release firmware builds

    case .getTuningParameters:
      var w = ByteWriter(code: 23)
      w.u32(0); w.u32(1_000)
      reply(w.data)

    case .getAutoAddConfig:
      reply(Data([25, 0x1E, 0]))

    case .getAllowedRepeatFrequencies:
      var w = ByteWriter(code: 26)
      for (lower, upper): (UInt32, UInt32) in [(433_000, 433_000), (869_495, 869_495), (918_000, 918_000)] {
        w.u32(lower); w.u32(upper)
      }
      reply(w.data)

    case .getDefaultFloodScope:
      reply(Data([28]))

    case .getCustomVariables:
      var w = ByteWriter(code: 21)
      w.string("gps:0,gps_interval:900")
      reply(w.data)

    case .getAdvertPath:
      try? r.skip(1)
      let key = (try? r.bytes(32)) ?? Data()
      if let contact = contacts.first(where: { $0.publicKey.bytes == key }) {
        var w = ByteWriter(code: 22)
        w.u32(contact.lastAdvert)
        w.u8(contact.outPath.isFlood ? 0 : contact.outPath.length.rawValue)
        w.bytes(contact.outPath.bytes)
        reply(w.data)
      } else {
        error(.notFound)
      }

    case .signStart:
      var w = ByteWriter(code: 19)
      w.u8(0); w.u32(8 * 1024)
      reply(w.data)

    case .signFinish:
      reply(Data([20]) + ChannelKeys.sha256(Data("demo".utf8)) + ChannelKeys.sha256(Data("sig".utf8)))

    case .runCLICommand:
      var w = ByteWriter(code: 29)
      w.string(Self.cliReply(to: r.restString()))
      reply(w.data)

    case .setAdvertName:
      selfInfo.name = r.restString()
      ok()

    case .setAdvertLocation:
      selfInfo.latitude = Double((try? r.i32()) ?? 0) / 1_000_000
      selfInfo.longitude = Double((try? r.i32()) ?? 0) / 1_000_000
      ok()

    case .setRadioParameters:
      if let freq = try? r.u32(), let bw = try? r.u32(), let sf = try? r.u8(), let cr = try? r.u8() {
        selfInfo.radio = RadioParameters(frequencyKHz: freq, bandwidthHz: bw, spreadingFactor: sf, codingRate: cr)
      }
      ok()

    case .setTxPower:
      selfInfo.txPower = (try? r.i8()) ?? selfInfo.txPower
      ok()

    case .setOtherParameters:
      selfInfo.manualAddContacts = (try? r.u8()) ?? 0
      if let modes = try? r.u8() { selfInfo.telemetryModes = TelemetryModes(byte: modes) }
      if let policy = try? r.u8() { selfInfo.advertLocationPolicy = AdvertLocationPolicy(byte: policy) }
      if let acks = try? r.u8() { selfInfo.multiAcks = acks }
      ok()

    case .sendSelfAdvert:
      ok()
      later(.seconds(2)) { radio in await radio.announceStranger() }

    case .sendControlData:
      ok()
      later(.seconds(1)) { radio in await radio.discoveryResponses() }

    case .reboot, .factoryReset:
      break

    default:
      ok()
    }
  }

  // MARK: - Simulated traffic

  private func backgroundTick(_ tick: Int) {
    guard isOpen else { return }
    // A raw packet for the RX log.
    let types: [UInt8] = [0x11, 0x15, 0x0A, 0x0D, 0x26]
    var w = ByteWriter(code: 0x88)
    w.i8(Int8(clamping: 20 + (tick % 7) * 3 - 12)); w.i8(Int8(clamping: -70 - (tick % 5) * 6))
    w.u8(types[tick % types.count]); w.u8(UInt8(tick % 3)); w.bytes(Array([UInt8]([0xA3, 0x7F]).prefix(tick % 3)))
    w.bytes(Data((0..<24).map { _ in UInt8.random(in: 0...255) }))
    push(w.data)

    if tick % 12 == 0, let alice = contacts.first {
      var advert = ByteWriter(code: 0x80)
      advert.bytes(alice.publicKey.bytes)
      push(advert.data)
    }
    if tick % 20 == 0 {
      queueChannelMessage(index: 1, from: "Carol", text: "Weather's clearing up over the bay ☀️", delay: 0)
    }
  }

  private func queueContactMessage(from contact: Contact, type: TextType = .plain, text: String) {
    var w = ByteWriter(code: 16)
    w.i8(28); w.u8(0); w.u8(0)
    w.bytes(contact.publicKey.bytes.prefix(6))
    w.u8(contact.outPath.isFlood ? 3 : 0xFF)
    w.u8(type.rawValue)
    w.u32(UInt32(Date().timeIntervalSince1970))
    w.string(text)
    enqueue(w.data)
  }

  private func queueChannelMessage(index: UInt8, from sender: String, text: String, delay: Int) {
    var w = ByteWriter(code: 17)
    w.i8(18); w.u8(0); w.u8(0)
    w.u8(index); w.u8(2); w.u8(0)
    w.u32(UInt32(Date().timeIntervalSince1970))
    w.string("\(sender): \(text)")
    enqueue(w.data)
  }

  private func enqueue(_ frame: Data) {
    queue.append(frame)
    push(Data([0x83]))
  }

  private func announceStranger() {
    let stranger = Contact(
      publicKey: PublicKey(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))!,
      type: .repeater,
      name: "Hilltop RPT \(Int.random(in: 10...99))",
      lastAdvert: UInt32(Date().timeIntervalSince1970),
      latitude: -37.75 + Double.random(in: -0.05...0.05),
      longitude: 145.0 + Double.random(in: -0.05...0.05),
      lastModified: clock
    )
    contacts.append(stranger)
    push(Data([0x8A]) + stranger.encodedRecord())
  }

  private func discoveryResponses() {
    for contact in contacts where contact.type == .repeater {
      var w = ByteWriter(code: 0x8E)
      w.i8(24); w.i8(-81); w.u8(0)
      w.u8(ControlType.nodeDiscoverResponse | contact.type.rawValue)
      w.i8(30); w.u32(0)
      w.bytes(contact.publicKey.bytes)
      push(w.data)
    }
  }

  private func neighbourSample() -> [(Data, Int32, Int8)] {
    contacts.filter { $0.type != .chat }.enumerated().map { index, contact in
      (contact.publicKey.bytes, Int32(60 * (index + 1)), Int8(clamping: 36 - index * 18))
    }
  }

  // MARK: - Helpers

  private func selfInfoFrame() -> Data {
    var w = ByteWriter(code: 5)
    w.u8(selfInfo.advertType.rawValue)
    w.i8(selfInfo.txPower)
    w.i8(selfInfo.maxTxPower)
    w.bytes(selfInfo.publicKey.bytes)
    w.i32(Int32(selfInfo.latitude * 1_000_000))
    w.i32(Int32(selfInfo.longitude * 1_000_000))
    w.u8(selfInfo.multiAcks)
    w.u8(selfInfo.advertLocationPolicy.rawValue)
    w.u8(selfInfo.telemetryModes.byte)
    w.u8(selfInfo.manualAddContacts)
    w.u32(selfInfo.radio.frequencyKHz)
    w.u32(selfInfo.radio.bandwidthHz)
    w.u8(selfInfo.radio.spreadingFactor)
    w.u8(selfInfo.radio.codingRate)
    w.string(selfInfo.name)
    return w.data
  }

  private func nextAckCode() -> UInt32 {
    nextAck &+= 0x101
    return nextAck
  }

  private func sent(tag: UInt32) {
    var w = ByteWriter(code: 6)
    w.u8(0); w.u32(tag); w.u32(5_000)
    reply(w.data)
  }

  private func ok() { reply(Data([0])) }
  private func error(_ code: DeviceErrorCode) { reply(Data([1, code.rawValue])) }

  private func reply(_ frame: Data) {
    guard isOpen else { return }
    emit(frame)
  }

  private func push(_ frame: Data) {
    guard isOpen else { return }
    emit(frame)
  }

  private func later(_ delay: Duration, _ work: @escaping @Sendable (DemoRadio) async -> Void) {
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }
      await work(self)
    }
  }

  private static func reply(to text: String, timestamp: UInt32) -> String {
    let lower = text.lowercased()
    if lower.contains("hello") || lower.contains("hi") { return "Hey! Loud and clear 👋" }
    if lower.contains("?") { return "Good question — I'll check and get back to you." }
    return "Got it (\(text.count) chars)."
  }

  private static func cliReply(to command: String) -> String {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "ver": return "v1.18.0 (Build: 15 Oct 2026)"
    case "clock": return "06:42 - 21/10/2026 UTC"
    case "get name": return "> Demo Heltec V4"
    case "board": return "Heltec V4"
    case "neighbors": return "a3:120:9\n7f:300:-2"
    default: return trimmed.isEmpty ? "" : "OK - \(trimmed)"
    }
  }
}

private extension UInt32 {
  init(littleEndianPrefix data: Data) {
    var value: UInt32 = 0
    for (index, byte) in data.prefix(4).enumerated() {
      value |= UInt32(byte) << (8 * UInt32(index))
    }
    self = value
  }
}
