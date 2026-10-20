import Foundation
import MeshCoreProtocol

/// Serialises commands to the radio and matches replies to them.
///
/// The companion protocol is strictly request/response: the firmware answers
/// commands in order, while push frames (codes ≥ 0x80) can arrive at any time.
/// Only one command is in flight at once; later callers wait their turn.
actor CommandPipeline {
  private struct Pending {
    let id: UInt64
    let command: Command
    var frames: [ResponseFrame] = []
    var continuation: CheckedContinuation<[ResponseFrame], Error>?
    var result: Result<[ResponseFrame], Error>?
  }

  private let write: @Sendable (Data) async throws -> Void
  private let onPush: @Sendable (PushEvent) -> Void
  private let onUnsolicited: @Sendable (ResponseFrame) -> Void

  private var current: Pending?
  private var nextID: UInt64 = 0
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var closedError: MeshCoreError?

  init(
    write: @escaping @Sendable (Data) async throws -> Void,
    onPush: @escaping @Sendable (PushEvent) -> Void,
    onUnsolicited: @escaping @Sendable (ResponseFrame) -> Void = { _ in }
  ) {
    self.write = write
    self.onPush = onPush
    self.onUnsolicited = onUnsolicited
  }

  // MARK: Sending

  func send(_ command: Command) async throws -> [ResponseFrame] {
    if let closedError { throw closedError }
    await acquire()
    defer { release() }
    if let closedError { throw closedError }

    nextID &+= 1
    let id = nextID
    let frame = command.encoded()

    guard command.responseExpectation != .none else {
      try await write(frame)
      return []
    }

    // Register before writing so a fast reply can't be missed.
    current = Pending(id: id, command: command)
    do {
      try await write(frame)
    } catch {
      if current?.id == id { current = nil }
      throw (error as? MeshCoreError) ?? MeshCoreError.writeFailed(error.localizedDescription)
    }

    let timeoutTask = Task { [weak self] in
      try await Task.sleep(for: command.timeout)
      await self?.complete(id, with: .failure(MeshCoreError.timeout))
    }
    defer { timeoutTask.cancel() }

    return try await withCheckedThrowingContinuation { continuation in
      install(continuation, for: id)
    }
  }

  private func install(_ continuation: CheckedContinuation<[ResponseFrame], Error>, for id: UInt64) {
    guard var pending = current, pending.id == id else {
      // Already torn down (e.g. disconnected while writing).
      continuation.resume(throwing: closedError ?? MeshCoreError.disconnected)
      return
    }
    if let result = pending.result {
      current = nil
      continuation.resume(with: result)
    } else {
      pending.continuation = continuation
      current = pending
    }
  }

  private func complete(_ id: UInt64, with result: Result<[ResponseFrame], Error>) {
    guard var pending = current, pending.id == id else { return }
    if let continuation = pending.continuation {
      current = nil
      continuation.resume(with: result)
    } else if pending.result == nil {
      pending.result = result
      current = pending
    }
  }

  // MARK: Receiving

  /// Feed every frame received from the radio, in order.
  func receive(_ data: Data) {
    let frame: ResponseFrame
    do {
      frame = try ResponseFrame(decoding: data)
    } catch {
      return
    }

    if case let .push(push) = frame {
      if let pending = current, pending.result == nil, pending.command.acceptsAsReply(push) {
        complete(pending.id, with: .success(pending.frames + [frame]))
      } else {
        onPush(push)
      }
      return
    }

    guard var pending = current, pending.result == nil,
          pending.command.isPlausibleReply(frame)
    else {
      onUnsolicited(frame)
      return
    }
    pending.frames.append(frame)
    current = pending
    if pending.command.isTerminal(frame) {
      complete(pending.id, with: .success(pending.frames))
    }
  }

  /// Fails the in-flight command and every queued one.
  func close(with error: MeshCoreError = .disconnected) {
    closedError = error
    if let pending = current {
      complete(pending.id, with: .failure(error))
    }
    let queued = waiters
    waiters.removeAll()
    isBusy = false
    queued.forEach { $0.resume() }
  }

  // MARK: Turn-taking

  private func acquire() async {
    if !isBusy {
      isBusy = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      // Hand the turn directly to the next waiter; `isBusy` stays true.
      waiters.removeFirst().resume()
    }
  }
}
