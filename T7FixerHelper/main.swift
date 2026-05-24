import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: T7HelperProtocol.self)
        newConnection.exportedObject = T7HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: T7HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
