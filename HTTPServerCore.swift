#!/usr/bin/env swiftc

import Foundation

// MARK: - Data Layer

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

    init(status: String, contentType: String = "text/plain", body: String = "") {
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

// MARK: - Database Integration

protocol DatabaseClient {
    func doOperation(_ query: String) -> Bool
    func askQuery(_ query: String) -> String?
    func tellEvent(_ event: String, data: [String: String])
}

// MARK: - Business Logic Layer

protocol RequestHandler {
    func canHandle(_ request: HTTPRequest) -> Bool
    func handle(_ request: HTTPRequest, database: DatabaseClient?) -> HTTPResponse
}

// Authentication is now handled by Module 5

// MARK: - Presentation Layer

protocol ResponseRenderer {
    func renderUnauthorized() -> HTTPResponse
    func renderAuthChallenge(method: String, realm: String) -> HTTPResponse
    func renderNotFound() -> HTTPResponse
    func renderMethodNotAllowed() -> HTTPResponse
    func renderError(_ message: String) -> HTTPResponse
}

class StandardHTTPRenderer: ResponseRenderer {
    func renderUnauthorized() -> HTTPResponse {
        return HTTPResponse(status: "401 Unauthorized", body: "Unauthorized")
    }

    func renderAuthChallenge(method: String, realm: String) -> HTTPResponse {
        return HTTPResponse(
            status: "401 Unauthorized",
            headers: ["WWW-Authenticate": "\(method) realm=\"\(realm)\"", "Content-Length": "12"],
            body: "Unauthorized".data(using: .utf8) ?? Data()
        )
    }

    func renderNotFound() -> HTTPResponse {
        return HTTPResponse(status: "404 Not Found", body: "Not Found")
    }

    func renderMethodNotAllowed() -> HTTPResponse {
        return HTTPResponse(status: "405 Method Not Allowed", body: "Method Not Allowed")
    }

    func renderError(_ message: String) -> HTTPResponse {
        return HTTPResponse(status: "500 Internal Server Error", body: message)
    }
}

// MARK: - Core HTTP Server

class HTTPServer {
    private let port: Int
    private var serverSocket: Int32 = -1
    private var handlers: [RequestHandler] = []
    private var authMiddleware: AuthenticationMiddleware?
    private let renderer: ResponseRenderer
    private let display: DisplayAdapter
    private var databaseClient: DatabaseClient?

    init(port: Int, renderer: ResponseRenderer = StandardHTTPRenderer()) {
        self.port = port
        self.renderer = renderer
        self.display = DisplayAdapter()
    }

    func setAuthenticationMiddleware(_ middleware: AuthenticationMiddleware) {
        self.authMiddleware = middleware
        display.log("Authentication middleware configured", icon: "🔐", fallback: "[AUTH]")
    }

    func setDatabaseClient(_ client: DatabaseClient) {
        self.databaseClient = client
        display.log("Connected to database service", icon: "🔗", fallback: "[DB]")
    }

    func addHandler(_ handler: RequestHandler) {
        handlers.append(handler)
    }

    func start() throws {
        // Create socket
        serverSocket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard serverSocket >= 0 else {
            throw ServerError.socketCreationFailed
        }

        // Allow reuse of address
        var reuse = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int>.size))

        // Bind to port
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = UInt16(port).bigEndian
        serverAddr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            throw ServerError.bindFailed
        }

        // Listen for connections
        guard listen(serverSocket, 5) >= 0 else {
            throw ServerError.listenFailed
        }

        display.log("HTTP Server started on port \(port)", icon: "🚀", fallback: "[START]")

        // Accept connections
        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            if clientSocket >= 0 {
                handleConnection(clientSocket: clientSocket)
            }
        }
    }

    private func handleConnection(clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read request
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let bytesRead = recv(clientSocket, buffer, bufferSize - 1, 0)
        guard bytesRead > 0 else { return }

        buffer[bytesRead] = 0  // Null terminate
        let requestData = Data(bytes: buffer, count: bytesRead)
        guard let requestString = String(data: requestData, encoding: .utf8) else { return }

        // Parse request
        let request = parseHTTPRequest(requestString)
        display.log("\(request.method) \(request.path)", icon: "📥", fallback: "[REQUEST]")

        // Process request
        let response = processRequest(request)

        // Send response
        let responseData = response.serialize().data(using: .utf8) ?? Data()
        _ = responseData.withUnsafeBytes { bytes in
            send(clientSocket, bytes.bindMemory(to: UInt8.self).baseAddress, responseData.count, 0)
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
        var bodyStart = -1

        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStart = index + 1
                break
            }
            if index > 0 {
                let headerParts = line.components(separatedBy: ": ")
                if headerParts.count >= 2 {
                    headers[headerParts[0]] = headerParts[1]
                }
            }
        }

        // Extract body if present
        var body: Data? = nil
        if bodyStart >= 0 && bodyStart < lines.count {
            let bodyLines = Array(lines[bodyStart...])
            let bodyString = bodyLines.joined(separator: "\r\n")
            body = bodyString.data(using: .utf8)
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func processRequest(_ request: HTTPRequest) -> HTTPResponse {
        // Check authentication using Module 5
        if let authMiddleware = authMiddleware {
            let authResult = authMiddleware.processRequest(request)

            switch authResult {
            case .failure:
                return renderer.renderUnauthorized()
            case .challenge(let method, let realm):
                return renderer.renderAuthChallenge(method: method, realm: realm)
            case .success:
                break // Continue processing
            }
        }

        // Find handler
        for handler in handlers {
            if handler.canHandle(request) {
                return handler.handle(request, database: databaseClient)
            }
        }

        return renderer.renderNotFound()
    }
}

enum ServerError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
}