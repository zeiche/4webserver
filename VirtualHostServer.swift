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

        // Set socket timeout to prevent hanging
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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

        // Look up service via mDNS (lazy discovery)
        guard let service = discoverService(for: hostname) else {
            let response = HTTPResponse(status: "503 Service Unavailable",
                                       body: "Service not discovered: \(hostname)")
            sendResponse(response, to: clientSocket)
            display.log("Service not found: \(hostname)", icon: "❌", fallback: "[404]")
            return
        }

        display.log("Routing \(hostname) → \(service.host):\(service.port)", icon: "🔀", fallback: "[ROUTE]")

        // Proxy request to the discovered service
        let response = proxyRequest(request, to: service, originalRequest: request)
        sendResponse(response, to: clientSocket)
    }

    private func proxyRequest(_ request: HTTPRequest, to service: DiscoveredService, originalRequest: HTTPRequest) -> HTTPResponse {
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

        // Check if client is a browser
        let userAgent = originalRequest.headers["User-Agent"] ?? ""
        let isBrowser = userAgent.contains("Mozilla") || userAgent.contains("Chrome") || userAgent.contains("Safari")

        // Modify request to ask for JSON if client is a browser and service supports it
        var modifiedRequest = request
        if isBrowser && service.capabilities["supports_json"] == "true" {
            var headers = request.headers
            headers["Accept"] = "application/json"
            modifiedRequest = HTTPRequest(method: request.method, path: request.path, headers: headers, body: request.body)
        }

        // Forward the request
        let requestString = serializeHTTPRequest(modifiedRequest)
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

        // Parse the response
        let parsedResponse = parseHTTPResponse(responseString)

        // If browser and response is JSON, convert to HTML
        if isBrowser && parsedResponse.headers["Content-Type"]?.contains("application/json") == true {
            if let jsonBody = String(data: parsedResponse.body, encoding: .utf8) {
                let htmlBody = convertJSONToHTML(jsonBody, cssEndpoint: service.capabilities["css_endpoint"])
                return HTTPResponse(status: parsedResponse.status, contentType: "text/html", body: htmlBody)
            }
        }

        return parsedResponse
    }

    private func convertJSONToHTML(_ jsonString: String, cssEndpoint: String?) -> String {
        // Parse JSON
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String,
              type == "directory_listing",
              let path = json["path"] as? String,
              let items = json["items"] as? [[String: Any]] else {
            return "<html><body><h1>Error parsing JSON</h1></body></html>"
        }

        // Build HTML
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Directory: \(path)</title>
        """

        // Add CSS link if available (or default to /layout.css)
        let cssPath = cssEndpoint ?? "/layout.css"
        html += "\n    <link rel=\"stylesheet\" href=\"\(cssPath)\">"

        html += """

        </head>
        <body>
            <div class="directory-listing">
                <div class="header">
                    <h1>Directory Listing</h1>
                    <div class="path">\(path)</div>
                </div>
                <div class="items">
        """

        // Convert each item to HTML
        for item in items {
            guard let name = item["name"] as? String,
                  let type = item["type"] as? String,
                  let itemPath = item["path"] as? String else {
                continue
            }

            let isFolder = (type == "folder")
            let iconClass = isFolder ? "folder-icon" : "file-icon"
            let size = item["size"] as? Int ?? 0
            let sizeStr = isFolder ? "" : formatFileSize(size)

            html += """

                    <a href="\(itemPath)">
                        <div class="item">
                            <div class="icon \(iconClass)"></div>
                            <div class="item-info">
                                <div class="item-name">\(name)</div>
                                <div class="item-meta">\(type)</div>
                            </div>
                            <div class="item-size">\(sizeStr)</div>
                        </div>
                    </a>
            """
        }

        html += """

                </div>
            </div>
        </body>
        </html>
        """

        return html
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
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

    private func discoverService(for hostname: String) -> DiscoveredService? {
        // Extract service name from hostname (e.g., "webdav" from "webdav.local")
        let serviceName = hostname.replacingOccurrences(of: ".local", with: "")
                                   .replacingOccurrences(of: ".zilogo.com", with: "")
                                   .components(separatedBy: ".").first ?? ""

        if serviceName.isEmpty {
            return nil
        }

        // Query mDNS for service type
        let serviceType = "_\(serviceName)._tcp"
        display.log("Discovering \(serviceType) for \(hostname)...", icon: "🔍", fallback: "[DISCOVER]")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        process.arguments = ["2", "/usr/bin/avahi-browse", "-r", "-t", "-p", serviceType]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }

            // Parse avahi-browse output
            // Format: =;interface;protocol;name;type;domain;hostname;address;port;txt...
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("=") {
                    let parts = line.components(separatedBy: ";")
                    if parts.count >= 9 {
                        let host = parts[7]
                        let port = Int(parts[8]) ?? 0

                        // Parse TXT records (all in parts[9] as quoted strings)
                        var capabilities: [String: String] = [:]
                        if parts.count > 9 && !parts[9].isEmpty {
                            // TXT records are like: "key1=val1" "key2=val2"
                            let txtField = parts[9]
                            let txtRecords = txtField.components(separatedBy: "\" \"")
                            for record in txtRecords {
                                let cleaned = record.replacingOccurrences(of: "\"", with: "")
                                let txtParts = cleaned.components(separatedBy: "=")
                                if txtParts.count >= 2 {
                                    let key = txtParts[0]
                                    let value = txtParts[1...].joined(separator: "=")
                                    capabilities[key] = value
                                }
                            }
                        }

                        display.log("Found \(serviceType) at \(host):\(port)", icon: "✅", fallback: "[FOUND]")

                        return DiscoveredService(
                            hostname: hostname,
                            serviceType: serviceType,
                            name: serviceName,
                            host: host,
                            port: port,
                            lastSeen: Date(),
                            capabilities: capabilities
                        )
                    }
                }
            }
        } catch {
            display.log("Discovery error: \(error)", icon: "⚠️", fallback: "[ERROR]")
        }

        return nil
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