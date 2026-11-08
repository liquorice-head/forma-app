import Foundation

struct RelaunchDraft: Codable {
    var savedAt = Date()
    let mode: WritingMode
    let tone: String
    let sourceLanguage: String
    let targetLanguage: String
    let input: String
    let output: String
    let resultEngine: TextEngine?
    let screen: String?
    var accessibilityRestart: Bool? = nil
}

enum RelaunchStore {
    private static func file(in directory: URL?) -> URL {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forma", isDirectory: true)
        return root.appendingPathComponent("relaunch.json")
    }

    static func save(_ draft: RelaunchDraft, directory: URL? = nil) throws {
        let url = file(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Set permissions before writing any text, including the first save.
        let data = try JSONEncoder().encode(draft)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func take(directory: URL? = nil, now: Date = Date()) throws -> RelaunchDraft? {
        let url = file(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(RelaunchDraft.self, from: Data(contentsOf: url))
        try FileManager.default.removeItem(at: url)
        guard abs(now.timeIntervalSince(draft.savedAt)) < 600 else { return nil }
        return draft
    }

    static func discard(directory: URL? = nil) { try? FileManager.default.removeItem(at: file(in: directory)) }
}
