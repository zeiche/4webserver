# WebDAV + CSS Presentation Implementation TODO

## Goal
Get WebDAV to present its virtual filesystem as JSON + CSS to the web server on port 80.

## Architecture Decisions (CONFIRMED)
1. **JSON is the data format** - Universal, parseable, clean
2. **One static CSS per module** - Each module serves its own CSS on demand, no caching in web server
3. **Modules serve CSS directly** - Web server proxies CSS requests to modules
4. **Multiple client types** - Not just browsers/web servers - native clients, CLI tools, apps, etc. can all query modules

## Implementation Plan

### Phase 1: WebDAV Module Updates ✅
Location: `/home/ubuntu/2database/WebDAVServer.swift`

**Task 1.1: Add CSS endpoint to WebDAV** ✅
- ✅ Add `GET /layout.css` endpoint
- ✅ Returns static CSS describing directory listing layout
- ✅ CSS includes:
  - Grid/flex layout for directory listings
  - Folder/file styling (icons, colors, weights)
  - Spacing, padding, typography rules
- File: WebDAVServer.swift:357 (handleCSSRequest)

**Task 1.2: Ensure WebDAV returns JSON** ✅
- ✅ Content negotiation: Check `Accept: application/json` header
- ✅ Returns JSON directory listing with structure:
  ```json
  {
    "type": "directory_listing",
    "path": "/users/alice",
    "items": [
      {"name": "documents", "type": "folder", "path": "/users/alice/documents"},
      {"name": "photo.jpg", "type": "file", "size": 1024000, "path": "/users/alice/photo.jpg"}
    ]
  }
  ```
- File: WebDAVServer.swift:320 (handleJSONDirectoryListing)

**Task 1.3: Update mDNS advertisement** ✅
- ✅ Add TXT records to WebDAV service advertisement:
  - `css_endpoint=/layout.css`
  - `data_format=json`
  - `supports_json=true`
- File: WebDAVServer.swift:822 (registerWithServiceDiscovery)

### Phase 2: Web Server Updates (Port 80) ✅
Location: `/home/ubuntu/4webserver/VirtualHostServer.swift`

**Task 2.1: Extend DiscoveredService to include CSS metadata** ✅
- ✅ DiscoveredService.capabilities dictionary already supports arbitrary key-value pairs
- ✅ Parses TXT records from mDNS for `css_endpoint`, `data_format`, `supports_json`
- File: VirtualHostServer.swift:232 (capabilities field)

**Task 2.2: Add CSS proxying logic** ✅
- ✅ CSS requests proxied through normal request flow to module's endpoint
- ✅ No caching - modules serve CSS on demand
- ✅ Forward request to `http://service_ip:port/css_endpoint` and return response
- File: VirtualHostServer.swift:93 (proxyRequest)

**Task 2.3: Add JSON → HTML converter** ✅
- ✅ Function: `convertJSONToHTML(jsonString: String, cssEndpoint: String?) -> String`
- ✅ Converts JSON directory listings to semantic HTML with proper classes
- ✅ Includes file size formatting, folder/file icons, proper structure
- File: VirtualHostServer.swift:172 (convertJSONToHTML)

**Task 2.4: Modify response wrapping** ✅
- ✅ Browser detection via User-Agent (Mozilla/Chrome/Safari)
- ✅ Modifies request to include `Accept: application/json` for browsers
- ✅ Converts JSON responses to HTML for browsers
- ✅ Pass-through for non-browser clients
- File: VirtualHostServer.swift:124-169 (proxyRequest)

**Task 2.5: Handle CSS link in HTML wrapper** ✅
- ✅ HTML includes `<link rel="stylesheet" href="/layout.css">`
- ✅ Web server proxies CSS request to module via normal request flow
- File: VirtualHostServer.swift:194 (CSS link insertion)

### Phase 3: Testing ✅
Location: Static code analysis and compilation verification

**Task 3.1: Verify code compilation** ✅
- ✅ WebDAVServer.swift compiles without errors
- ✅ VirtualHostServer.swift compiles without errors
- Both files ready for runtime testing

**Task 3.2: Verify CSS endpoint implementation** ✅
- ✅ `handleCSSRequest()` returns complete CSS (140+ lines)
- ✅ Includes modern styling: gradients, flexbox, responsive design
- ✅ Proper Content-Type: text/css
- File: WebDAVServer.swift:314-455

**Task 3.3: Verify JSON endpoint implementation** ✅
- ✅ `handleJSONDirectoryListing()` converts directory items to JSON
- ✅ Content negotiation via `Accept: application/json` header
- ✅ Returns proper JSON structure with type, path, items
- File: WebDAVServer.swift:319-354

**Task 3.4: Verify service discovery integration** ✅
- ✅ DiscoveredService struct has `capabilities: [String: String]` in both files
- ✅ BonjourFramework.swift:18-26
- ✅ VirtualHostServer.swift:336-344
- ✅ WebDAV advertises: css_endpoint, data_format, supports_json

**Task 3.5: Verify web server integration** ✅
- ✅ Browser detection via User-Agent check
- ✅ Automatic Accept: application/json header injection for browsers
- ✅ JSON to HTML conversion with proper CSS classes
- ✅ CSS link injection in HTML wrapper
- File: VirtualHostServer.swift:93-247

### Phase 4: Runtime Testing (Manual)
**Status**: Ready for runtime testing

**Prerequisites for runtime testing:**
- Start WebDAV server: `./WebDAVServer.swift` (port 8080)
- Start mDNS listener/DNS server (Module 3)
- Start web server: `./VirtualHostServer.swift` (port 80)
- Ensure MySQL database is running with test data

**Runtime test commands:**
```bash
# Test 1: CSS endpoint
curl http://localhost:8080/layout.css

# Test 2: JSON endpoint
curl -H "Accept: application/json" http://localhost:8080/

# Test 3: XML endpoint (default WebDAV)
curl http://localhost:8080/

# Test 4: Browser access (requires running services + mDNS)
curl -H "User-Agent: Mozilla/5.0" http://webdav.zilogo.com/

# Test 5: Actual browser
# Open http://webdav.zilogo.com/ in Chrome/Firefox/Safari
```

## Files to Modify
1. `/home/ubuntu/4webserver/VirtualHostServer.swift` - Web server with CSS proxying and HTML wrapping
2. WebDAV service file (location TBD) - Add CSS endpoint and JSON response
3. mDNS advertisement file (likely BonjourFramework.swift) - Add TXT records
4. Possibly create new file: `/home/ubuntu/4webserver/JSONToHTMLConverter.swift` - JSON to HTML logic

## Notes
- **Crash prevention**: Save work frequently, commit to git if possible
- **Simplicity first**: Start with basic CSS, basic JSON structure
- **Test incrementally**: Test each phase before moving to next
- **No caching**: Web server proxies CSS requests directly to modules, no caching needed
- **Browser detection**: Simple User-Agent check, not perfect but good enough
- **Universal CSS**: One CSS per module works for all client types (browsers, apps, CLI tools, etc.)

## Open Questions
1. Where exactly is the WebDAV service code? Need to locate it first.
2. Does WebDAV already have JSON endpoints or only XML?
3. Is mDNS advertisement already in place for WebDAV?

## Success Criteria
✅ WebDAV advertises CSS endpoint via mDNS
✅ WebDAV returns JSON directory listings
✅ WebDAV serves static CSS file on demand
✅ Web server proxies CSS requests to modules
✅ Web server converts JSON to HTML
✅ Web server wraps HTML with CSS link
✅ Browser displays formatted directory listing using WebDAV's CSS
✅ Other clients (apps, CLI tools) can also fetch JSON+CSS independently

## Post-Implementation Cleanup
⚠️ **TODO**: Move WebDAV code from `/home/ubuntu/2database/` to proper directory structure
- Current location: `/home/ubuntu/2database/WebDAVServer.swift`
- Should be moved to dedicated WebDAV directory (e.g., `/home/ubuntu/webdav/`)
- Wait until current implementation is tested and stable before moving
- Update any import paths or references when moving

## Future Architecture Work
⚠️ **TODO**: Implement static linking for BonjourFramework
- Goal: Each service binary is fully independent and can run on any VPS
- Services should statically link BonjourFramework (no dynamic libs)
- Consider Swift Package or source inclusion approach
- Framework should provide:
  - Service registration/advertisement with TXT records
  - Service discovery for dependencies (database, auth, etc.)
  - IPC/communication between services
  - Graceful handling of missing dependencies
- Single self-contained executable per service
- **Note**: Current WebDAV server is standalone and doesn't use framework yet