import Foundation

/// Errors thrown while decoding frames received from the radio.
public enum DecodingError: Error, Equatable, Sendable {
  case unexpectedEnd(needed: Int, remaining: Int)
  case emptyFrame
  case invalidValue(String)
}

/// Little-endian cursor over a frame. MeshCore encodes every multi-byte
/// integer little-endian, except Cayenne LPP telemetry which is big-endian.
public struct ByteReader: Sendable {
  private let bytes: [UInt8]
  public private(set) var offset: Int = 0

  public init(_ data: Data) {
    self.bytes = Array(data)
  }

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  public var remaining: Int { bytes.count - offset }
  public var isAtEnd: Bool { remaining <= 0 }

  private func require(_ count: Int) throws {
    guard count <= remaining else {
      throw DecodingError.unexpectedEnd(needed: count, remaining: remaining)
    }
  }

  public mutating func skip(_ count: Int) throws {
    try require(count)
    offset += count
  }

  public mutating func u8() throws -> UInt8 {
    try require(1)
    defer { offset += 1 }
    return bytes[offset]
  }

  public mutating func i8() throws -> Int8 {
    Int8(bitPattern: try u8())
  }

  public mutating func u16() throws -> UInt16 {
    try require(2)
    defer { offset += 2 }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  public mutating func i16() throws -> Int16 {
    Int16(bitPattern: try u16())
  }

  public mutating func u32() throws -> UInt32 {
    try require(4)
    defer { offset += 4 }
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  public mutating func i32() throws -> Int32 {
    Int32(bitPattern: try u32())
  }

  /// Big-endian unsigned integer of `count` bytes (1...4), used by Cayenne LPP.
  public mutating func uBE(_ count: Int) throws -> UInt32 {
    try require(count)
    var value: UInt32 = 0
    for i in 0..<count {
      value = value << 8 | UInt32(bytes[offset + i])
    }
    offset += count
    return value
  }

  /// Big-endian signed integer of `count` bytes (1...4), sign-extended.
  public mutating func iBE(_ count: Int) throws -> Int32 {
    let raw = try uBE(count)
    let shift = UInt32(32 - count * 8)
    return Int32(bitPattern: raw << shift) >> Int32(shift)
  }

  /// Optional trailing fields added in later firmware versions.
  public mutating func optionalU8() -> UInt8? {
    guard remaining >= 1 else { return nil }
    return try? u8()
  }

  public mutating func optionalI8() -> Int8? {
    guard remaining >= 1 else { return nil }
    return try? i8()
  }

  public mutating func optionalU32() -> UInt32? {
    guard remaining >= 4 else { return nil }
    return try? u32()
  }

  public mutating func bytes(_ count: Int) throws -> Data {
    try require(count)
    defer { offset += count }
    return Data(bytes[offset..<(offset + count)])
  }

  public mutating func rest() -> Data {
    guard remaining > 0 else { return Data() }
    defer { offset = bytes.count }
    return Data(bytes[offset...])
  }

  /// A fixed-width, NUL padded string field.
  public mutating func fixedString(_ count: Int) throws -> String {
    let raw = try bytes(count)
    return String.decodingNullTerminated(raw)
  }

  /// The remainder of the frame decoded as UTF-8 (NUL terminated if present).
  public mutating func restString() -> String {
    String.decodingNullTerminated(rest())
  }
}

/// Little-endian frame builder.
public struct ByteWriter: Sendable {
  public private(set) var data = Data()

  public init() {}

  public init(code: UInt8) {
    data.append(code)
  }

  public mutating func u8(_ value: UInt8) { data.append(value) }
  public mutating func i8(_ value: Int8) { data.append(UInt8(bitPattern: value)) }

  public mutating func u16(_ value: UInt16) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8(value >> 8))
  }

  public mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }

  public mutating func u32(_ value: UInt32) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8(value >> 24))
  }

  public mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

  public mutating func bytes(_ value: Data) { data.append(value) }
  public mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }

  /// Writes `value` into a fixed-width field, truncating (on a UTF-8 boundary)
  /// and NUL padding as needed. One byte is always reserved for the terminator.
  public mutating func fixedString(_ value: String, width: Int) {
    let utf8 = Array(value.utf8Truncated(toByteCount: width - 1).utf8)
    data.append(contentsOf: utf8)
    data.append(contentsOf: [UInt8](repeating: 0, count: width - utf8.count))
  }

  /// Writes `value` (zero padded / truncated) into a fixed-width binary field.
  public mutating func fixedBytes(_ value: Data, width: Int) {
    let slice = Array(value.prefix(width))
    data.append(contentsOf: slice)
    if slice.count < width {
      data.append(contentsOf: [UInt8](repeating: 0, count: width - slice.count))
    }
  }

  public mutating func string(_ value: String) {
    data.append(contentsOf: Array(value.utf8))
  }
}

extension String {
  /// Decodes UTF-8 up to the first NUL byte, repairing invalid sequences.
  static func decodingNullTerminated(_ data: Data) -> String {
    let trimmed = data.prefix { $0 != 0 }
    return String(decoding: trimmed, as: UTF8.self)
  }

  /// Returns the longest prefix of the string whose UTF-8 encoding fits in
  /// `count` bytes without splitting a character.
  public func utf8Truncated(toByteCount count: Int) -> String {
    guard utf8.count > count else { return self }
    var result = ""
    var used = 0
    for character in self {
      let size = String(character).utf8.count
      if used + size > count { break }
      result.append(character)
      used += size
    }
    return result
  }
}

extension Data {
  /// Lowercase hexadecimal representation.
  public var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }

  /// Parses a hexadecimal string (whitespace and `:` separators are ignored).
  public init?(hexString: String) {
    let cleaned = hexString.filter { !$0.isWhitespace && $0 != ":" }
    guard cleaned.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
