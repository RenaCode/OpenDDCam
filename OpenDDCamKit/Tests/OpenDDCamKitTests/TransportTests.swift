import Foundation
import Testing

@testable import OpenDDCamKit

enum StubBehavior: Sendable {
    case respond(status: Int, headers: [String: String], body: Data)
    case redirect(URL)
    case hang
    case fail(URLError.Code)
}

/// URLProtocol stub: no network. Tests using it run serialized because the state is static.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let handler = LockedBox<(@Sendable (URLRequest) -> StubBehavior)?>(nil)
    static let seen = LockedBox<[URLRequest]>([])

    static func reset(_ h: @escaping @Sendable (URLRequest) -> StubBehavior) {
        seen.value = []
        handler.value = h
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.mutate { $0.append(request) }
        guard let handler = Self.handler.value, let url = request.url else { return }
        switch handler(request) {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // A real HTTP stack delivers the 302 itself when the delegate declines to follow it.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private func okBody(_ s: String = #"{"errcode":0}"#) -> StubBehavior {
    .respond(status: 200, headers: [:], body: Data(s.utf8))
}

private func makeTransport(
    guard g: NetworkGuard = onCameraNetwork, limit: Int = 1024, resourceTimeout: TimeInterval? = nil
) -> URLSessionCameraTransport {
    URLSessionCameraTransport(
        networkGuard: g, maxResponseBytes: limit, protocolClasses: [StubProtocol.self],
        resourceTimeoutOverride: resourceTimeout)
}

private let request = CameraRequest(command: "API_GetBaseInfo", body: nil, sessionID: "abc")

@Suite(.serialized) struct URLSessionTransportTests {
    @Test func returnsBodyAndSendsTheCameraRequest() async throws {
        StubProtocol.reset { _ in okBody(#"{"errcode":0,"data":{}}"#) }
        let data = try await makeTransport().send(request)
        #expect(String(decoding: data, as: UTF8.self) == #"{"errcode":0,"data":{}}"#)
        let seen = StubProtocol.seen.value
        #expect(seen.count == 1)
        #expect(seen[0].url?.absoluteString == "http://193.168.0.1/vcam/cmd.cgi?cmd=API_GetBaseInfo")
        #expect(seen[0].httpMethod == "POST")
        #expect(seen[0].value(forHTTPHeaderField: "sessionid") == "abc")
    }

    @Test func nonOKStatusIsReported() async {
        StubProtocol.reset { _ in .respond(status: 500, headers: [:], body: Data()) }
        await #expect(throws: CameraError.httpStatus(500)) { _ = try await makeTransport().send(request) }
    }

    @Test func bodyOverTheLimitIsRejected() async {
        StubProtocol.reset { _ in .respond(status: 200, headers: [:], body: Data(repeating: 0x41, count: 50)) }
        await #expect(throws: CameraError.responseTooLarge) { _ = try await makeTransport(limit: 10).send(request) }
    }

    @Test func declaredLengthOverTheLimitIsRejected() async {
        StubProtocol.reset { _ in
            .respond(status: 200, headers: ["Content-Length": "5000"], body: Data(repeating: 0x41, count: 5))
        }
        await #expect(throws: CameraError.responseTooLarge) { _ = try await makeTransport(limit: 100).send(request) }
    }

    @Test func bodyExactlyAtTheLimitIsAccepted() async throws {
        StubProtocol.reset { _ in .respond(status: 200, headers: [:], body: Data(repeating: 0x41, count: 10)) }
        let data = try await makeTransport(limit: 10).send(request)
        #expect(data.count == 10)
    }

    @Test func urlErrorsBecomeTransportErrors() async {
        StubProtocol.reset { _ in .fail(.notConnectedToInternet) }
        await #expect(throws: CameraError.transport("URLError -1009")) { _ = try await makeTransport().send(request) }
        StubProtocol.reset { _ in .fail(.timedOut) }
        await #expect(throws: CameraError.transport("URLError -1001")) { _ = try await makeTransport().send(request) }
    }

    @Test func cancellationBecomesCancellationError() async throws {
        StubProtocol.reset { _ in .hang }
        let transport = makeTransport()
        let task = Task { try await transport.send(request) }
        for _ in 0..<300 where StubProtocol.seen.value.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(StubProtocol.seen.value.count == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func redirectsAreNotFollowed() async {
        let elsewhere = URL(string: "http://203.0.113.9/steal")!
        StubProtocol.reset { _ in .redirect(elsewhere) }
        await #expect(throws: CameraError.httpStatus(302)) { _ = try await makeTransport().send(request) }
        #expect(StubProtocol.seen.value.map { $0.url?.host } == ["193.168.0.1"])
    }

    @Test func resourceDeadlineEndsAStalledRequest() async {
        StubProtocol.reset { _ in .hang }
        await #expect(throws: CameraError.transport("timeout")) {
            _ = try await makeTransport(resourceTimeout: 0.2).send(request)
        }
    }

    @Test func guardRefusalSendsNothing() async {
        StubProtocol.reset { _ in okBody() }
        let off = NetworkGuard(host: "193.168.0.1") { _ in "10.0.0.2" }
        await #expect(throws: CameraError.notOnCameraNetwork(source: "10.0.0.2")) {
            _ = try await makeTransport(guard: off).send(request)
        }
        #expect(StubProtocol.seen.value.isEmpty)
    }

    @Test func guardIsCheckedOnEverySend() async throws {
        StubProtocol.reset { _ in okBody() }
        let onNet = LockedBox(true)
        let g = NetworkGuard(host: "193.168.0.1") { _ in onNet.value ? "193.168.0.4" : nil }
        let transport = makeTransport(guard: g)
        _ = try await transport.send(request)
        onNet.value = false
        await #expect(throws: CameraError.notOnCameraNetwork(source: nil)) { _ = try await transport.send(request) }
        #expect(StubProtocol.seen.value.count == 1)
    }

    @Test func guardAndRequestUseTheSameHost() async throws {
        StubProtocol.reset { _ in okBody() }
        let checked = LockedBox<String?>(nil)
        let g = NetworkGuard(host: "10.9.8.7") { host in
            checked.value = host
            return "10.9.8.2"
        }
        let transport = makeTransport(guard: g)
        #expect(transport.host == "10.9.8.7")
        _ = try await transport.send(request)
        #expect(checked.value == "10.9.8.7")
        #expect(StubProtocol.seen.value.first?.url?.host == "10.9.8.7")
    }

    @Test func configurationDoesNotUseCellularOrExpensiveNetworks() {
        let c = URLSessionCameraTransport.makeConfiguration()
        #expect(c.allowsCellularAccess == false)
        #expect(c.allowsExpensiveNetworkAccess == false)
        #expect(c.allowsConstrainedNetworkAccess == false)
        #expect(c.timeoutIntervalForResource == 30)
        #expect(c.waitsForConnectivity == false)
    }

    @Test func eachRequestForbidsCellularAndExpensiveNetworks() throws {
        let u = try request.urlRequest(host: "193.168.0.1")
        #expect(u.allowsCellularAccess == false)
        #expect(u.allowsExpensiveNetworkAccess == false)
        #expect(u.allowsConstrainedNetworkAccess == false)
    }

    @Test func mailboxHasAShorterResourceDeadline() {
        let mailbox = CameraRequest(command: "API_GetMailboxData", body: nil, sessionID: "s")
        #expect(mailbox.resourceTimeout < request.resourceTimeout)
        #expect(request.resourceTimeout == 30)
    }
}

@Suite struct AllowlistTests {
    @Test func allowlistHasOnlyReadOnlyCommands() {
        let forbidden: Set<String> = [
            "API_GeneralSave", "API_MmcFormat", "API_MmcFormatSecondStorage", "API_SetLockFile", "API_SyncDate",
            "API_RecordOpt", "API_Reboot", "API_RestartWifi", "APP_DeleteEvent", "API_SuperDownload",
            "APP_PlaybackLiveSwitch", "API_AuthModify", "API_SetLogonInfo",
        ]
        #expect(CameraSession.allowedCommands.isDisjoint(with: forbidden))
        #expect(CameraSession.allowedCommands.contains("API_Logout"))
        #expect(CameraSession.allowedCommands.contains("API_GetBaseInfo"))
    }
}
