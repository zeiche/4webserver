#!/usr/bin/env swiftc

import Foundation

// MARK: - Web Browser Handler

class WebBrowserHandler: RequestHandler {
    private let renderer: WebBrowserRenderer

    init(renderer: WebBrowserRenderer = HTMLRenderer()) {
        self.renderer = renderer
    }

    func canHandle(_ request: HTTPRequest) -> Bool {
        // Handle GET requests that look like browser requests (not WebDAV)
        return request.method == "GET" &&
               (request.path == "/" || request.path.hasPrefix("/?browse"))
    }

    func handle(_ request: HTTPRequest, database: DatabaseClient?) -> HTTPResponse {
        guard let db = database else {
            return HTTPResponse(status: "503 Service Unavailable", body: "Database not available")
        }

        let browsePath = extractBrowsePath(from: request.path)

        // ASK: Query for directory contents
        let query = "SELECT name, path, is_folder, size, content_type FROM virtual_files WHERE parent_path = '\(browsePath)'"
        if let result = db.askQuery(query) {
            let items = parseFileItems(from: result)
            db.tellEvent("browse_request", data: ["path": browsePath, "count": "\(items.count)"])
            return renderer.renderFileBrowser(path: browsePath, items: items)
        }

        return HTTPResponse(status: "404 Not Found", body: "Directory not found")
    }

    private func extractBrowsePath(from path: String) -> String {
        if path == "/" {
            return "/"
        } else if path.hasPrefix("/?browse=") {
            var browsePath = String(path.dropFirst(9)) // Remove "/?browse="
            // Clean up the path
            browsePath = browsePath.replacingOccurrences(of: "//", with: "/")
            if !browsePath.hasPrefix("/") {
                browsePath = "/" + browsePath
            }
            if browsePath.isEmpty {
                browsePath = "/"
            }
            return browsePath
        }
        return "/"
    }

    private func parseFileItems(from result: String) -> [VirtualFileItem] {
        // Parse database result into VirtualFileItem array
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
}

// MARK: - Web Browser Renderer

protocol WebBrowserRenderer {
    func renderFileBrowser(path: String, items: [VirtualFileItem]) -> HTTPResponse
}

class HTMLRenderer: WebBrowserRenderer {
    func renderFileBrowser(path: String, items: [VirtualFileItem]) -> HTTPResponse {
        var itemsHtml = ""

        // Add parent directory link if not at root
        if path != "/" {
            let parentPath = (path as NSString).deletingLastPathComponent
            let finalParentPath = parentPath.isEmpty ? "/" : parentPath
            itemsHtml += """
            <tr class="folder">
                <td><a href="/?browse=\(finalParentPath)">&#x1F4C1; ..</a></td>
                <td>-</td>
                <td>Folder</td>
            </tr>
            """
        }

        // Add items
        for item in items {
            let icon = item.isFolder ? "&#x1F4C1;" : "&#x1F4C4;"
            let sizeText = item.isFolder ? "-" : "\(item.size) bytes"
            let typeText = item.isFolder ? "Folder" : (item.contentType ?? "File")

            let linkPath: String
            if item.isFolder {
                let folderPath = String(item.path.dropLast()) // Remove trailing /
                linkPath = "/?browse=\(folderPath)"
            } else {
                linkPath = item.path
            }

            itemsHtml += """
            <tr class="\(item.isFolder ? "folder" : "file")">
                <td><a href="\(linkPath)">\(icon) \(item.name)</a></td>
                <td>\(sizeText)</td>
                <td>\(typeText)</td>
            </tr>
            """
        }

        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Database File Browser</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 20px; }
                .header { background: #f0f8ff; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
                .path { background: #e8e8e8; padding: 10px; border-radius: 4px; margin-bottom: 15px; font-family: monospace; }
                table { width: 100%; border-collapse: collapse; }
                th, td { text-align: left; padding: 12px; border-bottom: 1px solid #ddd; }
                th { background-color: #f5f5f5; font-weight: bold; }
                .folder a { color: #0066cc; }
                .file a { color: #333; }
                a { text-decoration: none; }
                a:hover { text-decoration: underline; }
                tr:hover { background-color: #f9f9f9; }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>&#x1F5C4;&#xFE0F; Database File Browser</h1>
                <p>&#x1F4C1; Browsing MySQL BLOB storage filesystem</p>
            </div>

            <div class="path">
                <strong>Current path:</strong> \(path == "/" ? "/" : path)
            </div>

            <table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Size</th>
                        <th>Type</th>
                    </tr>
                </thead>
                <tbody>
                    \(itemsHtml)
                </tbody>
            </table>
        </body>
        </html>
        """

        return HTTPResponse(status: "200 OK", contentType: "text/html", body: htmlContent)
    }
}

// MARK: - Alternative Renderers

class JSONRenderer: WebBrowserRenderer {
    func renderFileBrowser(path: String, items: [VirtualFileItem]) -> HTTPResponse {
        let jsonData: [String: Any] = [
            "path": path,
            "items": items.map { item in
                [
                    "name": item.name,
                    "path": item.path,
                    "isFolder": item.isFolder,
                    "size": item.size,
                    "contentType": item.contentType ?? ""
                ]
            }
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return HTTPResponse(status: "200 OK", contentType: "application/json", body: jsonString)
        } catch {
            return HTTPResponse(status: "500 Internal Server Error", body: "JSON serialization failed")
        }
    }
}

class PlainTextRenderer: WebBrowserRenderer {
    func renderFileBrowser(path: String, items: [VirtualFileItem]) -> HTTPResponse {
        var content = "Directory listing for: \(path)\n\n"

        for item in items {
            let type = item.isFolder ? "DIR " : "FILE"
            let size = item.isFolder ? "" : " (\(item.size) bytes)"
            content += "\(type) \(item.name)\(size)\n"
        }

        return HTTPResponse(status: "200 OK", contentType: "text/plain", body: content)
    }
}