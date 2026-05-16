import Foundation
import Network
import Combine
import Darwin

enum HookIPCTransport: Equatable {
    case tcp(port: UInt16)
    case unix(path: String)
}

class HookSocketServer {
    private var listener: NWListener?
    private let maxPayloadSize = 1_048_576
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "DevIsland.HookSocketServer.connections")
    private let unixQueue = DispatchQueue(label: "DevIsland.HookSocketServer.unix")
    private let unixClientTimeoutSeconds = 300
    private var unixListenFD: Int32 = -1
    private var unixAcceptSource: DispatchSourceRead?

    /// Called when a complete message is received.
    /// - Parameters:
    ///   - message: Raw JSON string (raw mode) or envelope JSON string (framed mode).
    ///   - requestId: UUID from the IPC envelope, or nil for raw JSON requests.
    ///   - responseHandler: Call with the response string. The server automatically
    ///     frames the response if the request was framed.
    var onMessageReceived: ((String, String?, @escaping (String) -> Void) -> Void)?
    var onServerFailed: (() -> Void)?

    deinit {
        stopUnixListener()
    }

    func start(transport: HookIPCTransport = .tcp(port: 9090)) {
        switch transport {
        case .tcp(let port):
            startTCP(port: NWEndpoint.Port(rawValue: port) ?? 9090)
        case .unix(let path):
            startUnix(path: path)
        }
    }

    private func startTCP(port: NWEndpoint.Port) {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: port)

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Server listening on port \(port)")
                case .failed(let error):
                    print("Server failed: \(error)")
                    DispatchQueue.main.async { self.onServerFailed?() }
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .global())
        } catch {
            print("Failed to start server: \(error)")
            // TODO: Call onServerFailed() here to avoid silent failure when port is occupied
            // or other initialization errors occur.
        }
    }

    private func startUnix(path: String) {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try removeStaleSocket(at: url)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

            var flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                flags = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { buffer in
                    for (index, byte) in pathBytes.enumerated() {
                        buffer[index] = CChar(bitPattern: byte)
                    }
                    buffer[pathBytes.count] = 0
                }
            }

            let previousUmask = umask(mode_t(S_IRWXG | S_IRWXO))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let bindErrno = errno
            umask(previousUmask)
            guard bindResult == 0 else {
                let error = POSIXError(.init(rawValue: bindErrno) ?? .EIO)
                close(fd)
                throw error
            }
            chmod(path, S_IRUSR | S_IWUSR)
            guard listen(fd, SOMAXCONN) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }

            unixListenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: unixQueue)
            source.setEventHandler { [weak self] in
                self?.acceptUnixConnections()
            }
            source.setCancelHandler {
                close(fd)
            }
            unixAcceptSource = source
            source.resume()
            print("Server listening on Unix socket \(path)")
        } catch {
            print("Failed to start Unix socket server: \(error)")
            DispatchQueue.main.async { self.onServerFailed?() }
        }
    }

    private func removeStaleSocket(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFSOCK else {
            throw POSIXError(.EEXIST)
        }
        try FileManager.default.removeItem(at: url)
    }

    private func stopUnixListener() {
        unixAcceptSource?.cancel()
        unixAcceptSource = nil
        unixListenFD = -1
    }

    private func acceptUnixConnections() {
        while true {
            let clientFD = accept(unixListenFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                print("Unix accept failed: \(errno)")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleUnixClient(clientFD)
            }
        }
    }

    private func handleUnixClient(_ fd: Int32) {
        configureUnixClient(fd)
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let readCount = recv(fd, &buffer, buffer.count, 0)
            if readCount > 0 {
                payload.append(buffer, count: readCount)
                if payload.count > maxPayloadSize {
                    close(fd)
                    return
                }
            } else if readCount == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                close(fd)
                return
            }
        }

        guard !payload.isEmpty else {
            close(fd)
            return
        }

        // 0x7B == "{": raw JSON from legacy clients without length-prefixed framing.
        if payload.first == 0x7B {
            deliverUnixPayload(payload, framed: false, fd: fd)
        } else {
            guard payload.count >= 4 else {
                close(fd)
                return
            }
            let length = payload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length <= maxPayloadSize, payload.count >= Int(4 + length) else {
                close(fd)
                return
            }
            deliverUnixPayload(payload.dropFirst(4).prefix(Int(length)), framed: true, fd: fd)
        }
    }

    private func configureUnixClient(_ fd: Int32) {
        var timeout = timeval(tv_sec: unixClientTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private func deliverUnixPayload(_ data: Data, framed: Bool, fd: Int32) {
        guard let message = String(data: data, encoding: .utf8) else {
            close(fd)
            return
        }
        let requestId = framed ? extractRequestId(from: data) : nil
        DispatchQueue.main.async { [weak self] in
            let responseQueue = self?.unixQueue ?? DispatchQueue.global(qos: .userInitiated)
            guard let onMessageReceived = self?.onMessageReceived else {
                responseQueue.async { close(fd) }
                return
            }
            onMessageReceived(message, requestId) { response in
                let responseData = Self.unixResponseData(response, framed: framed)
                responseQueue.async {
                    Self.sendAll(responseData, to: fd)
                    close(fd)
                }
            }
        }
    }

    private static func unixResponseData(_ response: String, framed: Bool) -> Data {
        guard framed else { return Data(response.utf8) }
        let responseBytes = Data(response.utf8)
        let length = UInt32(responseBytes.count).bigEndian
        var framedResponse = withUnsafeBytes(of: length) { Data($0) }
        framedResponse.append(responseBytes)
        return framedResponse
    }

    private static func sendAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = send(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    let err = String(cString: strerror(errno))
                    NSLog("[HookSocketServer] sendAll failed on fd %d: %@ (errno %d)", fd, err, errno)
                    return
                }
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = UUID()
        connectionQueue.sync {
            activeConnections[id] = connection
        }
        connection.start(queue: .global())
        // Peek at the first byte to determine framing mode before reading the full payload.
        peekFramingMode(on: connection, id: id)
    }

    private func closeConnection(id: UUID, connection: NWConnection) {
        connection.cancel()
        connectionQueue.async {
            self.activeConnections.removeValue(forKey: id)
        }
    }

    // MARK: - Framing detection

    /// Reads exactly 1 byte to distinguish raw JSON (0x7B = '{') from length-prefixed framing.
    private func peekFramingMode(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                self?.closeConnection(id: id, connection: connection)
                return
            }
            if data[0] == 0x7B {
                // Raw JSON: accumulate the rest until EOF.
                self.receiveRawJSON(on: connection, id: id, accumulated: data)
            } else {
                // Length-prefixed framing: we already have the first byte of the 4-byte header.
                self.receiveFramedHeader(on: connection, id: id, headerSoFar: data)
            }
        }
    }

    // MARK: - Raw JSON path (backward-compatible)

    private func receiveRawJSON(on connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            var payload = accumulated
            if let data { payload.append(data) }

            if payload.count > (self?.maxPayloadSize ?? 0) {
                print("Payload exceeds size limit")
                self?.closeConnection(id: id, connection: connection)
                return
            }

            if isComplete, let message = String(data: payload, encoding: .utf8) {
                print("Received raw JSON: \(message)")
                DispatchQueue.main.async {
                    self?.onMessageReceived?(message, nil) { response in
                        // Raw request → raw response, no framing.
                        let responseData = Data(response.utf8)
                        connection.send(content: responseData, completion: .contentProcessed({ _ in
                            self?.closeConnection(id: id, connection: connection)
                        }))
                    }
                }
            } else if isComplete || error != nil {
                self?.closeConnection(id: id, connection: connection)
            } else {
                self?.receiveRawJSON(on: connection, id: id, accumulated: payload)
            }
        }
    }

    // MARK: - Length-prefixed framing path

    /// Collects the remaining bytes of the 4-byte big-endian length header.
    private func receiveFramedHeader(on connection: NWConnection, id: UUID, headerSoFar: Data) {
        let remaining = 4 - headerSoFar.count
        if remaining == 0 {
            let length = headerSoFar.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            receiveFramedBody(on: connection, id: id, expectedLength: Int(length), accumulated: Data())
            return
        }
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                self?.closeConnection(id: id, connection: connection)
                return
            }
            var header = headerSoFar
            header.append(data)
            self?.receiveFramedHeader(on: connection, id: id, headerSoFar: header)
        }
    }

    private func receiveFramedBody(on connection: NWConnection, id: UUID, expectedLength: Int, accumulated: Data) {
        guard expectedLength <= maxPayloadSize else {
            print("Framed payload length \(expectedLength) exceeds limit")
            closeConnection(id: id, connection: connection)
            return
        }
        let needed = expectedLength - accumulated.count
        if needed == 0 {
            deliverFramedPayload(accumulated, on: connection, id: id)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self] data, _, isComplete, error in
            var body = accumulated
            if let data { body.append(data) }
            if body.count >= expectedLength {
                self?.deliverFramedPayload(body, on: connection, id: id)
            } else if isComplete || error != nil {
                self?.closeConnection(id: id, connection: connection)
            } else {
                self?.receiveFramedBody(on: connection, id: id, expectedLength: expectedLength, accumulated: body)
            }
        }
    }

    private func deliverFramedPayload(_ data: Data, on connection: NWConnection, id: UUID) {
        guard let message = String(data: data, encoding: .utf8) else {
            closeConnection(id: id, connection: connection)
            return
        }
        print("Received framed message: \(message)")

        // Extract requestId for rich response construction.
        let requestId = extractRequestId(from: data)

        DispatchQueue.main.async { [weak self] in
            self?.onMessageReceived?(message, requestId) { response in
                // Framed request → length-prefixed response.
                let responseBytes = Data(response.utf8)
                let length = UInt32(responseBytes.count).bigEndian
                var framed = withUnsafeBytes(of: length) { Data($0) }
                framed.append(responseBytes)
                connection.send(content: framed, completion: .contentProcessed({ _ in
                    self?.closeConnection(id: id, connection: connection)
                }))
            }
        }
    }

    private func extractRequestId(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["requestId"] as? String
    }
}
