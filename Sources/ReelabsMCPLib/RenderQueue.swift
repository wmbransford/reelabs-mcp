import Foundation

/// Continuation-based mutex that serializes render jobs.
/// Swift actors can interleave at each `await` suspension point, so a bare
/// actor method doesn't guarantee mutual exclusion across an entire async
/// operation. This queue uses a waiters list to hand the lock directly from
/// one job to the next, preventing interleaving.
package actor RenderQueue {
    package static let shared = RenderQueue()

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func acquireLock() async {
        if isRunning {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            // Resumed — we inherit the lock (isRunning stays true)
        } else {
            isRunning = true
        }
    }

    private func releaseLock() {
        if !waiters.isEmpty {
            // Hand lock directly to next waiter (isRunning stays true)
            waiters.removeFirst().resume()
        } else {
            isRunning = false
        }
    }

    package func enqueue<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquireLock()
        do {
            let result = try await work()
            releaseLock()
            return result
        } catch {
            releaseLock()
            throw error
        }
    }
}
