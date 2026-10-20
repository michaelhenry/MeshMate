import Foundation

/// Fans a sequence of values out to any number of `AsyncStream` subscribers.
/// `AsyncStream` itself only supports a single consumer.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
  private var latest: Element?
  private let replaysLatest: Bool

  /// - Parameter replaysLatest: New subscribers immediately receive the most
  ///   recent value (useful for state such as Bluetooth power).
  init(replaysLatest: Bool = false) {
    self.replaysLatest = replaysLatest
  }

  func stream() -> AsyncStream<Element> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock {
        continuations[id] = continuation
        if replaysLatest, let latest {
          continuation.yield(latest)
        }
      }
      continuation.onTermination = { [weak self] _ in
        self?.remove(id)
      }
    }
  }

  func yield(_ element: Element) {
    let targets = lock.withLock {
      if replaysLatest { latest = element }
      return Array(continuations.values)
    }
    for continuation in targets {
      continuation.yield(element)
    }
  }

  var currentValue: Element? {
    lock.withLock { latest }
  }

  private func remove(_ id: UUID) {
    lock.withLock {
      _ = continuations.removeValue(forKey: id)
    }
  }
}
