import Foundation
import OpenDDCamKit

enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else { fatalError("missing fixture \(name)") }
        return data
    }

    static func response(_ name: String) -> CameraResponse {
        CameraResponse.parse(data(name))
    }
}

/// Scripted transport: the handler gets the request and its zero-based index.
final class FakeTransport: CameraTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [CameraRequest] = []
    private let handler: @Sendable (CameraRequest, Int) throws -> Data

    init(_ handler: @escaping @Sendable (CameraRequest, Int) throws -> Data) {
        self.handler = handler
    }

    var requests: [CameraRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var commands: [String] { requests.map(\.command) }

    func send(_ request: CameraRequest) async throws -> Data {
        let index: Int = {
            lock.lock()
            defer { lock.unlock() }
            log.append(request)
            return log.count - 1
        }()
        return try handler(request, index)
    }
}

let onCameraNetwork = NetworkGuard(host: "193.168.0.1") { _ in "193.168.0.23" }

func makeSession(_ transport: FakeTransport, guard netGuard: NetworkGuard = onCameraNetwork) -> CameraSession {
    CameraSession(transport: transport, networkGuard: netGuard, uid: "randomImeiTEST")
}

/// Answers the login commands and delegates everything else.
func loginAnswering(
    sessionID: String = "S1", other: @escaping @Sendable (CameraRequest, Int) throws -> Data
) -> @Sendable (CameraRequest, Int) throws -> Data {
    { request, index in
        switch request.command {
        case "API_RequestSessionID":
            return Data(#"{"errcode":0,"data":{"acSessionId":"\#(sessionID)"}}"#.utf8)
        case "API_RequestCertificate":
            return Fixture.data("ok_empty")
        default:
            return try other(request, index)
        }
    }
}

func json(_ data: Data?) -> JSONValue? {
    data.flatMap { JSONValue(data: $0) }
}
