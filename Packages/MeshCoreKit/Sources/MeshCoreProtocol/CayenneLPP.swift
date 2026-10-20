import Foundation

/// A single decoded Cayenne LPP telemetry value.
public struct TelemetryReading: Hashable, Sendable, Codable, Identifiable {
  public enum Value: Hashable, Sendable, Codable {
    case number(Double)
    case vector(x: Double, y: Double, z: Double)
    case location(latitude: Double, longitude: Double, altitude: Double)
    case colour(red: UInt8, green: UInt8, blue: UInt8)
  }

  public var channel: UInt8
  public var typeCode: UInt8
  public var value: Value
  /// Position within the frame, to keep identity stable for lists.
  public var index: Int

  public var id: Int { index }

  public init(channel: UInt8, typeCode: UInt8, value: Value, index: Int) {
    self.channel = channel
    self.typeCode = typeCode
    self.value = value
    self.index = index
  }

  public var name: String { CayenneLPP.name(for: typeCode) }
  public var unit: String { CayenneLPP.unit(for: typeCode) }

  public var formattedValue: String {
    switch value {
    case let .number(number):
      let text = number.rounded() == number ? String(format: "%.0f", number) : String(format: "%.2f", number)
      return unit.isEmpty ? text : "\(text) \(unit)"
    case let .vector(x, y, z):
      return String(format: "x %.2f, y %.2f, z %.2f %@", x, y, z, unit)
    case let .location(lat, lon, alt):
      return String(format: "%.5f, %.5f (%.1f m)", lat, lon, alt)
    case let .colour(r, g, b):
      return String(format: "#%02X%02X%02X", r, g, b)
    }
  }
}

/// Decoder for the (big-endian) Cayenne Low Power Payload format MeshCore
/// uses for sensor telemetry.
public enum CayenneLPP {
  private struct Spec {
    let name: String
    let unit: String
    let size: Int
    let divisor: Double
    let signed: Bool
  }

  private static let specs: [UInt8: Spec] = [
    0: Spec(name: "Digital input", unit: "", size: 1, divisor: 1, signed: false),
    1: Spec(name: "Digital output", unit: "", size: 1, divisor: 1, signed: false),
    2: Spec(name: "Analog input", unit: "", size: 2, divisor: 100, signed: true),
    3: Spec(name: "Analog output", unit: "", size: 2, divisor: 100, signed: true),
    100: Spec(name: "Generic", unit: "", size: 4, divisor: 1, signed: false),
    101: Spec(name: "Illuminance", unit: "lx", size: 2, divisor: 1, signed: false),
    102: Spec(name: "Presence", unit: "", size: 1, divisor: 1, signed: false),
    103: Spec(name: "Temperature", unit: "°C", size: 2, divisor: 10, signed: true),
    104: Spec(name: "Humidity", unit: "%", size: 1, divisor: 2, signed: false),
    113: Spec(name: "Accelerometer", unit: "G", size: 6, divisor: 1000, signed: true),
    115: Spec(name: "Pressure", unit: "hPa", size: 2, divisor: 10, signed: false),
    116: Spec(name: "Voltage", unit: "V", size: 2, divisor: 100, signed: false),
    117: Spec(name: "Current", unit: "A", size: 2, divisor: 1000, signed: false),
    118: Spec(name: "Frequency", unit: "Hz", size: 4, divisor: 1, signed: false),
    120: Spec(name: "Percentage", unit: "%", size: 1, divisor: 1, signed: false),
    121: Spec(name: "Altitude", unit: "m", size: 2, divisor: 1, signed: true),
    122: Spec(name: "Load", unit: "kg", size: 3, divisor: 1000, signed: true),
    125: Spec(name: "Concentration", unit: "ppm", size: 2, divisor: 1, signed: false),
    128: Spec(name: "Power", unit: "W", size: 2, divisor: 1, signed: false),
    130: Spec(name: "Distance", unit: "m", size: 4, divisor: 1000, signed: false),
    131: Spec(name: "Energy", unit: "kWh", size: 4, divisor: 1000, signed: false),
    132: Spec(name: "Direction", unit: "°", size: 2, divisor: 1, signed: false),
    133: Spec(name: "Time", unit: "", size: 4, divisor: 1, signed: false),
    134: Spec(name: "Gyrometer", unit: "°/s", size: 6, divisor: 100, signed: true),
    135: Spec(name: "Colour", unit: "", size: 3, divisor: 1, signed: false),
    136: Spec(name: "GPS", unit: "", size: 9, divisor: 1, signed: true),
    142: Spec(name: "Switch", unit: "", size: 1, divisor: 1, signed: false),
  ]

  public static func name(for type: UInt8) -> String { specs[type]?.name ?? "Type \(type)" }
  public static func unit(for type: UInt8) -> String { specs[type]?.unit ?? "" }

  /// Decodes as many readings as possible; stops at the first unknown type
  /// (whose size can't be known) or at a zero channel terminator.
  public static func decode(_ data: Data) -> [TelemetryReading] {
    var reader = ByteReader(data)
    var readings: [TelemetryReading] = []
    while reader.remaining >= 2 {
      guard let channel = try? reader.u8(), let type = try? reader.u8() else { break }
      // MeshCore numbers channels from 1; a zero channel byte is padding.
      if channel == 0 { break }
      guard let spec = specs[type], reader.remaining >= spec.size else { break }
      let index = readings.count
      do {
        let value: TelemetryReading.Value
        switch type {
        case 113, 134:
          let x = Double(try reader.iBE(2)) / spec.divisor
          let y = Double(try reader.iBE(2)) / spec.divisor
          let z = Double(try reader.iBE(2)) / spec.divisor
          value = .vector(x: x, y: y, z: z)
        case 135:
          value = .colour(red: try reader.u8(), green: try reader.u8(), blue: try reader.u8())
        case 136:
          let lat = Double(try reader.iBE(3)) / 10_000
          let lon = Double(try reader.iBE(3)) / 10_000
          let alt = Double(try reader.iBE(3)) / 100
          value = .location(latitude: lat, longitude: lon, altitude: alt)
        default:
          let raw: Double
          if spec.signed {
            raw = Double(try reader.iBE(spec.size))
          } else {
            raw = Double(try reader.uBE(spec.size))
          }
          value = .number(raw / spec.divisor)
        }
        readings.append(TelemetryReading(channel: channel, typeCode: type, value: value, index: index))
      } catch {
        break
      }
    }
    return readings
  }
}
