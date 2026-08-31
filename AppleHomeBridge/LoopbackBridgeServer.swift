import Darwin
import Foundation
import Security

struct BridgeDescriptor: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let host: String
    let port: Int
    let token: String
    let appVersion: String
    let pid: Int32
}

enum BridgeSecret {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apple Home Bridge", isDirectory: true)
            .appendingPathComponent("bridge-token", isDirectory: false)
    }

    static func loadOrCreate(at url: URL = defaultURL) throws -> String {
        do { return try read(at: url) }
        catch let error as POSIXError where error.code == .ENOENT {
            return try create(at: url)
        }
    }

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError("secret_failed", "could not generate the bridge authentication token")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func read(at url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0,
              (details.st_mode & S_IFMT) == S_IFREG,
              details.st_uid == getuid(),
              details.st_nlink == 1,
              details.st_mode & 0o777 == 0o600,
              details.st_size >= 32,
              details.st_size <= 512 else {
            throw BridgeError("secret_failed", "bridge token file must be owner-only mode 0600")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 512 else {
                throw BridgeError("secret_failed", "bridge token file is too large")
            }
        }
        guard let token = String(data: data, encoding: .utf8), 32...512 ~= token.utf8.count else {
            throw BridgeError("secret_failed", "bridge token file is invalid")
        }
        return token
    }

    private static func create(at url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let token = try generate()
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0, errno == EEXIST { return try read(at: url) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let data = Data(token.utf8)
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    written += count
                }
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            Darwin.close(fd)
            return token
        } catch {
            Darwin.close(fd)
            unlink(url.path)
            throw error
        }
    }
}

@MainActor
final class LoopbackBridgeServer {
    static var defaultDescriptorURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apple Home Bridge", isDirectory: true)
            .appendingPathComponent("bridge.json", isDirectory: false)
    }

    private let service: BridgeService
    private let token: String
    private let descriptorURL: URL
    private let acceptQueue = DispatchQueue(label: "com.henryvanness.apple-home-bridge.accept")
    private let clientQueue = DispatchQueue(
        label: "com.henryvanness.apple-home-bridge.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var descriptor: BridgeDescriptor?

    init(service: BridgeService, token: String, descriptorURL: URL? = nil) {
        self.service = service
        self.token = token
        self.descriptorURL = descriptorURL ?? Self.defaultDescriptorURL
    }

    func start() throws -> BridgeDescriptor {
        guard listener < 0 else {
            guard let descriptor else { throw BridgeError("internal_error", "bridge state is invalid") }
            return descriptor
        }

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw posixError("could not create loopback socket") }
        do {
            var enabled: Int32 = 1
            guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
                  setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw posixError("could not secure loopback socket")
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, Darwin.listen(socketFD, 16) == 0 else {
                throw posixError("could not bind Apple Home Bridge to 127.0.0.1")
            }
            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socketFD, $0, &boundLength)
                }
            }
            guard nameResult == 0 else { throw posixError("could not inspect loopback port") }
            _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL) | O_NONBLOCK)

            let descriptor = BridgeDescriptor(
                schemaVersion: BridgeService.schemaVersion,
                host: "127.0.0.1",
                port: Int(UInt16(bigEndian: boundAddress.sin_port)),
                token: token,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0",
                pid: getpid()
            )
            try writeDescriptor(descriptor)
            listener = socketFD
            self.descriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
            source.setCancelHandler { Darwin.close(socketFD) }
            self.source = source
            source.resume()
            return descriptor
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        listener = -1
        descriptor = nil
        try? FileManager.default.removeItem(at: descriptorURL)
    }

    private nonisolated func acceptAvailableConnections() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = self.listener
            let service = self.service
            let clientQueue = self.clientQueue
            clientQueue.async {
                while true {
                    let client = Darwin.accept(listener, nil, nil)
                    if client < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK { return }
                        return
                    }
                    clientQueue.async { Self.handle(client: client, service: service) }
                }
            }
        }
    }

    private nonisolated static func handle(client: Int32, service: BridgeService) {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        guard setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0,
        setsockopt(
            client,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0 else {
            Darwin.close(client)
            return
        }
        var noPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))

        let line = readRequestLine(client)
        Task { @MainActor in
            let response = await service.handle(line: line)
            Self.clientQueueWrite(response, to: client)
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
    }

    private nonisolated static func readRequestLine(_ client: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < BridgeService.maximumMessageBytes {
            let remaining = BridgeService.maximumMessageBytes - data.count
            let count = Darwin.recv(client, &buffer, min(buffer.count, remaining), 0)
            if count <= 0 { return Data() }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) {
                guard newline == data.index(before: data.endIndex) else { return Data() }
                return Data(data[..<newline])
            }
        }
        return Data()
    }

    private nonisolated static func clientQueueWrite(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    private func writeDescriptor(_ descriptor: BridgeDescriptor) throws {
        try FileManager.default.createDirectory(
            at: descriptorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var data = try JSONEncoder().encode(descriptor)
        data.append(0x0A)
        let temporaryURL = descriptorURL.deletingLastPathComponent()
            .appendingPathComponent(".bridge-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("could not create bridge descriptor") }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                    guard count > 0 else { throw posixError("could not write bridge descriptor") }
                    written += count
                }
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
                throw posixError("could not secure bridge descriptor")
            }
            guard rename(temporaryURL.path, descriptorURL.path) == 0 else {
                throw posixError("could not publish bridge descriptor")
            }
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            unlink(temporaryURL.path)
            throw error
        }
    }

    private func posixError(_ message: String) -> BridgeError {
        BridgeError("bridge_unavailable", "\(message): \(String(cString: strerror(errno)))")
    }
}
