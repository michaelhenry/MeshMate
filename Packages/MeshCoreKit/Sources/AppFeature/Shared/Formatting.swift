import Foundation
import MeshCoreProtocol
import SwiftUI

extension ChannelInfo {
  var conversationID: ConversationID { .forChannel(self) }

  var displayName: String {
    if name.isEmpty { return "Channel \(index)" }
    return name
  }

  var kindLabel: String {
    if isPublic { return "Public" }
    if isHashtag { return "Hashtag" }
    return "Private"
  }
}

extension NodeType {
  var symbolName: String {
    switch self {
    case .none: "questionmark.circle"
    case .chat: "person.fill"
    case .repeater: "antenna.radiowaves.left.and.right"
    case .room: "bubble.left.and.bubble.right.fill"
    case .sensor: "thermometer.medium"
    }
  }

  var tint: Color {
    switch self {
    case .none: .gray
    case .chat: .blue
    case .repeater: .orange
    case .room: .purple
    case .sensor: .green
    }
  }
}

enum Format {
  static func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "never" }
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  static func duration(seconds: UInt32) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
  }

  static func voltage(_ millivolts: UInt16) -> String {
    String(format: "%.2f V", Double(millivolts) / 1000)
  }

  static func snr(_ value: Double?) -> String {
    guard let value else { return "–" }
    return String(format: "%+.1f dB", value)
  }

  static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
    String(format: "%.5f, %.5f", latitude, longitude)
  }

  static func shortKey(_ hex: String) -> String {
    hex.count > 12 ? "\(hex.prefix(8))…\(hex.suffix(4))" : hex
  }

  static func hops(_ hops: Int?) -> String? {
    guard let hops else { return nil }
    return hops == 0 ? "direct" : (hops == 1 ? "1 hop" : "\(hops) hops")
  }

  static func storage(usedKB: UInt32?, totalKB: UInt32?) -> String? {
    guard let usedKB, let totalKB, totalKB > 0 else { return nil }
    return "\(usedKB) / \(totalKB) KB"
  }
}

extension PathLength {
  /// Hop count for a message's path field (nil when it arrived direct).
  var messageHops: Int? { isFlood ? nil : hopCount }
}
