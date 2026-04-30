import Foundation
import Network
import Combine

class HookSocketServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 9090
    private let maxPayloadSize = 1_048_576
    
    var onMessageReceived: ((String, @escaping (String) -> Void) -> Void)?
    
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
        connection.start(queue: .global())
        receiveData(on: connection, accumulatedData: Data())
    }
    
    private func receiveData(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            var payload = accumulatedData
            if let data {
                payload.append(data)
            }

            let maxPayloadSize = self?.maxPayloadSize ?? 0
            if payload.count > maxPayloadSize {
                print("Received payload exceeds size limit")
                connection.cancel()
                return
            }

            if isComplete, let message = String(data: payload, encoding: .utf8) {
                print("Received data: \(message)")
                DispatchQueue.main.async {
                    self?.onMessageReceived?(message) { response in
                        let responseData = Data(response.utf8)
                        connection.send(content: responseData, completion: .contentProcessed({ sendError in
                            if let error = sendError {
                                print("Send error: \(error)")
                            }
                            connection.cancel()
                        }))
                    }
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receiveData(on: connection, accumulatedData: payload)
            }
        }
    }
}
