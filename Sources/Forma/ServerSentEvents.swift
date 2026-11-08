import Foundation

/// Preserve empty lines: they delimit SSE events and must not be dropped by a line iterator.
struct ServerSentEvents {
    private var line = Data()
    private var dataLines: [String] = []
    private var afterCarriageReturn = false
    private var firstLine = true

    mutating func consume(_ byte: UInt8) throws -> String? {
        if byte == 10 && afterCarriageReturn {
            afterCarriageReturn = false
            return nil
        }
        afterCarriageReturn = byte == 13
        if byte == 10 || byte == 13 { return try finishLine() }
        line.append(byte)
        guard line.count <= 4 * 1024 * 1024 else { throw Self.invalidStream }
        return nil
    }

    private mutating func finishLine() throws -> String? {
        guard var value = String(data: line, encoding: .utf8) else { throw Self.invalidStream }
        line.removeAll(keepingCapacity: true)
        if firstLine { value = value.replacingOccurrences(of: "^\u{feff}", with: "", options: .regularExpression); firstLine = false }
        if value.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return event
        }
        guard value == "data" || value.hasPrefix("data:") else { return nil }
        var field = value == "data" ? "" : String(value.dropFirst(5))
        if field.first == " " { field.removeFirst() }
        dataLines.append(field)
        return nil
    }

    private static var invalidStream: AppFailure {
        AppFailure(message: "Не удалось прочитать ответ OpenAI. Повторите запрос.")
    }
}
