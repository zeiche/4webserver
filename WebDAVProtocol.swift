#!/usr/bin/env swiftc

import Foundation

// MARK: - WebDAV Protocol Handler

class WebDAVHandler: RequestHandler {
    private let renderer: WebDAVRenderer

    init(renderer: WebDAVRenderer = WebDAVXMLRenderer()) {
        self.renderer = renderer
    }

    func canHandle(_ request: HTTPRequest) -> Bool {
        return ["PROPFIND", "GET", "PUT", "DELETE", "MKCOL", "OPTIONS"].contains(request.method)
    }

    func handle(_ request: HTTPRequest, database: DatabaseClient?) -> HTTPResponse {
        guard let db = database else {
            return HTTPResponse(status: "503 Service Unavailable", body: "Database not available")
        }

        switch request.method {
        case "PROPFIND":
            return handlePROPFIND(request, database: db)
        case "GET":
            return handleGET(request, database: db)
        case "PUT":
            return handlePUT(request, database: db)
        case "DELETE":
            return handleDELETE(request, database: db)
        case "MKCOL":
            return handleMKCOL(request, database: db)
        case "OPTIONS":
            return handleOPTIONS(request)
        default:
            return HTTPResponse(status: "405 Method Not Allowed")
        }
    }

    private func handlePROPFIND(_ request: HTTPRequest, database: DatabaseClient) -> HTTPResponse {
        let path = cleanPath(request.path)

        // ASK: Query for directory contents
        let query = "SELECT name, path, is_folder, size, content_type FROM virtual_files WHERE parent_path = '\(path)'"
        if let result = database.askQuery(query) {
            let items = parseFileItems(from: result)
            database.tellEvent("propfind_request", data: ["path": path, "count": "\(items.count)"])
            return renderer.renderDirectoryListing(path: path, items: items)
        }

        return HTTPResponse(status: "404 Not Found")
    }

    private func handleGET(_ request: HTTPRequest, database: DatabaseClient) -> HTTPResponse {
        let path = cleanPath(request.path)

        // ASK: Query for file content
        let query = "SELECT content FROM virtual_files WHERE path = '\(path)'"
        if let content = database.askQuery(query) {
            let contentType = determineContentType(path: path)
            database.tellEvent("file_downloaded", data: ["path": path, "size": "\(content.count)"])
            return HTTPResponse(status: "200 OK", contentType: contentType, body: content)
        }

        return HTTPResponse(status: "404 Not Found")
    }

    private func handlePUT(_ request: HTTPRequest, database: DatabaseClient) -> HTTPResponse {
        let path = cleanPath(request.path)

        guard let body = request.body,
              let content = String(data: body, encoding: .utf8) else {
            return HTTPResponse(status: "400 Bad Request")
        }

        // DO: Store file content
        let query = "INSERT INTO virtual_files (path, content, size, modified_at) VALUES ('\(path)', '\(content)', \(content.count), NOW()) ON DUPLICATE KEY UPDATE content = '\(content)', size = \(content.count), modified_at = NOW()"

        if database.doOperation(query) {
            database.tellEvent("file_uploaded", data: ["path": path, "size": "\(content.count)"])
            return HTTPResponse(status: "201 Created")
        } else {
            return HTTPResponse(status: "500 Internal Server Error")
        }
    }

    private func handleDELETE(_ request: HTTPRequest, database: DatabaseClient) -> HTTPResponse {
        let path = cleanPath(request.path)

        // DO: Delete file/folder
        let query = "DELETE FROM virtual_files WHERE path = '\(path)' OR path LIKE '\(path)/%'"

        if database.doOperation(query) {
            database.tellEvent("file_deleted", data: ["path": path])
            return HTTPResponse(status: "204 No Content")
        } else {
            return HTTPResponse(status: "500 Internal Server Error")
        }
    }

    private func handleMKCOL(_ request: HTTPRequest, database: DatabaseClient) -> HTTPResponse {
        let path = cleanPath(request.path)

        // DO: Create folder
        let query = "INSERT INTO virtual_files (path, is_folder, created_at) VALUES ('\(path)', 1, NOW())"

        if database.doOperation(query) {
            database.tellEvent("folder_created", data: ["path": path])
            return HTTPResponse(status: "201 Created")
        } else {
            return HTTPResponse(status: "500 Internal Server Error")
        }
    }

    private func handleOPTIONS(_ request: HTTPRequest) -> HTTPResponse {
        return HTTPResponse(
            status: "200 OK",
            headers: [
                "DAV": "1, 2",
                "Allow": "OPTIONS, PROPFIND, GET, PUT, DELETE, MKCOL",
                "Content-Length": "0"
            ],
            body: Data()
        )
    }

    private func cleanPath(_ path: String) -> String {
        // Remove query parameters for WebDAV paths
        if let queryIndex = path.firstIndex(of: "?") {
            return String(path.prefix(upTo: queryIndex))
        }
        return path
    }

    private func parseFileItems(from result: String) -> [VirtualFileItem] {
        // Parse database result into VirtualFileItem array
        // This is a simplified parser - in practice would use proper SQL result parsing
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        var items: [VirtualFileItem] = []

        for line in lines.dropFirst() { // Skip header
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 5 {
                let item = VirtualFileItem(
                    name: parts[0],
                    path: parts[1],
                    isFolder: parts[2] == "1",
                    size: Int(parts[3]) ?? 0,
                    contentType: parts[4].isEmpty ? nil : parts[4]
                )
                items.append(item)
            }
        }

        return items
    }

    private func determineContentType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "txt": return "text/plain"
        case "html": return "text/html"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - WebDAV Response Renderer

protocol WebDAVRenderer {
    func renderDirectoryListing(path: String, items: [VirtualFileItem]) -> HTTPResponse
}

class WebDAVXMLRenderer: WebDAVRenderer {
    func renderDirectoryListing(path: String, items: [VirtualFileItem]) -> HTTPResponse {
        var xmlResponse = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        """

        for item in items {
            let href = item.path
            let isFolder = item.isFolder

            xmlResponse += """

            <D:response>
                <D:href>\(href)</D:href>
                <D:propstat>
                    <D:prop>
            """

            if isFolder {
                xmlResponse += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xmlResponse += "<D:resourcetype/>"
                xmlResponse += "<D:getcontentlength>\(item.size)</D:getcontentlength>"
                if let contentType = item.contentType {
                    xmlResponse += "<D:getcontenttype>\(contentType)</D:getcontenttype>"
                }
            }

            xmlResponse += """
                        <D:displayname>\(item.name)</D:displayname>
                    </D:prop>
                    <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
            </D:response>
            """
        }

        xmlResponse += "\n</D:multistatus>"

        return HTTPResponse(status: "207 Multi-Status", contentType: "application/xml", body: xmlResponse)
    }
}