import Darwin
import Foundation
import XCTest
@testable import AppleHomeBridge

@MainActor
final class LoopbackBridgeServerTests: XCTestCase {
    func testPublishesMode0600DescriptorAndServesExactlyOneResponseLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHomeBridgeTests-\(UUID().uuidString)", isDirectory: true)
        let descriptorURL = directory.appendingPathComponent("bridge.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let token = "0123456789abcdef0123456789abcdef"
        let server = LoopbackBridgeServer(
            service: BridgeService(store: MockHomeStore(), token: token),
            token: token,
            descriptorURL: descriptorURL
        )
        let descriptor = try server.start()
        defer { server.stop() }

        XCTAssertEqual(descriptor.host, "127.0.0.1")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: descriptorURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        let request = try JSONEncoder().encode(BridgeRequest(
            schemaVersion: 1,
            token: token,
            operation: "status",
            arguments: [:]
        )) + Data([0x0A])
        let response = try await roundTrip(port: descriptor.port, request: request)
        XCTAssertEqual(response.last, 0x0A)
        XCTAssertEqual(response.filter { $0 == 0x0A }.count, 1)
        XCTAssertTrue(try JSONDecoder().decode(BridgeResponse.self, from: response.dropLast()).ok)
    }

    func testIncompleteRequestFrameFailsClosed() async throws {
        let descriptorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHomeBridgeTests-\(UUID().uuidString)/bridge.json")
        defer { try? FileManager.default.removeItem(at: descriptorURL.deletingLastPathComponent()) }
        let token = "0123456789abcdef0123456789abcdef"
        let server = LoopbackBridgeServer(
            service: BridgeService(store: MockHomeStore(), token: token),
            token: token,
            descriptorURL: descriptorURL
        )
        let descriptor = try server.start()
        defer { server.stop() }
        let response = try await roundTrip(port: descriptor.port, request: Data("{}".utf8))
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeResponse.self, from: response.dropLast()).error?.code,
            "invalid_request"
        )
    }

    func testSecretPersistsInOwnerOnlyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHomeBridgeSecretTests-\(UUID().uuidString)", isDirectory: true)
        let secretURL = directory.appendingPathComponent("bridge-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BridgeSecret.loadOrCreate(at: secretURL)
        let second = try BridgeSecret.loadOrCreate(at: secretURL)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.utf8.count, 32)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: secretURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testRequestBelowAndAtOneMiBIsAccepted() async throws {
        let descriptorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHomeBridgeTests-\(UUID().uuidString)/bridge.json")
        defer { try? FileManager.default.removeItem(at: descriptorURL.deletingLastPathComponent()) }
        let token = "0123456789abcdef0123456789abcdef"
        let server = LoopbackBridgeServer(
            service: BridgeService(store: MockHomeStore(), token: token),
            token: token,
            descriptorURL: descriptorURL
        )
        let descriptor = try server.start()
        defer { server.stop() }
        for size in [BridgeService.maximumMessageBytes - 1, BridgeService.maximumMessageBytes] {
            let response = try await roundTrip(
                port: descriptor.port,
                request: paddedStatusRequest(totalBytes: size)
            )
            XCTAssertTrue(try JSONDecoder().decode(BridgeResponse.self, from: response.dropLast()).ok)
        }
    }

    func testRequestOverOneMiBFailsClosedWhenPeerClosesDuringSend() async throws {
        let descriptorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHomeBridgeTests-\(UUID().uuidString)/bridge.json")
        defer { try? FileManager.default.removeItem(at: descriptorURL.deletingLastPathComponent()) }
        let token = "0123456789abcdef0123456789abcdef"
        let server = LoopbackBridgeServer(
            service: BridgeService(store: MockHomeStore(), token: token),
            token: token,
            descriptorURL: descriptorURL
        )
        let descriptor = try server.start()
        defer { server.stop() }
        let result = try await rejectedRoundTrip(
            port: descriptor.port,
            request: paddedStatusRequest(totalBytes: BridgeService.maximumMessageBytes + 1)
        )
        if result.response.last != 0x0A {
            XCTAssertTrue(result.peerClosedDuringSend)
        } else {
            XCTAssertEqual(
                try JSONDecoder().decode(BridgeResponse.self, from: result.response.dropLast()).error?.code,
                "invalid_request"
            )
        }
    }

    private func roundTrip(port: Int, request: Data) async throws -> Data {
        try await Task.detached {
            let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard client >= 0 else { throw POSIXError(.ENOTSOCK) }
            defer { Darwin.close(client) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
            try request.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                    guard count > 0 else { throw POSIXError(.EPIPE) }
                    sent += count
                }
            }
            Darwin.shutdown(client, SHUT_WR)
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.recv(client, &buffer, buffer.count, 0)
                if count == 0 { break }
                guard count > 0 else { throw POSIXError(.ECONNRESET) }
                response.append(contentsOf: buffer.prefix(count))
            }
            return response
        }.value
    }

    private func rejectedRoundTrip(
        port: Int,
        request: Data
    ) async throws -> (response: Data, peerClosedDuringSend: Bool) {
        try await Task.detached {
            let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard client >= 0 else { throw POSIXError(.ENOTSOCK) }
            defer { Darwin.close(client) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            }
            var peerClosedDuringSend = false
            try request.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                    if count < 0, errno == EPIPE || errno == ECONNRESET {
                        peerClosedDuringSend = true
                        return
                    }
                    guard count > 0 else { throw POSIXError(.EPIPE) }
                    sent += count
                }
            }
            Darwin.shutdown(client, SHUT_WR)
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.recv(client, &buffer, buffer.count, 0)
                if count == 0 { break }
                if count < 0, errno == ECONNRESET { break }
                guard count > 0 else { throw POSIXError(.ECONNRESET) }
                response.append(contentsOf: buffer.prefix(count))
            }
            return (response, peerClosedDuringSend)
        }.value
    }

    private func paddedStatusRequest(totalBytes: Int) -> Data {
        let token = "0123456789abcdef0123456789abcdef"
        var request = try! JSONEncoder().encode(BridgeRequest(
            schemaVersion: 1,
            token: token,
            operation: "status",
            arguments: [:]
        ))
        precondition(totalBytes > request.count)
        request.append(Data(repeating: 0x20, count: totalBytes - request.count - 1))
        request.append(0x0A)
        return request
    }
}
