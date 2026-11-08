import Foundation

@MainActor final class DebouncedAction {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration = .milliseconds(500), action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
