import Foundation

struct ProcessedText {
    let text: String
    var cacheHit = false
    var reasoningTokens: Int? = nil
}

struct ProcessingMetrics {
    let firstText: TimeInterval?
    let total: TimeInterval
    let cacheHit: Bool
    let reasoningTokens: Int?

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Exact results only, bounded by both entry count and approximate UTF-8 size.
/// Nothing is written to disk. Callers insert only after completed inference.
struct ProcessingResultCache {
    struct Key: Hashable {
        let account: String
        let model: String
        let reasoning: ReasoningEffort?
        let instructions: String
        let input: String
        var byteCount: Int { account.utf8.count + model.utf8.count + instructions.utf8.count + input.utf8.count }
    }
    private struct Entry { let key: Key; let text: String; let bytes: Int }
    private var entries: [Entry] = []
    private var bytes = 0
    let capacity: Int
    let byteLimit: Int

    init(capacity: Int = 64, byteLimit: Int = 2 * 1024 * 1024) {
        self.capacity = capacity; self.byteLimit = byteLimit
    }

    mutating func value(for key: Key) -> String? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.text
    }

    mutating func insert(_ text: String, for key: Key) {
        guard capacity > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let size = key.byteCount + text.utf8.count
        guard size <= byteLimit else { return }
        if let index = entries.firstIndex(where: { $0.key == key }) { bytes -= entries.remove(at: index).bytes }
        while !entries.isEmpty && (entries.count >= capacity || bytes + size > byteLimit) {
            bytes -= entries.removeFirst().bytes
        }
        entries.append(Entry(key: key, text: text, bytes: size)); bytes += size
    }

    mutating func removeAll() { entries.removeAll(); bytes = 0 }
}

/// Show the first text immediately; coalesce subsequent deltas with a trailing
/// flush even if the network pauses. Completion flushes synchronously.
@MainActor final class StreamingTextPublisher {
    private let interval: Duration
    private let publish: @MainActor (String) -> Void
    private var lastSent: ContinuousClock.Instant?
    private var sent = ""
    private var pending: String?
    private var task: Task<Void, Never>?

    init(interval: Duration = .milliseconds(40), publish: @escaping @MainActor (String) -> Void) {
        self.interval = interval; self.publish = publish
    }

    func send(_ text: String) {
        guard !text.isEmpty, text != sent else { return }
        pending = text
        let now = ContinuousClock.now
        guard let lastSent, now - lastSent < interval else { flush(); return }
        guard task == nil else { return }
        let delay = interval - (now - lastSent)
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.task = nil
            self?.flush()
        }
    }

    func finish(_ text: String) { pending = text; flush() }
    func cancel() { task?.cancel(); task = nil; pending = nil }
    deinit { task?.cancel() }

    private func flush() {
        task?.cancel(); task = nil
        guard let text = pending else { return }
        pending = nil
        guard text != sent else { return }
        sent = text; lastSent = .now
        publish(text)
    }
}

enum InputChange {
    case typing, paste

    static func automaticDelay(from old: String, to new: String, change: Self) -> Duration {
        if change == .paste { return .zero }
        // TextEditor's binding does not distinguish keyboard paste. A multi-character
        // insertion/replacement is also safe to submit immediately; ordinary typing
        // and deletion retain a short debounce.
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let oldTail = old.dropFirst(prefix), newTail = new.dropFirst(prefix)
        let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix(while: { $0 == $1 }).count
        return newTail.count - suffix > 1 ? .zero : .milliseconds(500)
    }
}
