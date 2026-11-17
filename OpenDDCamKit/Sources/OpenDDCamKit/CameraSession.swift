import Foundation

/// Logged-in conversation with the camera. Read-only: it never changes settings, the
/// clock, locks, recording or the memory card.
public actor CameraSession {
    private let transport: any CameraTransport
    private let networkGuard: NetworkGuard
    private let uid: String
    private let level: Int
    private let user: String
    private let password: String

    public private(set) var sessionID: String?
    private var loginTask: Task<String, any Error>?

    /// - Parameters:
    ///   - uid: Stable per-install identifier. The stock app uses a random string it generates once.
    ///   - level: 0 = interactive, 1 = background.
    public init(
        transport: any CameraTransport, networkGuard: NetworkGuard = NetworkGuard(),
        uid: String, level: Int = 0, user: String = "admin", password: String = "admin"
    ) {
        self.transport = transport
        self.networkGuard = networkGuard
        self.uid = uid
        self.level = level
        self.user = user
        self.password = password
    }

    // MARK: Login / logout

    /// Requests a session id and authenticates. Replaces any previous session.
    public func login() async throws {
        sessionID = nil
        _ = try await ensureLoggedIn(force: true)
    }

    /// Best effort: errors are ignored, the session is dropped either way.
    public func logout() async {
        guard let id = sessionID else { return }
        sessionID = nil
        loginTask = nil
        _ = try? await raw("API_Logout", body: nil, sessionID: id)
    }

    private func ensureLoggedIn(force: Bool = false) async throws -> String {
        if !force, let id = sessionID { return id }
        if let task = loginTask { return try await task.value }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        return try await task.value
    }

    private func performLogin() async throws -> String {
        let first = try await raw("API_RequestSessionID", body: nil, sessionID: "")
        guard let id = first.payload["acSessionId"]?.string, !id.isEmpty else {
            throw CameraError.invalidResponse
        }
        let body = JSONValue.object([
            "user": .string(user), "password": .string(password),
            "level": .number(Double(level)), "uid": .string(uid),
        ]).encoded()
        _ = try await raw("API_RequestCertificate", body: body, sessionID: id)
        sessionID = id
        return id
    }

    // MARK: Commands

    /// Sends a command; logs in first if needed and once more after a session error.
    @discardableResult
    public func send(_ command: String, body: JSONValue? = nil) async throws -> CameraResponse {
        try networkGuard.check()
        let encoded = body?.encoded()
        let used = try await ensureLoggedIn()
        do {
            return try await raw(command, body: encoded, sessionID: used)
        } catch let error as CameraError where error.isSessionError {
            if sessionID == used { sessionID = nil }
            let fresh = try await ensureLoggedIn()
            return try await raw(command, body: encoded, sessionID: fresh)
        }
    }

    private func raw(_ command: String, body: Data?, sessionID: String) async throws -> CameraResponse {
        try networkGuard.check()
        let data = try await transport.send(CameraRequest(command: command, body: body, sessionID: sessionID))
        let response = CameraResponse.parse(data)
        guard response.isJSON, response.root?.object != nil else { throw CameraError.invalidResponse }
        if let code = response.errcode, let error = CameraError(errcode: code) { throw error }
        return response
    }

    // MARK: Read-only queries

    public func baseInfo() async throws -> BaseInfo {
        BaseInfo(try await send("API_GetBaseInfo").payload)
    }

    public func storageInfo() async throws -> StorageInfo {
        StorageInfo(try await send("API_GetStorageInfo").payload)
    }

    /// Loop recordings. `rear` asks the rear camera.
    public func playbackList(rear: Bool = false) async throws -> PlaybackList {
        PlaybackList(try await send(rear ? "APP_PlaybackListReq_RearCam" : "APP_PlaybackListReq").payload)
    }

    public func eventList(rear: Bool = false) async throws -> [EventEntry] {
        EventEntry.list(try await send(rear ? "APP_EventListReq_RearCam" : "APP_EventListReq").payload)
    }

    /// Names of locked files.
    public func lockedList() async throws -> [String] {
        LockedFiles.names(try await send("APP_LockedListReq").payload)
    }

    public func generalQuery(keys: [String]) async throws -> GeneralQueryResult {
        let body = JSONValue.object([
            "keys": .array(keys.map { .object(["key": .string($0)]) })
        ])
        return GeneralQueryResult(try await send("API_GeneralQuery", body: body).payload)
    }

    /// Pending event messages from the camera's mailbox.
    public func mailbox() async throws -> [MailboxMessage] {
        MailboxMessage.list(try await send("API_GetMailboxData").payload)
    }
}
