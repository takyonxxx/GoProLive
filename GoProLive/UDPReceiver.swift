import Foundation
import Darwin

/// Tek bir BSD UDP soketi: 8554 portunu dinler ve aynı soketten keep-alive gönderir.
final class UDPReceiver {
    private final class Token { var cancelled = false }

    private var fd: Int32 = -1
    private var token: Token?

    /// Alım thread'inde çağrılır. Buffer yalnızca çağrı süresince geçerlidir.
    var onDatagram: ((UnsafeRawBufferPointer) -> Void)?

    func start(port: UInt16) throws {
        stop()

        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvBuf: Int32 = 2 * 1024 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let e = errno
            close(s)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }

        let token = Token()
        self.token = token
        self.fd = s
        let handler = onDatagram

        let thread = Thread {
            let capacity = 65536
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
            defer {
                buffer.deallocate()
                close(s)
            }
            while !token.cancelled {
                let n = recv(s, buffer, capacity, 0)
                if n > 0 {
                    if token.cancelled { break }
                    handler?(UnsafeRawBufferPointer(start: buffer, count: n))
                } else if n < 0 {
                    let e = errno
                    if e != EAGAIN && e != EWOULDBLOCK && e != EINTR { break }
                }
            }
        }
        thread.name = "GoProUDPReceiver"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func send(_ bytes: [UInt8], host: String, port: UInt16) {
        let s = fd
        guard s >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }

        bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(s, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Soketi alım thread'i kapatır (en geç ~300 ms içinde).
    func stop() {
        token?.cancelled = true
        token = nil
        fd = -1
    }
}
