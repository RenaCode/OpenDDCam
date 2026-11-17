import Foundation

/// The camera's address (193.168.0.1) is a public internet address. Off the camera's own
/// Wi-Fi, requests, including the vendor-default login, would go to a stranger's host.
/// The guard therefore requires our source address towards the camera to be in the
/// camera's /24 before anything is sent.
public struct NetworkGuard: Sendable {
    public typealias SourceAddressProvider = @Sendable (_ host: String) -> String?

    public let host: String
    public let prefix: Int
    private let provider: SourceAddressProvider

    public init(
        host: String = "193.168.0.1", prefix: Int = 24,
        sourceAddress: @escaping SourceAddressProvider = NetworkGuard.systemSourceAddress
    ) {
        self.host = host
        self.prefix = prefix
        self.provider = sourceAddress
    }

    /// Throws `CameraError.notOnCameraNetwork` unless we are on the camera's subnet.
    public func check() throws {
        let source = provider(host)
        guard let source, Self.sameSubnet(source, host, prefix: prefix) else {
            throw CameraError.notOnCameraNetwork(source: source)
        }
    }

    /// True when both are IPv4 addresses inside the same `/prefix` network.
    public static func sameSubnet(_ a: String, _ b: String, prefix: Int = 24) -> Bool {
        guard (0...32).contains(prefix), let x = ipv4(a), let y = ipv4(b) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return (x & mask) == (y & mask)
    }

    private static func ipv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// Local address the OS would use to reach `host`. A UDP connect sends no packet.
    public static let systemSourceAddress: SourceAddressProvider = { host in
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
