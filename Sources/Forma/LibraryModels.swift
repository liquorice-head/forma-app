import Foundation
import CryptoKit

enum WritingMode: String, CaseIterable, Identifiable, Codable {
    case translate = "Перевод", correct = "Коррекция", rewrite = "Переписать"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .translate: "character.bubble"
        case .correct: "checkmark.bubble"
        case .rewrite: "pencil.and.outline"
        }
    }
    var hint: String {
        switch self {
        case .translate: "Тот же смысл. На другом языке."
        case .correct: "Ошибки и пунктуация. Ваши формулировки."
        case .rewrite: "Ваши мысли. Более точные слова."
        }
    }
}

struct MemoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var source: String
    var preferred: String
    var languages: String
    var context: String? = nil
    var modifiedAt = Date()
    var deleted = false
    enum CodingKeys: CodingKey { case id, source, preferred, languages, context, modifiedAt, deleted }
    init(source: String, preferred: String, languages: String, context: String? = nil) {
        self.source = source; self.preferred = preferred; self.languages = languages; self.context = context
        // The same phrase on two offline Macs must converge to one preference record.
        var bytes = Array(SHA256.hash(data: Data((source.precomposedStringWithCanonicalMapping + "\0" + languages).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(String.self, forKey: .source)
        preferred = try values.decode(String.self, forKey: .preferred)
        languages = try values.decode(String.self, forKey: .languages)
        context = try values.decodeIfPresent(String.self, forKey: .context)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        deleted = try values.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var mode: WritingMode
    var source: String
    var result: String
    var date = Date()
    var sourceLanguage: String? = nil
    var targetLanguage: String? = nil
    var engine: String? = nil
}

