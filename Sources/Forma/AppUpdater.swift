import Foundation
import Observation
import Sparkle

@MainActor @Observable final class AppUpdater: NSObject, SPUUpdaterDelegate {
    var automaticChecks = UserDefaults.standard.object(forKey: "updates.check") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "updates.check"); schedule() }
    }
    var automaticInstall = UserDefaults.standard.object(forKey: "updates.install") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticInstall, forKey: "updates.install"); controller?.updater.automaticallyDownloadsUpdates = automaticInstall }
    }
    var includePrereleases = UserDefaults.standard.object(forKey: "updates.preview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includePrereleases, forKey: "updates.preview") }
    }
    private(set) var busy = false
    private(set) var hasToken = false
    private(set) var status: String?
    private(set) var installationDeferred = false
    @ObservationIgnored var beforeInstall: (() throws -> Void)?
    @ObservationIgnored var onAccessRequired: (() -> Void)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private let session = HTTPClient.make()
    private var feed: URL?
    private var started = false
    var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    override init() {
        super.init()
        do { token = try UpdateCredentials.load(); hasToken = token != nil }
        catch { status = error.localizedDescription }
    }
    func start() {
        guard !started, configured else { return }
        started = true
        schedule()
    }
    private func schedule() {
        scheduler?.cancel()
        guard started else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks { await self.performCheck(interactive: false) }
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
            }
        }
    }
    func checkForUpdates() { Task { await performCheck(interactive: true) } }
    func saveAccess(_ value: String) {
        do {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try UpdateCredentials.save(cleaned.isEmpty ? nil : cleaned)
            token = cleaned.isEmpty ? nil : cleaned
            hasToken = token != nil
            status = nil
            checkForUpdates()
        } catch { status = error.localizedDescription }
    }
    private func performCheck(interactive: Bool) async {
        guard configured, !busy, !installationDeferred, controller?.updater.sessionInProgress != true else { return }
        busy = true; status = "Проверяем обновления…"
        do {
            var effectiveToken = token
            do {
                feed = try await GitHubUpdates.resolve(token: token, allowPrereleases: includePrereleases, session: session)
            } catch UpdateFailure.accessRequired where token != nil {
                // A repository can become public while a previously saved token expires.
                feed = try await GitHubUpdates.resolve(token: nil, allowPrereleases: includePrereleases, session: session)
                effectiveToken = nil
            }
            if controller == nil {
                controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            }
            guard let updater = controller?.updater else { throw UpdateFailure.unavailable }
            updater.httpHeaders = ["Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28"]
            if let effectiveToken { updater.httpHeaders?["Authorization"] = "Bearer \(effectiveToken)" }
            // GitHub's private asset IDs change per release; our scheduler resolves the current feed first.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = automaticInstall
            if !updaterStarted { try updater.start(); updaterStarted = true }
            if interactive { controller?.checkForUpdates(nil) }
            else { updater.checkForUpdatesInBackground() }
        } catch {
            busy = false
            status = (error as? UpdateFailure)?.localizedDescription ?? "Не удалось проверить обновления. Попробуйте позже."
            if interactive, case UpdateFailure.accessRequired = error { onAccessRequired?() }
        }
    }
    private var updaterStarted = false
    func feedURLString(for updater: SPUUpdater) -> String? { feed?.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { includePrereleases ? ["preview"] : [] }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let url = updateItem.fileURL, GitHubUpdates.isAssetURL(url) else { throw UpdateFailure.invalidAsset }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        busy = false
        let failure = error as NSError?
        if let failure, failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) {
            status = "Установлена последняя версия."
        } else {
            status = error == nil ? "Проверка обновлений завершена." : "Не удалось проверить обновления. Попробуйте позже."
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        do { try beforeInstall?(); return false }
        catch {
            pendingInstall = installHandler
            installationDeferred = true; busy = false
            status = "Не удалось сохранить текст перед обновлением. Повторите установку."
            return true
        }
    }
    func retryInstallation() {
        do {
            try beforeInstall?()
            let handler = pendingInstall
            pendingInstall = nil; installationDeferred = false
            handler?()
        } catch { status = "Не удалось сохранить текст перед обновлением. Повторите установку." }
    }
    deinit { scheduler?.cancel() }
}
