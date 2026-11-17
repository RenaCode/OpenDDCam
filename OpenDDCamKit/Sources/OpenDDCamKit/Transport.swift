import Foundation

/// One camera command.
public struct CameraRequest: Sendable, Equatable {
    public var command: String
    public var body: Data?
    /// Session id for the `sessionid` and `Cookie` headers; empty before login.
    public var sessionID: String

    public init(command: String, body: Data?, sessionID: String) {
        self.command = command
        self.body = body
        self.sessionID = sessionID
    }

    /// Idle timeout: 10 s, except 5 s for the mailbox poll.
    public var timeout: TimeInterval { command == "API_GetMailboxData" ? 5 : 10 }

    /// Total time allowed for the whole exchange: 30 s, except 10 s for the mailbox poll.
    public var resourceTimeout: TimeInterval { command == "API_GetMailboxData" ? 10 : 30 }

    func urlRequest(host: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/vcam/cmd.cgi"
        // Percent-encode everything but unreserved characters, so '&' and '=' cannot leak in.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        components.percentEncodedQuery = "cmd=" + encoded
        guard let url = components.url, url.host == host else {
            throw CameraError.transport("invalid camera address")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(sessionID, forHTTPHeaderField: "sessionid")
        request.setValue("SessionID=" + sessionID, forHTTPHeaderField: "Cookie")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = false
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        request.httpBody = body
        return request
    }
}

/// Sends commands to the camera and returns the raw response body.
///
/// A transport owns the camera address and its `NetworkGuard`. There is one host, taken
/// from the guard, so the address that is checked is the address that is contacted.
public protocol CameraTransport: Sendable {
    var networkGuard: NetworkGuard { get }
    func send(_ request: CameraRequest) async throws -> Data
}

/// Collects a response body while enforcing a size limit.
struct ResponseAccumulator {
    let limit: Int
    private(set) var data = Data()

    init(limit: Int) { self.limit = limit }

    func checkDeclared(length: Int64) throws {
        if length > Int64(limit) { throw CameraError.responseTooLarge }
    }

    mutating func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= limit else { throw CameraError.responseTooLarge }
        data.append(chunk)
    }
}

/// Redirects are never followed: a camera has no reason to send us elsewhere.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// `CameraTransport` over URLSession. Plain HTTP: an app must allow it for the camera's
/// address (App Transport Security).
///
/// Every send first runs the `NetworkGuard`. The session refuses cellular, expensive and
/// constrained networks, but URLSession cannot pin the connection to Wi-Fi, so a path
/// change between the check and the send remains a small residual window; the guard runs
/// again before every request.
public struct URLSessionCameraTransport: CameraTransport {
    public let networkGuard: NetworkGuard
    public let maxResponseBytes: Int
    private let session: URLSession
    private let resourceTimeoutOverride: TimeInterval?

    public var host: String { networkGuard.host }

    public init(networkGuard: NetworkGuard = NetworkGuard(), maxResponseBytes: Int = 8 * 1024 * 1024) {
        self.init(
            networkGuard: networkGuard, maxResponseBytes: maxResponseBytes, protocolClasses: nil,
            resourceTimeoutOverride: nil)
    }

    init(
        networkGuard: NetworkGuard, maxResponseBytes: Int, protocolClasses: [AnyClass]?,
        resourceTimeoutOverride: TimeInterval?
    ) {
        self.networkGuard = networkGuard
        self.maxResponseBytes = maxResponseBytes
        self.resourceTimeoutOverride = resourceTimeoutOverride
        let config = Self.makeConfiguration()
        if let protocolClasses { config.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: config)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return config
    }

    public func send(_ request: CameraRequest) async throws -> Data {
        try networkGuard.check()
        let urlRequest = try request.urlRequest(host: networkGuard.host)
        let deadline = resourceTimeoutOverride ?? request.resourceTimeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.fetch(urlRequest) }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw CameraError.transport("timeout")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CameraError.invalidResponse }
            return first
        }
    }

    private func fetch(_ urlRequest: URLRequest) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else { throw CameraError.invalidResponse }
            guard http.statusCode == 200 else { throw CameraError.httpStatus(http.statusCode) }
            var acc = ResponseAccumulator(limit: maxResponseBytes)
            try acc.checkDeclared(length: http.expectedContentLength)
            var chunk = Data()
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 16 * 1024 {
                    try acc.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try acc.append(chunk)
            return acc.data
        } catch let error as CameraError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw CameraError.transport("URLError \(error.code.rawValue)")
        } catch {
            throw CameraError.transport("error")
        }
    }
}
