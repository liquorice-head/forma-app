import CloudKit
import Foundation

@MainActor final class CloudKitTransport: CloudSyncTransport {
    private let container: CKContainer
    private var records: [String: CKRecord] = [:]
    static let recordType = "FormaSyncItem"

    init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }

    func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncFailure.unavailableAccount }
        try Task.checkCancellation()
        return try await container.userRecordID().recordName
    }

    func fetch() async throws -> [CloudSyncItem] {
        let database = container.privateCloudDatabase
        var fetched: [String: CKRecord] = [:]
        var items: [CloudSyncItem] = []
        var page = try await database.records(matching: CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true)), resultsLimit: 100)
        while true {
            try Task.checkCancellation()
            for (_, outcome) in page.matchResults {
                let record = try outcome.get()
                guard let payload = record["payload"] as? Data else { throw CloudSyncFailure.invalidRecord }
                let item = try JSONDecoder().decode(CloudSyncItem.self, from: payload)
                guard item.id == record.recordID.recordName else { throw CloudSyncFailure.invalidRecord }
                fetched[item.id] = record
                items.append(item)
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 100)
        }
        records = fetched
        return items
    }

    func save(_ items: [CloudSyncItem]) async throws {
        let uploads = try items.map { item -> CKRecord in
            let data = try CloudSyncItem.encodeJSON(item)
            guard data.count < 900_000 else { throw CloudSyncFailure.oversizedRecord }
            let record = records[item.id] ?? CKRecord(recordType: Self.recordType, recordID: .init(recordName: item.id))
            record["payload"] = data as CKRecordValue
            return record
        }
        for offset in stride(from: 0, to: uploads.count, by: 100) {
            try Task.checkCancellation()
            let chunk = Array(uploads[offset..<min(offset + 100, uploads.count)])
            let result = try await container.privateCloudDatabase.modifyRecords(saving: chunk, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            // Every partial failure must be surfaced; never report a successful
            // sync after swallowing a conflict, quota or permission error.
            for record in chunk {
                guard let outcome = result.saveResults[record.recordID] else { throw CloudSyncFailure.invalidRecord }
                records[record.recordID.recordName] = try outcome.get()
            }
        }
    }
}
