import Foundation

/// Some system XPC APIs do not react to task cancellation. Let the editor recover without waiting for them.
@MainActor enum AsyncDeadline {
    private final class Pending<Value> {
        var continuation: CheckedContinuation<Value, Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var resolved = false
        let cancelOperation: () -> Void
        init(cancelOperation: @escaping () -> Void) { self.cancelOperation = cancelOperation }
        func finish(_ result: Result<Value, Error>) {
            guard !resolved else { return }
            resolved = true
            if case .failure = result { cancelOperation() }
            work?.cancel(); timer?.cancel()
            continuation?.resume(with: result)
            continuation = nil; work = nil; timer = nil
        }
    }
    static func value<Value>(after duration: Duration, cancel: @escaping @MainActor () -> Void = {}, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let pending = Pending<Value>(cancelOperation: cancel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.work = Task {
                    do { pending.finish(.success(try await operation())) }
                    catch { pending.finish(.failure(error)) }
                }
                pending.timer = Task {
                    do { try await Task.sleep(for: duration) } catch { return }
                    pending.finish(.failure(AppFailure(message: "Системный перевод не ответил. Попробуйте ещё раз или выберите ChatGPT.")))
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
}
