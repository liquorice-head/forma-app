import AppKit
import ServiceManagement
import Testing
@testable import Forma

struct PreferencesTests {
    @Test func titleBarDraggingLeavesInteractiveControlsAndResizeEdgesAlone() {
        for width in [420.0, 480.0, 640.0] {
            let size = NSSize(width: width, height: 340)
            let mode = CGRect(x: 44, y: 8, width: width - 140, height: 28)
            let actions = CGRect(x: width - 80, y: 8, width: 68, height: 28)
            let controls = [mode, actions]
            for control in controls {
                let point = NSPoint(x: control.midX, y: size.height - control.midY)
                #expect(!PopupLayout.canDrag(at: point, size: size, controls: controls))
            }
            #expect(PopupLayout.canDrag(at: NSPoint(x: 24, y: 318), size: size, controls: controls))
            #expect(!PopupLayout.canDrag(at: NSPoint(x: 24, y: 338), size: size, controls: controls))
            #expect(!PopupLayout.canDrag(at: NSPoint(x: 3, y: 318), size: size, controls: controls))
            #expect(!PopupLayout.canDrag(at: NSPoint(x: 24, y: 200), size: size, controls: controls))
            #expect(!PopupLayout.canDrag(at: NSPoint(x: 24, y: 318), size: size, controls: []))
        }
    }

    @Test func alternateAppIdentitiesNeverUseTheInstalledAppsCredentials() {
        for service in ["app.forma.chatgpt", "app.forma.updates.github"] {
            #expect(AppIdentity.credentialService(service, bundleIdentifier: "app.forma.prototype") == service)
            let review = AppIdentity.credentialService(service, bundleIdentifier: "app.forma.review")
            let another = AppIdentity.credentialService(service, bundleIdentifier: "app.forma.review2")
            let unbundled = AppIdentity.credentialService(service, bundleIdentifier: nil)
            #expect(Set([service, review, another, unbundled]).count == 4)
            #expect(AppIdentity.credentialService(service, bundleIdentifier: "app.forma.review") == review)
        }
    }

    @Test func languageSearchFindsRussianEnglishNativeNamesAndCodes() throws {
        let dutch = try #require(LanguageCatalog.all.first { $0.code == "nl" })
        for query in ["нидерланд", "DUTCH", "Nederlands", " nl "] {
            #expect(dutch.matches(query))
        }
        #expect(LanguageCatalog.all.contains { $0.matches("украин") && $0.code == "uk" })
        #expect(LanguageCatalog.all.contains { $0.matches("hindi") && $0.code == "hi" })
        let french = try #require(LanguageCatalog.all.first { $0.code == "fr" })
        #expect(french.matches("francais"))
        #expect(LanguageCatalog.sorted(LanguageCatalog.all, query: "zzzz-no-language", english: false).isEmpty)
    }

    @Test func languageCatalogPreservesStoredPairsAndChineseScripts() {
        for value in LanguageCatalog.common {
            #expect(LanguageCatalog.label(LanguageCatalog.code(value)) == value)
        }
        #expect(LanguageCatalog.code("Dutch") == "nl")
        #expect(LanguageCatalog.code("Nederlands") == "nl")
        #expect(LanguageCatalog.label("zh") == "中文")
        #expect(LanguageCatalog.code(LanguageCatalog.label("zh-Hant")) == "zh-Hant")
        #expect(LanguageCatalog.displayName("nl", english: true) == "Dutch")
        #expect(LanguageCatalog.displayName("nl", english: false) == "Нидерландский")
        #expect(LanguageCatalog.all.count == Set(LanguageCatalog.all.map { LanguageCatalog.canonical($0.code) }).count)
    }

    @Test @MainActor func loginItemReflectsExternalChangesAndRegistrationOutcomes() async {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var removals = 0
        let settings = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            status = .requiresApproval
        }, unregister: {
            removals += 1
            status = .notRegistered
        })
        #expect(!settings.enabled && registrations == 0)
        await settings.setEnabled(true)
        #expect(settings.status == .requiresApproval && !settings.enabled && settings.message == nil)
        status = .enabled
        settings.refresh()
        #expect(settings.enabled)
        status = .requiresApproval
        settings.refresh()
        #expect(!settings.enabled)
        await settings.setEnabled(false)
        #expect(settings.status == .notRegistered && removals == 1 && registrations == 1)
    }

    @Test @MainActor func failedLoginItemChangeDoesNotInventSuccess() async {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(readStatus: { status }, register: { throw Failure.denied },
            unregister: { throw Failure.denied })
        await settings.setEnabled(true)
        #expect(!settings.enabled && settings.message != nil && !settings.busy)
        status = .enabled
        await settings.setEnabled(false)
        #expect(settings.enabled && settings.message != nil && !settings.busy)
    }

    @Test @MainActor func approvalStatusTakesPrecedenceOverRegistrationError() async {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(readStatus: { status }, register: {
            status = .requiresApproval
            throw Failure.denied
        }, unregister: { status = .notRegistered })
        await settings.setEnabled(true)
        #expect(settings.status == .requiresApproval && settings.message == nil)
        await settings.setEnabled(false)
        #expect(settings.status == .notRegistered && settings.message == nil)
    }

    @Test func onlyLoginAppleEventSelectsBackgroundLaunch() {
        #expect(!LaunchContext.isLoginItem(nil))
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(!LaunchContext.isLoginItem(event))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        #expect(LaunchContext.isLoginItem(event))
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reopen.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        #expect(!LaunchContext.isLoginItem(reopen))
    }

    private enum Failure: Error { case denied }
}
