import Foundation

/// Community radio presets. Mirrors https://api.meshcore.nz/api/v1/config
/// (fetched October 2026); the app also refreshes this list at runtime.
public struct RadioPreset: Hashable, Sendable, Codable, Identifiable {
  public var title: String
  public var radio: RadioParameters
  /// Bytes per path hash recommended for this network (1-3), if specified.
  public var pathHashSize: Int?

  public var id: String { title }

  public init(title: String, radio: RadioParameters, pathHashSize: Int? = nil) {
    self.title = title
    self.radio = radio
    self.pathHashSize = pathHashSize
  }

  init(_ title: String, _ mhz: Double, sf: UInt8, bw: Double, cr: UInt8, hash: Int? = nil) {
    self.init(
      title: title,
      radio: RadioParameters(frequencyMHz: mhz, bandwidthKHz: bw, spreadingFactor: sf, codingRate: cr),
      pathHashSize: hash
    )
  }

  public static let builtIn: [RadioPreset] = [
    RadioPreset("Australia", 915.800, sf: 10, bw: 250, cr: 5),
    RadioPreset("Australia (Narrow)", 916.575, sf: 7, bw: 62.5, cr: 7),
    RadioPreset("Australia (Mid)", 915.075, sf: 9, bw: 125, cr: 5),
    RadioPreset("Australia: SA, WA", 923.125, sf: 8, bw: 62.5, cr: 8),
    RadioPreset("Australia: QLD", 923.125, sf: 8, bw: 62.5, cr: 5),
    RadioPreset("Brazil", 923.125, sf: 8, bw: 62.5, cr: 8),
    RadioPreset("Canada", 910.525, sf: 7, bw: 62.5, cr: 5, hash: 3),
    RadioPreset("Costa Rica", 910.525, sf: 11, bw: 125, cr: 5),
    RadioPreset("EU/UK (Narrow)", 869.618, sf: 8, bw: 62.5, cr: 8),
    RadioPreset("EU/UK (Deprecated)", 869.525, sf: 11, bw: 250, cr: 5),
    RadioPreset("Czech Republic (Narrow)", 869.432, sf: 7, bw: 62.5, cr: 5, hash: 2),
    RadioPreset("EU 433MHz (Long Range)", 433.650, sf: 11, bw: 250, cr: 5),
    RadioPreset("EU 433MHz (Narrow)", 433.650, sf: 8, bw: 62.5, cr: 8),
    RadioPreset("Hungary", 869.618, sf: 7, bw: 62.5, cr: 5, hash: 2),
    RadioPreset("Netherlands", 869.618, sf: 7, bw: 62.5, cr: 5),
    RadioPreset("Netherlands (Limburg)", 869.618, sf: 8, bw: 62.5, cr: 8, hash: 2),
    RadioPreset("New Zealand (Narrow)", 917.375, sf: 7, bw: 62.5, cr: 5, hash: 2),
    RadioPreset("New Zealand (Gisborne)", 917.375, sf: 11, bw: 250, cr: 5, hash: 1),
    RadioPreset("Portugal 433", 433.375, sf: 9, bw: 62.5, cr: 6),
    RadioPreset("Portugal 868", 869.618, sf: 7, bw: 62.5, cr: 6),
    RadioPreset("Slovakia", 869.618, sf: 7, bw: 62.5, cr: 5, hash: 2),
    RadioPreset("Switzerland", 869.618, sf: 8, bw: 62.5, cr: 8),
    RadioPreset("USA", 910.525, sf: 7, bw: 62.5, cr: 5),
    RadioPreset("USA - Southern California", 927.875, sf: 7, bw: 62.5, cr: 5, hash: 3),
    RadioPreset("Vietnam (Narrow)", 920.250, sf: 8, bw: 62.5, cr: 5),
    RadioPreset("Vietnam (Deprecated)", 920.250, sf: 11, bw: 250, cr: 5),
  ]

  /// Parses the presets API response, tolerating missing keys.
  public static func parseAPIResponse(_ data: Data) -> [RadioPreset]? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let config = root["config"] as? [String: Any],
      let settings = config["suggested_radio_settings"] as? [String: Any],
      let entries = settings["entries"] as? [[String: Any]]
    else { return nil }

    func number(_ value: Any?) -> Double? {
      if let string = value as? String { return Double(string) }
      return (value as? NSNumber)?.doubleValue
    }

    let presets = entries.compactMap { entry -> RadioPreset? in
      guard
        let title = entry["title"] as? String,
        let freq = number(entry["frequency"]),
        let sf = number(entry["spreading_factor"]),
        let bw = number(entry["bandwidth"]),
        let cr = number(entry["coding_rate"])
      else { return nil }
      let network = entry["network_settings"] as? [String: Any]
      let preset = RadioPreset(
        title: title,
        radio: RadioParameters(frequencyMHz: freq, bandwidthKHz: bw, spreadingFactor: UInt8(clamping: Int(sf)), codingRate: UInt8(clamping: Int(cr))),
        pathHashSize: number(network?["path_hash_size"]).map(Int.init)
      )
      return preset.radio.isValid ? preset : nil
    }
    return presets.isEmpty ? nil : presets
  }
}
