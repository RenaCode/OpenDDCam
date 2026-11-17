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

    /// 10 s, except 5 s for the mailbox poll.
    public var timeout: TimeInterval { command == "API_GetMailboxData" ? 5 : 10 }

    public func urlRequest(host: String) throws -> URLRequest {
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
        request.httpBody = body
        return request
    }
}

/// Sends commands to the camera and returns the raw response body.
public protocol CameraTransport: Sendable {
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

/// `CameraTransport` over URLSession. Plain HTTP: an app must allow it for the camera's
/// address (App Transport Security).
public struct URLSessionCameraTransport: CameraTransport {
    public let host: String
    public let maxResponseBytes: Int
    private let session: URLSession

    public init(host: String = "193.168.0.1", maxResponseBytes: Int = 8 * 1024 * 1024, session: URLSession? = nil) {
        self.host = host
        self.maxResponseBytes = maxResponseBytes
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: CameraRequest) async throws -> Data {
        let urlRequest = try request.urlRequest(host: host)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
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
        } catch {
            throw CameraError.transport(String(describing: (error as? URLError)?.code.rawValue ?? -1))
        }
    }
}
