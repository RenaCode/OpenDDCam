import Foundation

/// Errors reported by the camera (`errcode`) and local client failures.
public enum CameraError: Error, Equatable, Sendable {
    /// Session expired, taken over by another client, or invalid (1996488765/70/73).
    case sessionExpired(code: Int)
    /// The camera has too many clients logged in (1996488783).
    case tooManyConnections
    /// The camera refused the login (1996488784/89).
    case loginRejected(code: Int)
    /// Operation not allowed right now, for example downloading while driving (1996488797).
    case notAllowedWhileDriving
    /// Any other non-zero `errcode`.
    case camera(code: Int)

    /// The HTTP status was not 200.
    case httpStatus(Int)
    /// The response was not JSON or lacked a required field.
    case invalidResponse
    /// The response exceeded the size limit.
    case responseTooLarge
    /// Network-level failure (description only, so the error stays `Equatable`).
    case transport(String)
    /// `logout()` was called; nothing is sent until `login()` is called again.
    case loggedOut
    /// The command is not on the read-only allowlist. Nothing was sent.
    case commandNotAllowed(String)
    /// Our own address towards the camera is not in the camera's subnet. Nothing was sent.
    case notOnCameraNetwork(source: String?)

    /// Maps a camera `errcode`; `nil` for 0 (success).
    public init?(errcode: Int) {
        switch errcode {
        case 0: return nil
        case 1_996_488_765, 1_996_488_770, 1_996_488_773: self = .sessionExpired(code: errcode)
        case 1_996_488_783: self = .tooManyConnections
        case 1_996_488_784, 1_996_488_789: self = .loginRejected(code: errcode)
        case 1_996_488_797: self = .notAllowedWhileDriving
        default: self = .camera(code: errcode)
        }
    }

    /// True when logging in again may fix the error.
    public var isSessionError: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}
