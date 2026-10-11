import Darwin

/// Sends TUIO frames over UDP to apps on this Mac (127.0.0.1, port 3333, TUIO's default). Nothing listens?
/// The datagrams are simply dropped.
final class TUIOSender {
    static let port: UInt16 = 3333
    private let socket: Int32
    private let address: sockaddr_in

    init(port: UInt16 = TUIOSender.port) {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        address = a
    }

    deinit {
        if socket >= 0 { close(socket) }
    }

    func send(_ bytes: [UInt8]) {
        guard socket >= 0 else { return }
        var target = address
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(socket, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
