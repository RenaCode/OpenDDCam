import Foundation
import Testing

@testable import OpenDDCamKit

@Suite struct CameraSessionTests {
    @Test func loginSequenceAndBodies() async throws {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data("ok_empty") })
        let session = makeSession(t)
        try await session.login()

        #expect(t.commands == ["API_RequestSessionID", "API_RequestCertificate"])
        #expect(t.requests[0].sessionID == "")
        #expect(t.requests[1].sessionID == "S1")
        let cert = json(t.requests[1].body)
        #expect(cert?["user"]?.string == "admin")
        #expect(cert?["password"]?.string == "admin")
        #expect(cert?["level"]?.int == 0)
        #expect(cert?["uid"]?.string == "randomImeiTEST")
        #expect(await session.sessionID == "S1")
    }

    @Test func firstCallLogsInLazilyAndSendsSessionHeader() async throws {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data("base_info") })
        let session = makeSession(t)
        let info = try await session.baseInfo()
        #expect(info.model == "VOLVO D317")
        #expect(t.commands == ["API_RequestSessionID", "API_RequestCertificate", "API_GetBaseInfo"])
        #expect(t.requests[2].sessionID == "S1")
    }

    @Test func secondCallDoesNotLoginAgain() async throws {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data("storage_info") })
        let session = makeSession(t)
        _ = try await session.storageInfo()
        _ = try await session.storageInfo()
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 1)
    }

    @Test func reloginsOnceAfterSessionExpiry() async throws {
        let counter = LockedBox(0)
        let t = FakeTransport(
            loginAnswering { req, _ in
                if req.command == "API_GetStorageInfo" {
                    counter.value += 1
                    return counter.value == 1 ? Fixture.data("session_expired") : Fixture.data("storage_info")
                }
                return Fixture.data("ok_empty")
            })
        let session = makeSession(t)
        let info = try await session.storageInfo()
        #expect(info.normalRecordings == 120)
        #expect(
            t.commands == [
                "API_RequestSessionID", "API_RequestCertificate", "API_GetStorageInfo",
                "API_RequestSessionID", "API_RequestCertificate", "API_GetStorageInfo",
            ])
    }

    @Test func doesNotLoopWhenExpiryPersists() async {
        let t = FakeTransport(
            loginAnswering { _, _ in Fixture.data("session_expired") })
        let session = makeSession(t)
        await #expect(throws: CameraError.sessionExpired(code: 1996488765)) {
            _ = try await session.storageInfo()
        }
        #expect(t.commands.filter { $0 == "API_GetStorageInfo" }.count == 2)
        #expect(t.commands.filter { $0 == "API_RequestSessionID" }.count == 2)
    }

    @Test func otherCameraErrorsAreNotRetried() async {
        let t = FakeTransport(
            loginAnswering { _, _ in Data(#"{"errcode":1996488797}"#.utf8) })
        let session = makeSession(t)
        await #expect(throws: CameraError.notAllowedWhileDriving) {
            _ = try await session.storageInfo()
        }
        #expect(t.commands.filter { $0 == "API_GetStorageInfo" }.count == 1)
    }

    @Test func loginRejectedSurfacesAndSessionStaysCleared() async {
        let t = FakeTransport { req, _ in
            if req.command == "API_RequestSessionID" { return Fixture.data("session") }
            return Data(#"{"errcode":1996488784}"#.utf8)
        }
        let session = makeSession(t)
        await #expect(throws: CameraError.loginRejected(code: 1996488784)) { try await session.login() }
        #expect(await session.sessionID == nil)
    }

    @Test func tooManyConnectionsOnLogin() async {
        let t = FakeTransport { _, _ in Data(#"{"errcode":1996488783}"#.utf8) }
        await #expect(throws: CameraError.tooManyConnections) { try await makeSession(t).login() }
    }

    @Test func missingSessionIDIsInvalidResponse() async {
        let t = FakeTransport { _, _ in Fixture.data("ok_empty") }
        await #expect(throws: CameraError.invalidResponse) { try await makeSession(t).login() }
    }

    @Test func nonJSONIsInvalidResponse() async {
        let t = FakeTransport(loginAnswering { _, _ in Data("<html/>".utf8) })
        await #expect(throws: CameraError.invalidResponse) { _ = try await makeSession(t).storageInfo() }
    }

    @Test func transportErrorsPropagate() async {
        let t = FakeTransport { _, _ in throw CameraError.httpStatus(500) }
        await #expect(throws: CameraError.httpStatus(500)) { try await makeSession(t).login() }
    }

    @Test func guardBlocksEverythingBeforeTransport() async {
        let off = NetworkGuard(host: "193.168.0.1") { _ in "10.1.1.1" }
        let t = FakeTransport(guard: off, loginAnswering { _, _ in Fixture.data("ok_empty") })
        let session = makeSession(t)
        await #expect(throws: CameraError.notOnCameraNetwork(source: "10.1.1.1")) { try await session.login() }
        await #expect(throws: CameraError.notOnCameraNetwork(source: "10.1.1.1")) { _ = try await session.baseInfo() }
        await session.logout()
        #expect(t.requests.isEmpty)
    }

    @Test func guardIsRecheckedOnEveryRequest() async throws {
        let onNet = LockedBox(true)
        let g = NetworkGuard(host: "193.168.0.1") { _ in onNet.value ? "193.168.0.9" : "172.16.0.1" }
        let t = FakeTransport(guard: g, loginAnswering { _, _ in Fixture.data("storage_info") })
        let session = makeSession(t)
        _ = try await session.storageInfo()
        let before = t.requests.count
        onNet.value = false
        await #expect(throws: CameraError.self) { _ = try await session.storageInfo() }
        #expect(t.requests.count == before)
    }

    @Test func logoutSendsCommandAndClearsSession() async throws {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data("ok_empty") })
        let session = makeSession(t)
        try await session.login()
        await session.logout()
        #expect(t.commands.last == "API_Logout")
        #expect(t.requests.last?.sessionID == "S1")
        #expect(await session.sessionID == nil)
    }

    @Test func logoutWithoutSessionSendsNothing() async {
        let t = FakeTransport { _, _ in Fixture.data("ok_empty") }
        await makeSession(t).logout()
        #expect(t.requests.isEmpty)
    }

    @Test func logoutSwallowsErrors() async throws {
        let t = FakeTransport(
            loginAnswering { req, _ in
                if req.command == "API_Logout" { throw CameraError.transport("down") }
                return Fixture.data("ok_empty")
            })
        let session = makeSession(t)
        try await session.login()
        await session.logout()
        #expect(await session.sessionID == nil)
    }
}

@Suite struct QueryTests {
    private func run<T: Sendable>(
        _ fixture: String, _ body: @Sendable (CameraSession) async throws -> T
    ) async throws -> (T, FakeTransport) {
        let t = FakeTransport(loginAnswering { _, _ in Fixture.data(fixture) })
        let result = try await body(makeSession(t))
        return (result, t)
    }

    @Test func playbackListFront() async throws {
        let (list, t) = try await run("playback_list") { try await $0.playbackList() }
        #expect(t.commands.last == "APP_PlaybackListReq")
        #expect(t.requests.last?.body == nil)
        #expect(list.count == 2)
        #expect(list.files.count == 2)
        #expect(list.files[0].name == "20261117101000_B.MP4")
    }

    @Test func playbackListRear() async throws {
        let (_, t) = try await run("playback_list") { try await $0.playbackList(rear: true) }
        #expect(t.commands.last == "APP_PlaybackListReq_RearCam")
    }

    @Test func eventListFrontAndRear() async throws {
        let (_, t1) = try await run("event_list") { try await $0.eventList() }
        #expect(t1.commands.last == "APP_EventListReq")
        let (_, t2) = try await run("event_list") { try await $0.eventList(rear: true) }
        #expect(t2.commands.last == "APP_EventListReq_RearCam")
    }

    @Test func lockedList() async throws {
        let (files, t) = try await run("locked_list") { try await $0.lockedList() }
        #expect(t.commands.last == "APP_LockedListReq")
        #expect(files == ["20261117101000_B.MP4"])
    }

    @Test func generalQueryBodyAndResult() async throws {
        let (result, t) = try await run("general_query") {
            try await $0.generalQuery(keys: ["mic_switch", "event_before_time"])
        }
        #expect(t.commands.last == "API_GeneralQuery")
        let body = json(t.requests.last?.body)
        #expect(body?["keys"]?.array?.compactMap { $0["key"]?.string } == ["mic_switch", "event_before_time"])
        #expect(result.string("mic_switch") == "on")
        #expect(result.int("event_before_time") == 10)
        #expect(result.int("gsensor_mode") == 3)
        #expect(result.string("missing") == nil)
    }

    @Test func mailbox() async throws {
        let (messages, t) = try await run("mailbox") { try await $0.mailbox() }
        #expect(t.commands.last == "API_GetMailboxData")
        #expect(messages.map(\.msgid) == ["MSG_PlaybackListUpdate", "MSG_CameraPreview", "MSG_PowerDown"])
        #expect(messages[0].data["action"]?.string == "add")
        #expect(messages[0].data["matchval"]?.int == 1)
        #expect(messages[1].data["cameraPreview"]?.string == "front")
        #expect(messages[2].data.isEmpty)
    }

    @Test func mailboxEmpty() async throws {
        let (messages, _) = try await run("ok_empty") { try await $0.mailbox() }
        #expect(messages.isEmpty)
    }
}
