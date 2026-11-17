import Foundation

/// Logged-in conversation with the camera. Read-only: it never changes settings, the
/// clock, locks, recording or the memory card.
public actor CameraSession {
    /// The only commands `send` accepts: the read-only queries of this kit and `API_Logout`.
    /// Anything else, for example settings, format, lock, clock or recording commands, is
    /// refused before any network traffic.
    public static let allowedCommands: Set<String> = [
        "API_GetBaseInfo", "API_GetStorageInfo",
        "APP_PlaybackListReq", "APP_PlaybackListReq_RearCam",
        "APP_EventListReq", "APP_EventListReq_RearCam",
        "APP_LockedListReq", "API_GeneralQuery", "API_GetMailboxData",
        "API_Logout",
    ]

    private enum State {
        case idle
        case loggedIn(String)
        /// After `logout()`: nothing is sent until `login()` is called again.
        case loggedOut
    }

    private let transport: any CameraTransport
    private let uid: String
    private let level: Int
    private let user: String
    private let password: String

    private var state = State.idle
    /// Bumped by `logout()`; a login that started in an older generation is discarded.
    private var generation = 0
    private var nextLoginID = 0
    private var loginTask: (id: Int, generation: Int, task: Task<String, any Error>)?

    public var sessionID: String? {
        if case .loggedIn(let id) = state { return id }
        return nil
    }

    /// - Parameters:
    ///   - uid: Stable per-install identifier. The stock app uses a random string it generates once.
    ///   - level: 0 = interactive, 1 = background.
    public init(
        transport: any CameraTransport,
        uid: String, level: Int = 0, user: String = "admin", password: String = "admin"
    ) {
        self.transport = transport
        self.uid = uid
        self.level = level
        self.user = user
        self.password = password
    }

    // MARK: Login / logout

    /// Requests a session id and authenticates. Clears a `logout()` state. Joins a login that
    /// is already running, otherwise starts a new one.
    public func login() async throws {
        if case .loggedOut = state { state = .idle }
        _ = try await ensureLoggedIn(force: true)
    }

    /// Durable: a login still running finishes without storing its session and logs that
    /// session out; a request in flight does not log in again. Errors are ignored.
    public func logout() async {
        generation += 1
        let old = sessionID
        state = .loggedOut
        if let id = old { await bestEffortLogout(id) }
    }

    private func bestEffortLogout(_ id: String) async {
        _ = try? await raw("API_Logout", body: nil, sessionID: id)
    }

    /// Callers share one login task. Cancelling a caller does not cancel that task: it is
    /// bounded by the transport timeouts (10 s per request), so a waiter is never stuck.
    private func ensureLoggedIn(force: Bool = false) async throws -> String {
        while true {
            if case .loggedOut = state { throw CameraError.loggedOut }
            if !force, case .loggedIn(let id) = state { return id }
            if let current = loginTask {
                if current.generation == generation { return try await current.task.value }
                // Left over from before a logout: let it finish, then start a fresh one.
                _ = try? await current.task.value
                continue
            }
            nextLoginID += 1
            let id = nextLoginID
            let gen = generation
            let task = Task { try await self.runLogin(id: id, generation: gen) }
            loginTask = (id, gen, task)
            return try await task.value
        }
    }

    private func runLogin(id: Int, generation gen: Int) async throws -> String {
        defer { if loginTask?.id == id { loginTask = nil } }
        do {
            let first = try await raw("API_RequestSessionID", body: nil, sessionID: "", requireOK: true)
            guard let sid = first.payload["acSessionId"]?.string, !sid.isEmpty else {
                throw CameraError.invalidResponse
            }
            if generation != gen {
                await bestEffortLogout(sid)
                throw CameraError.loggedOut
            }
            let body = JSONValue.object([
                "user": .string(user), "password": .string(password),
                "level": .number(Double(level)), "uid": .string(uid),
            ]).encoded()
            _ = try await raw("API_RequestCertificate", body: body, sessionID: sid, requireOK: true)
            if generation != gen {
                await bestEffortLogout(sid)
                throw CameraError.loggedOut
            }
            state = .loggedIn(sid)
            return sid
        } catch {
            if generation == gen, case .loggedIn = state { state = .idle }
            throw error
        }
    }

    // MARK: Commands

    /// Sends an allowlisted command; logs in first if needed and once more after a session error.
    @discardableResult
    public func send(_ command: String, body: JSONValue? = nil) async throws -> CameraResponse {
        guard Self.allowedCommands.contains(command) else { throw CameraError.commandNotAllowed(command) }
        try transport.networkGuard.check()
        let encoded = body?.encoded()
        let used = try await ensureLoggedIn()
        do {
            return try await raw(command, body: encoded, sessionID: used)
        } catch let error as CameraError where error.isSessionError {
            if case .loggedOut = state { throw CameraError.loggedOut }
            if case .loggedIn(let current) = state, current == used { state = .idle }
            let fresh = try await ensureLoggedIn()
            return try await raw(command, body: encoded, sessionID: fresh)
        }
    }

    /// `requireOK`: the reply must carry `errcode` 0 (logins fail closed); queries stay tolerant.
    private func raw(
        _ command: String, body: Data?, sessionID: String, requireOK: Bool = false
    ) async throws -> CameraResponse {
        try transport.networkGuard.check()
        let data = try await transport.send(CameraRequest(command: command, body: body, sessionID: sessionID))
        let response = CameraResponse.parse(data)
        guard response.isJSON, response.root?.object != nil else { throw CameraError.invalidResponse }
        if requireOK, response.errcode == nil { throw CameraError.invalidResponse }
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
