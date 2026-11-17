import Foundation
import Testing

@testable import OpenDDCamKit

@Suite struct SessionHardeningTests {
    @Test(arguments: ["API_GeneralSave", "API_MmcFormat", "API_SetLockFile", "API_SyncDate", "API_RecordOpt"])
    func writeCommandsAreRejectedWithoutTraffic(command: String) async {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data("ok_empty") })
        let session = makeSession(t)
        await #expect(throws: CameraError.commandNotAllowed(command)) { _ = try await session.send(command) }
        #expect(t.requests.isEmpty)
    }

    @Test func logoutDuringLoginDiscardsTheNewSession() async throws {
        let certArrived = Gate()
        let certGate = Gate()
        let t = FakeTransport { req, _ in
            switch req.command {
            case "API_RequestSessionID": return sessionData("S1")
            case "API_RequestCertificate":
                await certArrived.release()
                await certGate.wait()
                return Fixture.data("ok_empty")
            default: return Fixture.data("ok_empty")
            }
        }
        let session = makeSession(t)
        let login = Task { try await session.login() }
        await certArrived.wait()
        await session.logout()
        await certGate.release()

        await #expect(throws: CameraError.loggedOut) { try await login.value }
        #expect(await session.sessionID == nil)
        #expect(t.commands.last == "API_Logout")
        #expect(t.requests.last?.sessionID == "S1")
        await #expect(throws: CameraError.loggedOut) { _ = try await session.storageInfo() }
    }

    @Test func inFlightSendDoesNotReloginAfterLogout() async throws {
        let arrived = Gate()
        let gate = Gate()
        let t = FakeTransport(
            loginAnswering { req, _ in
                if req.command == "API_GetStorageInfo" {
                    await arrived.release()
                    await gate.wait()
                    return Fixture.data("session_expired")
                }
                return Fixture.data("ok_empty")
            })
        let session = makeSession(t)
        try await session.login()
        let call = Task { try await session.storageInfo() }
        await arrived.wait()
        await session.logout()
        await gate.release()

        await #expect(throws: CameraError.loggedOut) { _ = try await call.value }
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 1)
    }

    @Test func forcedLoginJoiningAnInFlightLoginKeepsTheSession() async throws {
        let arrived = Gate()
        let gate = Gate()
        let t = FakeTransport { req, _ in
            switch req.command {
            case "API_RequestSessionID": return sessionData("S1")
            case "API_RequestCertificate":
                await arrived.release()
                await gate.wait()
                return Fixture.data("ok_empty")
            default: return Fixture.data("storage_info")
            }
        }
        let session = makeSession(t)
        let lazy = Task { try await session.storageInfo() }
        await arrived.wait()
        let forced = Task { try await session.login() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        _ = try await lazy.value
        try await forced.value

        #expect(await session.sessionID == "S1")
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 1)
    }

    @Test func loginAfterLogoutDuringLoginStartsFresh() async throws {
        let arrived = Gate()
        let gate = Gate()
        let sessions = LockedBox(0)
        let certs = LockedBox(0)
        let t = FakeTransport { req, _ in
            switch req.command {
            case "API_RequestSessionID":
                sessions.value += 1
                return sessionData("S\(sessions.value)")
            case "API_RequestCertificate":
                certs.value += 1
                if certs.value == 1 {
                    await arrived.release()
                    await gate.wait()
                }
                return Fixture.data("ok_empty")
            default: return Fixture.data("ok_empty")
            }
        }
        let session = makeSession(t)
        let a = Task { try await session.login() }
        await arrived.wait()
        await session.logout()
        let b = Task { try await session.login() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()

        await #expect(throws: CameraError.loggedOut) { try await a.value }
        try await b.value
        #expect(await session.sessionID == "S2")
        #expect(t.requests.contains { $0.command == "API_Logout" && $0.sessionID == "S1" })
    }

    @Test func twoCallsExpiringTogetherShareOneRelogin() async throws {
        let barrier = Barrier(count: 2)
        let sessions = LockedBox(0)
        let t = FakeTransport { req, _ in
            switch req.command {
            case "API_RequestSessionID":
                sessions.value += 1
                return sessionData("S\(sessions.value)")
            case "API_GetStorageInfo":
                if req.sessionID == "S1" {
                    await barrier.arrive()  // both calls are in flight before either expires
                    return Fixture.data("session_expired")
                }
                return Fixture.data("storage_info")
            default: return Fixture.data("ok_empty")
            }
        }
        let session = makeSession(t)
        try await session.login()
        async let a = session.storageInfo()
        async let b = session.storageInfo()
        let (x, y) = try await (a, b)
        #expect(x.normalRecordings == 120)
        #expect(y.normalRecordings == 120)
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 2)
        #expect(t.commands.filter { $0 == "API_GetStorageInfo" }.count == 4)
    }

    @Test func concurrentFirstCallsShareOneLogin() async throws {
        let arrived = Gate()
        let gate = Gate()
        let t = FakeTransport { req, _ in
            switch req.command {
            case "API_RequestSessionID":
                await arrived.release()
                await gate.wait()  // hold the login so every caller is waiting on it
                return sessionData("S1")
            case "API_GetStorageInfo": return Fixture.data("storage_info")
            default: return Fixture.data("ok_empty")
            }
        }
        let session = makeSession(t)
        let calls = (0..<5).map { _ in Task { try await session.storageInfo() } }
        await arrived.wait()
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()
        for c in calls { _ = try await c.value }
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 1)
        #expect(t.commands.filter { $0 == "API_RequestCertificate" }.count == 1)
    }

    @Test func certificateWithoutErrcodeFailsClosed() async {
        let t = FakeTransport { req, _ in
            req.command == "API_RequestSessionID" ? sessionData("S1") : Data("{}".utf8)
        }
        let session = makeSession(t)
        await #expect(throws: CameraError.invalidResponse) { try await session.login() }
        #expect(await session.sessionID == nil)
    }

    @Test func certificateWithGarbageErrcodeFailsClosed() async {
        let t = FakeTransport { req, _ in
            req.command == "API_RequestSessionID" ? sessionData("S1") : Data(#"{"errcode":"x"}"#.utf8)
        }
        await #expect(throws: CameraError.invalidResponse) { try await makeSession(t).login() }
    }

    @Test func sessionIDWithoutErrcodeFailsClosed() async {
        let t = FakeTransport { _, _ in Data(#"{"data":{"acSessionId":"S1"}}"#.utf8) }
        await #expect(throws: CameraError.invalidResponse) { try await makeSession(t).login() }
    }

    @Test func queriesStayTolerantOfMissingErrcode() async throws {
        let t = FakeTransport(
            loginAnswering { _, _ in Data(#"{"data":{"sdcapacity":5,"n_num":2}}"#.utf8) })
        let info = try await makeSession(t).storageInfo()
        #expect(info.normalRecordings == 2)
    }
}

@Suite struct FrameParserScaleTests {
    @Test func largeFrameInTcpSizedChunksParsesQuickly() {
        let payload = Data(repeating: 0x55, count: 8 * 1024 * 1024 - 8)
        var stream = Data([0x0A, 0x0B, 0x0C, 0x00])
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { stream.append(contentsOf: $0) }
        stream.append(payload)
        var parser = FrameParser(maxPayload: 16 * 1024 * 1024)
        var frames: [Frame] = []
        let clock = ContinuousClock()
        let start = clock.now
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 1460, stream.count)
            frames += parser.feed(stream[offset..<end])
            offset = end
            if clock.now - start > .seconds(3) { break }  // fail fast instead of crawling
        }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(1))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == payload)
        #expect(parser.resyncs == 0)
    }

    @Test func falseSyncIsResolvedWhenRealFramesTrickleIn() {
        var bogus = Data([0x0A, 0x0B, 0x0C, 0x00])
        bogus.append(contentsOf: [0, 0x01, 0x86, 0xA0])  // 100000, never completes
        var real = Data()
        var expected: [Data] = []
        for i in 0..<6 {
            let body = Data(repeating: UInt8(0x30 + i), count: 40)
            expected.append(body)
            real.append(contentsOf: [0x0A, 0x0B, 0x0C, 0x02, 0, 0, 0, 40])
            real.append(body)
        }
        var parser = FrameParser()
        var out: [Frame] = []
        let stream = bogus + real
        var i = 0
        while i < stream.count {
            out += parser.feed(stream[i..<min(i + 5, stream.count)])
            i += 5
        }
        #expect(out.map(\.payload) == expected)
        #expect(parser.resyncs == 1)
    }
}
