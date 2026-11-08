import Foundation

final class HTTPRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // OAuth credentials and bearer requests must never be forwarded to a different origin.
        let original = task.originalRequest?.url
        let destination = request.url
        let allowed = destination?.scheme == "https" && destination?.host == original?.host && destination?.port == original?.port
        completionHandler(allowed ? request : nil)
    }
}

enum HTTPClient {
    static let shared = make()

    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 240
        return URLSession(configuration: configuration, delegate: HTTPRedirectPolicy(), delegateQueue: nil)
    }
}
