import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ChatGPTProfile: Codable, Identifiable {
    var id: String { clientID }
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var sharing: Bool { scopes.contains("chatgpt.tokens.use.direct") && accessToken != nil }
}

enum CredentialStore {
    private static func query(service: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "connections",
        kSecAttrSynchronizable as String: false
    ] }
    static func load(service: String = AppIdentity.credentialService("app.forma.chatgpt")) throws -> [ChatGPTProfile] {
        var request = query(service: service)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppFailure(message: "Не удалось прочитать подключение из Связки ключей.")
        }
        return try JSONDecoder().decode([ChatGPTProfile].self, from: data)
    }
    static func save(_ profiles: [ChatGPTProfile], service: String = AppIdentity.credentialService("app.forma.chatgpt")) throws {
        let data = try JSONEncoder().encode(profiles)
        let query = query(service: service)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw AppFailure(message: "Не удалось сохранить подключение в Связке ключей.")
            }
        } else if status != errSecSuccess {
            throw AppFailure(message: "Не удалось сохранить подключение в Связке ключей.")
        }
    }
}

struct OpenIDConfiguration: Decodable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let jwks_uri: URL
    let revocation_endpoint: URL?
    func validate() throws {
        guard issuer == "https://auth.openai.com",
              [authorization_endpoint, token_endpoint, jwks_uri].allSatisfy({ $0.scheme == "https" && $0.host == "auth.openai.com" }),
              revocation_endpoint == nil || (revocation_endpoint?.scheme == "https" && revocation_endpoint?.host == "auth.openai.com") else {
            throw AppFailure(message: "Не удалось проверить сервер входа OpenAI.")
        }
    }
}

struct PublicJWK: Decodable {
    let kty: String
    let kid: String
    let n: String?
    let e: String?
}

enum IdentityToken {
    static func verify(_ token: String, audience: String, nonce: String?, keys: [PublicJWK], now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let jwk = keys.first(where: { $0.kid == kid && $0.kty == "RSA" }),
              let modulus = jwk.n.flatMap(Data.init(base64URL:)), let exponent = jwk.e.flatMap(Data.init(base64URL:)) else {
            throw AppFailure(message: "Не удалось проверить подпись аккаунта OpenAI.")
        }
        let der = derValue(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw AppFailure(message: "Не удалось проверить подпись аккаунта OpenAI.")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == "https://auth.openai.com", audiences.contains(audience),
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? TimeInterval, expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? TimeInterval ?? 0) <= now.timeIntervalSince1970 + 60,
              (claims["iat"] as? TimeInterval ?? 0) <= now.timeIntervalSince1970 + 60,
              claims["azp"] == nil || claims["azp"] as? String == audience,
              nonce == nil || claims["nonce"] as? String == nonce else {
            throw AppFailure(message: "Не удалось подтвердить аккаунт OpenAI. Повторите вход.")
        }
        return claims
    }
    private static func derInteger(_ data: Data) -> Data {
        var value = Data(data.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return derValue(0x02, value)
    }
    private static func derValue(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else {
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + data
    }
}

extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func secureRandom() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppFailure(message: "Не удалось начать безопасный вход.")
        }
        return Data(bytes)
    }
}

@MainActor private final class OAuthCallback {
    private var listener: NWListener?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private let expectedState: String
    private var timeout: Task<Void, Never>?
    init(state: String) { expectedState = state }

    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection, buffer: Data()) } }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            readyContinuation = ready
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.readyContinuation?.resume(); self.readyContinuation = nil
                    case .failed(let error):
                        self.readyContinuation?.resume(throwing: error); self.readyContinuation = nil
                        self.finish(.failure(error))
                    case .cancelled:
                        self.readyContinuation?.resume(throwing: CancellationError()); self.readyContinuation = nil
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        guard let port = listener.port else { throw AppFailure(message: "Не удалось открыть окно входа.") }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(AppFailure(message: "Время входа истекло. Попробуйте ещё раз.")))
        }
        return "http://127.0.0.1:\(port.rawValue)/auth/callback"
    }
    func wait() async throws -> [String: String] {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<[String: String], Error>) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel()
        listener?.cancel()
        waiter?.resume(with: result)
        waiter = nil
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
            guard let self else { connection.cancel(); return }
            let accumulated = buffer + (data ?? Data())
            guard accumulated.count <= 16384, error == nil else { connection.cancel(); return }
            guard let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, buffer: accumulated) } else { connection.cancel() }
                return
            }
            let firstLine = request.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard firstLine.count == 3, firstLine[0] == "GET", firstLine[1].hasPrefix("/auth/callback?"),
                  let components = URLComponents(string: "http://127.0.0.1" + firstLine[1]),
                  components.path == "/auth/callback" else { self.reply(connection, status: "404 Not Found", message: "Not found"); return }
            var values: [String: String] = [:]
            for item in components.queryItems ?? [] {
                guard values[item.name] == nil else { self.reply(connection, status: "400 Bad Request", message: "Invalid callback"); return }
                values[item.name] = item.value ?? ""
            }
            guard values["state"] == self.expectedState else { self.reply(connection, status: "400 Bad Request", message: "Invalid state"); return }
            self.reply(connection, status: "200 OK", message: "Return to Forma to complete sign-in. You can close this tab.")
            self.finish(.success(values))
            }
        }
    }
    private func reply(_ connection: NWConnection, status: String, message: String) {
        let body = "<!doctype html><meta charset=utf-8><title>Forma</title><p>\(message)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor @Observable final class ChatGPTAccount {
    var profiles: [ChatGPTProfile] = []
    var selectedID: String? = UserDefaults.standard.string(forKey: "chatgpt.selected") {
        didSet { UserDefaults.standard.set(selectedID, forKey: "chatgpt.selected") }
    }
    var busy = false
    var message: String?
    var showPlanNotice = false
    private var cancelRequested = false
    private var configuration: OpenIDConfiguration?
    private var callback: OAuthCallback?
    private var refreshTask: Task<ChatGPTProfile, Error>?
    private let http = HTTPClient.shared
    var active: ChatGPTProfile? { profiles.first { $0.clientID == selectedID } }
    var connected: Bool { active?.sharing == true }
    var inferenceScope: String? {
        guard let active, active.sharing else { return nil }
        return active.clientID + ":" + active.subject
    }
    private var hostID: String {
        if let value = UserDefaults.standard.string(forKey: "chatgpt.host") { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "chatgpt.host")
        return value
    }
    init() {
        do { profiles = try CredentialStore.load() }
        catch { message = error.localizedDescription }
    }
    private func discover() async throws -> OpenIDConfiguration {
        if let configuration { return configuration }
        let (data, response) = try await http.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure(message: "Сервер входа OpenAI недоступен.") }
        let value = try JSONDecoder().decode(OpenIDConfiguration.self, from: data)
        try value.validate()
        configuration = value
        return value
    }
    func signIn(addAccount: Bool = false) async {
        guard !busy else { return }
        busy = true; message = nil; cancelRequested = false
        defer { busy = false; callback = nil }
        do {
            let config = try await discover()
            try checkSignInCancellation()
            let existing = addAccount ? nil : active
            let state = try Data.secureRandom().base64URL
            let nonce = try Data.secureRandom().base64URL
            let verifier = try Data.secureRandom().base64URL
            let receiver = OAuthCallback(state: state)
            callback = receiver
            let redirect = try await receiver.start()
            try checkSignInCancellation()
            var url = URLComponents(url: config.authorization_endpoint, resolvingAgainstBaseURL: false)!
            var fields: [String: String] = [
                "client_id": existing?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                "response_type": "code", "redirect_uri": redirect,
                "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            ]
            if existing == nil { fields["agent_name_hint"] = "Forma" }
            if let hint = existing?.idToken { fields["id_token_hint"] = hint }
            url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let destination = url.url, NSWorkspace.shared.open(destination) else { throw AppFailure(message: "Не удалось открыть браузер для входа.") }
            let values = try await receiver.wait()
            guard values["error"] == nil else { throw AppFailure(message: "Вход отменён или разрешение не предоставлено.") }
            guard let clientID = values["client_id"] ?? existing?.clientID, clientID != "dynamic_agent_client", !clientID.isEmpty,
                  existing == nil || existing?.clientID == clientID, let code = values["code"], !code.isEmpty else {
                throw AppFailure(message: "OpenAI вернул неполное подключение. Повторите вход.")
            }
            let token = try await post(config.token_endpoint, fields: ["grant_type": "authorization_code", "client_id": clientID,
                "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": "https://api.openai.com/v1"])
            let profile = try await validatedProfile(token, clientID: clientID, nonce: nonce, previous: existing, config: config)
            try checkSignInCancellation()
            try save(profile)
            selectedID = profile.clientID
            if profile.sharing && !UserDefaults.standard.bool(forKey: "chatgpt.usageConfirmed." + profile.clientID) { showPlanNotice = true }
            message = profile.sharing ? "Используется ваш тариф ChatGPT." : "Вход выполнен. Разрешите использование тарифа ChatGPT для обработки текста."
        } catch is CancellationError { message = nil }
        catch { message = error.localizedDescription; callback?.cancel() }
    }
    func cancelSignIn() { cancelRequested = true; callback?.cancel() }
    private func checkSignInCancellation() throws { if cancelRequested { throw CancellationError() } }
    func confirmPlanNotice() {
        if let selectedID { UserDefaults.standard.set(true, forKey: "chatgpt.usageConfirmed." + selectedID) }
        showPlanNotice = false
    }
    func bearerToken() async throws -> String {
        guard let profile = active, profile.sharing else { throw AppFailure(message: "Подключите ChatGPT в настройках или выберите перевод Apple.") }
        if profile.expiresAt > Date().addingTimeInterval(90), let token = profile.accessToken { return token }
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard refreshed.sharing, let token = refreshed.accessToken else { throw AppFailure(message: "Подключите ChatGPT в настройках или выберите перевод Apple.") }
            return token
        }
        let task = Task { () throws -> ChatGPTProfile in
            guard let refresh = profile.refreshToken else { throw AppFailure(message: "Войдите в ChatGPT повторно.") }
            let config = try await discover()
            let token = try await post(config.token_endpoint, fields: ["grant_type": "refresh_token", "client_id": profile.clientID,
                "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
            let refreshed = try await validatedProfile(token, clientID: profile.clientID, nonce: nil, previous: profile, config: config)
            try Task.checkCancellation()
            try save(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        guard refreshed.sharing, let token = refreshed.accessToken else { throw AppFailure(message: "Подключите ChatGPT в настройках или выберите перевод Apple.") }
        return token
    }
    func signOut() async {
        guard let profile = active else { return }
        refreshTask?.cancel()
        busy = true
        defer { busy = false }
        var revoked = false
        do {
            let config = try await discover()
            if let endpoint = config.revocation_endpoint, let refresh = profile.refreshToken {
                _ = try await post(endpoint, fields: ["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID], allowEmpty: true)
                revoked = true
            }
        } catch { }
        var cleared = profile
        cleared.accessToken = nil; cleared.refreshToken = nil; cleared.idToken = nil; cleared.scopes = []
        do { try save(cleared) }
        catch { message = error.localizedDescription; return }
        message = revoked ? "Вы вышли из ChatGPT." : "Вы вышли на этом Mac. Для отзыва доступа откройте настройки ChatGPT."
    }
    private func save(_ profile: ChatGPTProfile) throws {
        var updated = profiles.filter { $0.clientID != profile.clientID }
        updated.append(profile)
        try CredentialStore.save(updated)
        profiles = updated
    }
    private func validatedProfile(_ token: [String: Any], clientID: String, nonce: String?, previous: ChatGPTProfile?, config: OpenIDConfiguration) async throws -> ChatGPTProfile {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer",
              let seconds = token["expires_in"] as? TimeInterval, seconds > 0 else { throw AppFailure(message: "OpenAI вернул неполное подключение. Повторите вход.") }
        var subject = previous?.subject ?? ""
        var email = previous?.email ?? "ChatGPT"
        if let idToken = token["id_token"] as? String {
            let (data, response) = try await http.data(from: config.jwks_uri)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure(message: "Не удалось проверить подпись аккаунта OpenAI.") }
            struct Keys: Decodable { let keys: [PublicJWK] }
            let claims = try IdentityToken.verify(idToken, audience: clientID, nonce: nonce, keys: JSONDecoder().decode(Keys.self, from: data).keys)
            subject = claims["sub"] as! String
            email = claims["email"] as? String ?? email
            guard previous == nil || previous?.subject == subject else { throw AppFailure(message: "Аккаунт не совпадает с выбранным подключением.") }
        } else if nonce != nil || previous == nil { throw AppFailure(message: "Не удалось подтвердить аккаунт OpenAI. Повторите вход.") }
        let scopes = (token["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? (nonce == nil ? previous?.scopes ?? [] : [])
        return ChatGPTProfile(clientID: clientID, subject: subject, email: email, accessToken: access,
            refreshToken: token["refresh_token"] as? String ?? previous?.refreshToken,
            idToken: token["id_token"] as? String ?? previous?.idToken, expiresAt: Date().addingTimeInterval(seconds), scopes: scopes)
    }
    private func post(_ url: URL, fields: [String: String], allowEmpty: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = fields.map { ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else { throw AppFailure(message: "Не удалось обновить подключение OpenAI. Повторите вход.") }
        if data.isEmpty && allowEmpty { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure(message: "OpenAI вернул неполное подключение. Повторите вход.") }
        return result
    }
}
