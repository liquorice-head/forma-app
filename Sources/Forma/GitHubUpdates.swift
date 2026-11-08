import Foundation
import Security

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let id: Int
        let name: String
        let state: String
    }
    let draft: Bool
    let prerelease: Bool
    let tag_name: String
    let assets: [Asset]
}

enum GitHubUpdates {
    static let repository = "liquorice-head/forma-app"
    static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    static func assetURL(_ id: Int) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(id)")!
    }
    static func isAssetURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let prefix = "/repos/\(repository)/releases/assets/"
        guard url.path.hasPrefix(prefix) else { return false }
        let suffix = url.path.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func feed(in releases: [GitHubRelease], allowPrereleases: Bool) throws -> URL {
        guard let asset = releases.first(where: {
            !$0.draft && (allowPrereleases || !$0.prerelease) && $0.assets.contains { $0.name == "appcast.xml" && $0.state == "uploaded" && $0.id > 0 }
        })?.assets.first(where: { $0.name == "appcast.xml" && $0.state == "uploaded" && $0.id > 0 }) else {
            throw UpdateFailure.noRelease
        }
        return assetURL(asset.id)
    }
    static func resolve(token: String?, allowPrereleases: Bool, session: URLSession) async throws -> URL {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 25
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw UpdateFailure.unavailable }
        guard status == 200 else {
            if [401, 403, 404].contains(status) { throw UpdateFailure.accessRequired }
            throw UpdateFailure.unavailable
        }
        let asset = try feed(in: JSONDecoder().decode([GitHubRelease].self, from: data), allowPrereleases: allowPrereleases)
        // Sparkle overrides Accept with RSS, which makes GitHub's asset API return
        // JSON metadata instead of the signed XML. Resolve GitHub's download redirect
        // ourselves, then give Sparkle the credential-free, temporary CDN URL.
        var download = URLRequest(url: asset)
        download.timeoutInterval = 25
        download.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        download.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { download.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, assetResponse) = try await session.data(for: download)
        guard let response = assetResponse as? HTTPURLResponse else { throw UpdateFailure.unavailable }
        if [401, 403, 404].contains(response.statusCode) { throw UpdateFailure.accessRequired }
        return try feedDownloadURL(from: response)
    }
    static func feedDownloadURL(from response: HTTPURLResponse) throws -> URL {
        // HTTPClient deliberately stops cross-origin redirects, retaining GitHub's
        // Location header without ever forwarding a GitHub token to the CDN.
        guard response.statusCode == 302, let origin = response.url, isAssetURL(origin),
              let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location), url.scheme == "https",
              url.host == "release-assets.githubusercontent.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw UpdateFailure.invalidAsset
        }
        return url
    }
    static func authorizeArchive(_ request: NSMutableURLRequest, token: String?) {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        if let token, let url = request.url, isAssetURL(url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

enum UpdateFailure: LocalizedError {
    case accessRequired, noRelease, unavailable, invalidAsset
    var errorDescription: String? {
        switch self {
        case .accessRequired: "Для обновлений из закрытого репозитория сохраните GitHub-токен с правом Contents: Read для Forma."
        case .noRelease: "Новых опубликованных релизов пока нет."
        case .unavailable: "Не удалось проверить обновления. Попробуйте позже."
        case .invalidAsset: "Адрес обновления не прошёл проверку. Установка отменена."
        }
    }
}

enum UpdateCredentials {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: AppIdentity.credentialService("app.forma.updates.github"),
        kSecAttrAccount as String: "read-token",
        kSecAttrSynchronizable as String: false
    ] }
    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AppFailure(message: "Не удалось прочитать доступ к обновлениям из Связки ключей.")
        }
        return token
    }
    static func save(_ token: String?) throws {
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw UpdateFailure.unavailable }
            return
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw UpdateFailure.unavailable }
        } else if status != errSecSuccess { throw UpdateFailure.unavailable }
    }
}
