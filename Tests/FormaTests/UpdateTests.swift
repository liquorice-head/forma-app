import Foundation
import Testing
@testable import Forma

struct UpdateTests {
    private func release(_ id: Int, draft: Bool = false, preview: Bool = false, state: String = "uploaded") -> GitHubRelease {
        GitHubRelease(draft: draft, prerelease: preview, tag_name: "v0.3.0", assets: [.init(id: id, name: "appcast.xml", state: state)])
    }
    @Test func releaseSelectionSkipsDraftsPartialUploadsAndExcludedPreviews() throws {
        let releases = [release(1, draft: true), release(2, state: "new"), release(3, preview: true), release(4)]
        #expect(try GitHubUpdates.feed(in: releases, allowPrereleases: true) == GitHubUpdates.assetURL(3))
        #expect(try GitHubUpdates.feed(in: releases, allowPrereleases: false) == GitHubUpdates.assetURL(4))
        #expect(throws: UpdateFailure.self) { try GitHubUpdates.feed(in: [release(0), release(1, draft: true)], allowPrereleases: true) }
    }
    @Test func updateArchivesAreLimitedToThisRepositoryAssetAPI() throws {
        #expect(GitHubUpdates.isAssetURL(GitHubUpdates.assetURL(123)))
        for value in [
            "http://api.github.com/repos/liquorice-head/forma-app/releases/assets/123",
            "https://api.github.com.evil.invalid/repos/liquorice-head/forma-app/releases/assets/123",
            "https://api.github.com/repos/other/forma/releases/assets/123",
            "https://api.github.com/repos/liquorice-head/forma-app/releases/assets/123/other",
            "https://api.github.com/repos/liquorice-head/forma-app/releases/assets/",
            "https://api.github.com/repos/liquorice-head/forma-app/releases/assets/١٢٣",
            "https://user@api.github.com/repos/liquorice-head/forma-app/releases/assets/123",
            "https://api.github.com:444/repos/liquorice-head/forma-app/releases/assets/123",
            "https://api.github.com/repos/liquorice-head/forma-app/releases/assets/123?redirect=elsewhere",
            "https://api.github.com/repos/liquorice-head/forma-app/releases/assets/123#fragment"
        ] { #expect(!GitHubUpdates.isAssetURL(try #require(URL(string: value)))) }
    }
    @Test func privateRepositoryRequiresAccessAndAuthenticatedMetadataSelectsFeed() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseResponse.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GitHubUpdates.resolve(token: nil, allowPrereleases: true, session: session)
            Issue.record("An inaccessible private repository must request access.")
        } catch { #expect(error as? UpdateFailure == .accessRequired) }
        #expect(try await GitHubUpdates.resolve(token: "non-credential-test-data", allowPrereleases: true, session: session) == URL(string: "https://release-assets.githubusercontent.com/test/appcast.xml?signature=example"))
    }
    @Test func anonymousPublicFeedResolvesToDownloadInsteadOfGitHubJSONMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PublicReleaseResponse.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        #expect(try await GitHubUpdates.resolve(token: nil, allowPrereleases: false, session: session) == URL(string: "https://release-assets.githubusercontent.com/test/appcast.xml?signature=example"))
    }
    @Test func feedRedirectRejectsMetadataAndUntrustedDestinations() throws {
        for target in ["http://release-assets.githubusercontent.com/test", "https://release-assets.githubusercontent.com.evil.invalid/test",
                       "https://user:secret@release-assets.githubusercontent.com/test", "https://release-assets.githubusercontent.com:444/test",
                       "https://example.invalid/test", "file:///tmp/appcast.xml"] {
            let response = try #require(HTTPURLResponse(url: GitHubUpdates.assetURL(42), statusCode: 302, httpVersion: nil, headerFields: ["Location": target]))
            #expect(throws: UpdateFailure.self) { try GitHubUpdates.feedDownloadURL(from: response) }
        }
        let metadata = try #require(HTTPURLResponse(url: GitHubUpdates.assetURL(42), statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(throws: UpdateFailure.self) { try GitHubUpdates.feedDownloadURL(from: metadata) }
    }
    @Test func archiveCredentialsAreRestrictedToThisRepositoryAndNeverSentToFeedCDN() throws {
        for url in [GitHubUpdates.assetURL(42), try #require(URL(string: "https://release-assets.githubusercontent.com/test")),
                    try #require(URL(string: "https://api.github.com/repos/other/app/releases/assets/42"))] {
            let request = NSMutableURLRequest(url: url)
            request.setValue("Bearer previous", forHTTPHeaderField: "Authorization")
            GitHubUpdates.authorizeArchive(request, token: "non-credential-test-data")
            #expect(request.value(forHTTPHeaderField: "Authorization") == (url == GitHubUpdates.assetURL(42) ? "Bearer non-credential-test-data" : nil))
        }
    }
}

private final class ReleaseResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isAsset = request.url == GitHubUpdates.assetURL(42)
        #expect(isAsset || request.url == GitHubUpdates.releasesURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == (isAsset ? "application/octet-stream" : "application/vnd.github+json"))
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer non-credential-test-data"
        let data = Data(#"[{"draft":false,"prerelease":true,"tag_name":"v0.3.0","assets":[{"id":42,"name":"appcast.xml","state":"uploaded"}]}]"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: authenticated ? (isAsset ? 302 : 200) : 404, httpVersion: nil,
                                       headerFields: isAsset ? ["Location": "https://release-assets.githubusercontent.com/test/appcast.xml?signature=example"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PublicReleaseResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let isAsset = request.url == GitHubUpdates.assetURL(42)
        #expect(isAsset || request.url == GitHubUpdates.releasesURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == (isAsset ? "application/octet-stream" : "application/vnd.github+json"))
        let data = Data(#"[{"draft":false,"prerelease":false,"tag_name":"v0.7.1","assets":[{"id":42,"name":"appcast.xml","state":"uploaded"}]}]"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: isAsset ? 302 : 200, httpVersion: nil,
                                       headerFields: isAsset ? ["Location": "https://release-assets.githubusercontent.com/test/appcast.xml?signature=example"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
