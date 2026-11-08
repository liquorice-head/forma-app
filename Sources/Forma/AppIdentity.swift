import Foundation

enum AppIdentity {
    static let productionBundleIdentifier = "app.forma.prototype"

    /// Preserve existing credentials for Forma; alternate app identities must use
    /// their own items because macOS grants Keychain access to a signed identity.
    static func credentialService(_ service: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard bundleIdentifier != productionBundleIdentifier else { return service }
        return service + ".variant." + (bundleIdentifier ?? "unbundled")
    }
}
