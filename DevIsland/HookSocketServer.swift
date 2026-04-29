import Foundation
import Network
import Combine

class HookSocketServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 9090
    
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
        receiveData(on: connection)
    }
    
    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let data = data, let message = String(data: data, encoding: .utf8) {
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
                self?.receiveData(on: connection)
            }
        }
    }
}
