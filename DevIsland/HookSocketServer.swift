import Foundation
import Network
import Combine

class HookSocketServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 9090
    private let maxPayloadSize = 1_048_576
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "DevIsland.HookSocketServer.connections")

    /// Called when a complete message is received.
    /// - Parameters:
    ///   - message: Raw JSON string (raw mode) or envelope JSON string (framed mode).
    ///   - requestId: UUID from the IPC envelope, or nil for raw JSON requests.
    ///   - responseHandler: Call with the response string. The server automatically
    ///     frames the response if the request was framed.
    var onMessageReceived: ((String, String?, @escaping (String) -> Void) -> Void)?
    var onServerFailed: (() -> Void)?

    func start() {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: port)

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Server listening on port \(self.port)")
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
            let length = headerSoFar.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
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
                var length = UInt32(responseBytes.count).bigEndian
                var framed = Data(bytes: &length, count: 4)
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
