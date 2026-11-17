import Foundation
import Testing

@testable import OpenDDCamKit

@Suite struct NetworkGuardTests {
    @Test(arguments: [
        ("193.168.0.23", "193.168.0.1", true),
        ("193.168.0.254", "193.168.0.1", true),
        ("193.168.1.23", "193.168.0.1", false),
        ("192.168.0.23", "193.168.0.1", false),
        ("10.0.0.5", "193.168.0.1", false),
        ("::1", "193.168.0.1", false),
        ("", "193.168.0.1", false),
        ("garbage", "193.168.0.1", false),
        ("193.168.0.23", "garbage", false),
        ("193.168.0.256", "193.168.0.1", false),
    ])
    func sameSubnet24(src: String, dst: String, expected: Bool) {
        #expect(NetworkGuard.sameSubnet(src, dst) == expected)
    }

    @Test func customPrefix() {
        #expect(NetworkGuard.sameSubnet("193.168.1.23", "193.168.0.1", prefix: 16))
        #expect(NetworkGuard.sameSubnet("193.168.1.23", "193.168.0.1", prefix: 24) == false)
        #expect(NetworkGuard.sameSubnet("1.2.3.4", "1.2.3.4", prefix: 32))
        #expect(NetworkGuard.sameSubnet("1.2.3.5", "1.2.3.4", prefix: 32) == false)
        #expect(NetworkGuard.sameSubnet("9.9.9.9", "1.2.3.4", prefix: 0))
        #expect(NetworkGuard.sameSubnet("1.2.3.4", "1.2.3.4", prefix: 33) == false)
    }

    @Test func checkPassesOnCameraNetwork() throws {
        try onCameraNetwork.check()
    }

    @Test func checkThrowsOnOtherNetwork() {
        let g = NetworkGuard(host: "193.168.0.1") { _ in "192.168.1.20" }
        #expect(throws: CameraError.notOnCameraNetwork(source: "192.168.1.20")) { try g.check() }
    }

    @Test func checkThrowsWhenSourceUnknown() {
        let g = NetworkGuard(host: "193.168.0.1") { _ in nil }
        #expect(throws: CameraError.notOnCameraNetwork(source: nil)) { try g.check() }
    }

    @Test func providerReceivesTheCameraHost() throws {
        let seen = LockedBox<String?>(nil)
        let g = NetworkGuard(host: "193.168.0.1") { host in
            seen.value = host
            return "193.168.0.5"
        }
        try g.check()
        #expect(seen.value == "193.168.0.1")
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }

    func mutate(_ change: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@Suite struct RequestTests {
    @Test func buildsURLAndHeaders() throws {
        let req = CameraRequest(command: "API_GetBaseInfo", body: nil, sessionID: "abc")
        let url = try req.urlRequest(host: "193.168.0.1")
        #expect(url.url?.absoluteString == "http://193.168.0.1/vcam/cmd.cgi?cmd=API_GetBaseInfo")
        #expect(url.httpMethod == "POST")
        #expect(url.value(forHTTPHeaderField: "sessionid") == "abc")
        #expect(url.value(forHTTPHeaderField: "Cookie") == "SessionID=abc")
        #expect(url.value(forHTTPHeaderField: "Connection") == "close")
        #expect(url.timeoutInterval == 10)
        #expect(url.httpBody == nil)
    }

    @Test func bodyIsAttached() throws {
        let body = Data(#"{"a":1}"#.utf8)
        let req = CameraRequest(command: "API_GeneralQuery", body: body, sessionID: "s")
        #expect(try req.urlRequest(host: "193.168.0.1").httpBody == body)
    }

    @Test func mailboxTimeoutIsFiveSeconds() throws {
        let req = CameraRequest(command: "API_GetMailboxData", body: nil, sessionID: "s")
        #expect(try req.urlRequest(host: "193.168.0.1").timeoutInterval == 5)
    }

    @Test func emptySessionSendsEmptyHeaders() throws {
        let req = CameraRequest(command: "API_RequestSessionID", body: nil, sessionID: "")
        let url = try req.urlRequest(host: "193.168.0.1")
        #expect(url.value(forHTTPHeaderField: "sessionid") == "")
        #expect(url.value(forHTTPHeaderField: "Cookie") == "SessionID=")
    }

    @Test func commandIsPercentEncoded() throws {
        let req = CameraRequest(command: "A&B=C", body: nil, sessionID: "")
        let s = try req.urlRequest(host: "193.168.0.1").url?.absoluteString
        #expect(s == "http://193.168.0.1/vcam/cmd.cgi?cmd=A%26B%3DC")
    }

    @Test func rejectsHostWithPathOrWhitespace() {
        let req = CameraRequest(command: "X", body: nil, sessionID: "")
        #expect(throws: CameraError.self) { try req.urlRequest(host: "evil.example/x ") }
    }
}

@Suite struct ResponseLimitTests {
    @Test func acceptsUpToLimit() throws {
        var acc = ResponseAccumulator(limit: 4)
        try acc.append(Data([1, 2]))
        try acc.append(Data([3, 4]))
        #expect(acc.data == Data([1, 2, 3, 4]))
    }

    @Test func throwsWhenExceeded() {
        var acc = ResponseAccumulator(limit: 3)
        #expect(throws: CameraError.responseTooLarge) { try acc.append(Data([1, 2, 3, 4])) }
    }

    @Test func throwsWhenDeclaredLengthExceeds() {
        #expect(throws: CameraError.responseTooLarge) {
            try ResponseAccumulator(limit: 10).checkDeclared(length: 11)
        }
        #expect(throws: Never.self) { try ResponseAccumulator(limit: 10).checkDeclared(length: -1) }
    }
}
