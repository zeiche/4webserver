#!/usr/bin/env swiftc

import Foundation

// Virtual host server - multiple subdomains on port 80
// Routes based on mDNS service discovery

class VirtualHostServer {
    private let port: Int
    private var serverSocket: Int32 = -1
    private let serviceRegistry: ServiceRegistry
    private let display: DisplayAdapter

    init(port: Int = 80, serviceRegistry: ServiceRegistry) {
        self.port = port
        self.serviceRegistry = serviceRegistry
        self.display = DisplayAdapter()
    }

    func start() throws {
        // Standard HTTP server setup
        serverSocket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard serverSocket >= 0 else { throw ServerError.socketCreationFailed }

        var reuse = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int>.size))

        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = UInt16(port).bigEndian
        serverAddr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else { throw ServerError.bindFailed }
        guard listen(serverSocket, 5) >= 0 else { throw ServerError.listenFailed }

        display.log("Virtual Host Server started on port \(port)", icon: "🌐", fallback: "[START]")
        display.log("Routing based on mDNS service discovery", icon: "🎯", fallback: "[ROUTING]")

        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            if clientSocket >= 0 {
                handleRequest(clientSocket: clientSocket)
            }
        }
    }

    private func handleRequest(clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read HTTP request
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let bytesRead = recv(clientSocket, buffer, bufferSize - 1, 0)
        guard bytesRead > 0 else { return }

        buffer[bytesRead] = 0
        let requestData = Data(bytes: buffer, count: bytesRead)
        guard let requestString = String(data: requestData, encoding: .utf8) else { return }

        // Parse HTTP request
        let request = parseHTTPRequest(requestString)

        // Extract hostname from Host header (strip port if present)
        let hostHeader = request.headers["Host"]?.lowercased() ?? ""
        let hostname = hostHeader.components(separatedBy: ":").first ?? hostHeader

        display.log("Request: \(request.method) \(request.path) Host: \(hostname)", icon: "📥", fallback: "[REQ]")

        // Look up service in mDNS registry
        guard let service = serviceRegistry.lookupServiceForHostname(hostname) else {
            let response = HTTPResponse(status: "503 Service Unavailable",
                                       body: "Service not discovered: \(hostname)")
            sendResponse(response, to: clientSocket)
            display.log("Service not found: \(hostname)", icon: "❌", fallback: "[404]")
            return
        }

        display.log("Routing \(hostname) → \(service.host):\(service.port)", icon: "🔀", fallback: "[ROUTE]")

        // Proxy request to the discovered service
        let response = proxyRequest(request, to: service)
        sendResponse(response, to: clientSocket)
    }

    private func proxyRequest(_ request: HTTPRequest, to service: DiscoveredService) -> HTTPResponse {
        // Create connection to backend service
        let backendSocket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard backendSocket >= 0 else {
            return HTTPResponse(status: "502 Bad Gateway", body: "Failed to connect to backend")
        }
        defer { close(backendSocket) }

        // Set connection timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(backendSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(backendSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Parse IP address
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = UInt16(service.port).bigEndian
        inet_pton(AF_INET, service.host, &serverAddr.sin_addr)

        // Connect to backend
        let connectResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(backendSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectResult >= 0 else {
            display.log("Failed to connect to \(service.host):\(service.port)", icon: "❌", fallback: "[ERROR]")
            return HTTPResponse(status: "502 Bad Gateway", body: "Backend connection failed")
        }

        // Forward the request
        let requestString = serializeHTTPRequest(request)
        let requestData = requestString.data(using: .utf8) ?? Data()
        _ = requestData.withUnsafeBytes { bytes in
            send(backendSocket, bytes.bindMemory(to: UInt8.self).baseAddress, requestData.count, 0)
        }

        // Read response
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let bytesRead = recv(backendSocket, buffer, bufferSize, 0)
        guard bytesRead > 0 else {
            return HTTPResponse(status: "502 Bad Gateway", body: "No response from backend")
        }

        let responseData = Data(bytes: buffer, count: bytesRead)
        guard let responseString = String(data: responseData, encoding: .utf8) else {
            return HTTPResponse(status: "502 Bad Gateway", body: "Invalid response from backend")
        }

        // Parse and return the response
        return parseHTTPResponse(responseString)
    }

    private func serializeHTTPRequest(_ request: HTTPRequest) -> String {
        var result = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for (key, value) in request.headers {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"
        if let body = request.body, let bodyString = String(data: body, encoding: .utf8) {
            result += bodyString
        }
        return result
    }

    private func parseHTTPResponse(_ response: String) -> HTTPResponse {
        let lines = response.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            return HTTPResponse(status: "502 Bad Gateway", body: "Invalid response")
        }

        // Extract status
        let statusParts = statusLine.components(separatedBy: " ")
        let status = statusParts.count > 2 ? statusParts[1...].joined(separator: " ") : "200 OK"

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 1
        for (index, line) in lines.enumerated().dropFirst() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0]] = headerParts[1]
            }
        }

        // Extract body
        let bodyLines = Array(lines.dropFirst(bodyStartIndex))
        let bodyString = bodyLines.joined(separator: "\r\n")
        let body = bodyString.data(using: .utf8) ?? Data()

        return HTTPResponse(status: status, headers: headers, body: body)
    }

    private func sendResponse(_ response: HTTPResponse, to socket: Int32) {
        let responseData = response.serialize().data(using: .utf8) ?? Data()
        _ = responseData.withUnsafeBytes { bytes in
            send(socket, bytes.bindMemory(to: UInt8.self).baseAddress, responseData.count, 0)
        }
    }

    private func parseHTTPRequest(_ request: String) -> HTTPRequest {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return HTTPRequest(method: "GET", path: "/", headers: [:], body: nil)
        }

        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0]] = headerParts[1]
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: nil)
    }
}

// Types from mDNS framework
struct DiscoveredService {
    let hostname: String
    let serviceType: String
    let name: String
    let host: String
    let port: Int
    let lastSeen: Date
    let capabilities: [String: String]
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let status: String
    let headers: [String: String]
    let body: Data

    init(status: String, contentType: String = "text/html", body: String = "") {
        self.status = status
        self.headers = ["Content-Type": contentType, "Content-Length": "\(body.utf8.count)"]
        self.body = body.data(using: .utf8) ?? Data()
    }

    init(status: String, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    func serialize() -> String {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        if let bodyString = String(data: body, encoding: .utf8) {
            response += bodyString
        }
        return response
    }
}

// Stub for ServiceRegistry - would be imported from BonjourFramework
class ServiceRegistry {
    private var hostnameToService: [String: DiscoveredService] = [:]

    func lookupServiceForHostname(_ hostname: String) -> DiscoveredService? {
        return hostnameToService[hostname.lowercased()]
    }

    func announceService(_ service: DiscoveredService) {
        hostnameToService[service.hostname.lowercased()] = service
    }
}

// Stub for DisplayAdapter
class DisplayAdapter {
    func log(_ message: String, icon: String, fallback: String) {
        print("\(icon) \(message)")
    }
}

enum ServerError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
}

// Demo: Virtual host routing with mDNS discovery
func startVirtualHostDemo() {
    let registry = ServiceRegistry()
    let server = VirtualHostServer(port: 80, serviceRegistry: registry)

    print("\n🎯 Virtual Host Router with mDNS Discovery")
    print("   - Listens on port 80")
    print("   - Routes requests based on Host header")
    print("   - Discovers backend services via mDNS")
    print("\n   Add test services:")
    print("   registry.announceService(DiscoveredService(")
    print("       hostname: \"webdav.zilogo.com\",")
    print("       serviceType: \"_webdav._tcp\",")
    print("       name: \"webdav\",")
    print("       host: \"127.0.0.1\",")
    print("       port: 8081,")
    print("       lastSeen: Date(),")
    print("       capabilities: [:]))")
    print("")

    do {
        try server.start()
    } catch {
        print("❌ Failed to start server: \(error)")
    }
}

startVirtualHostDemo()