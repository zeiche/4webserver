# WebDAV + CSS Presentation Implementation TODO

## Goal
Get WebDAV to present its virtual filesystem as JSON + CSS to the web server on port 80.

## Architecture Decisions (CONFIRMED)
1. **JSON is the data format** - Universal, parseable, clean
2. **Static CSS, cached in memory** - Fetched once per service, no dynamic generation needed
3. **WebDAV already does this** - Just add CSS endpoint, ensure JSON responses work
4. **In-memory cache is fine** - Fast, simple, re-fetch on service restart/TTL

## Implementation Plan

### Phase 1: WebDAV Module Updates
Location: `/home/ubuntu/` (find existing WebDAV service module)

**Task 1.1: Add CSS endpoint to WebDAV**
- Add `GET /layout.css` endpoint
- Returns static CSS describing directory listing layout
- CSS should include:
  - Grid/flex layout for directory listings
  - Folder/file styling (icons, colors, weights)
  - Spacing, padding, typography rules
- File: Likely in WebDAVProtocol.swift or equivalent

**Task 1.2: Ensure WebDAV returns JSON**
- Check if existing WebDAV endpoints can return JSON
- Options:
  - Content negotiation: Check `Accept: application/json` header
  - Dedicated endpoint: `/api/directory?path=XXX`
- JSON structure should include:
  ```json
  {
    "type": "directory_listing",
    "path": "/users/alice",
    "items": [
      {"name": "documents", "type": "folder", "size": null, "modified": "2025-01-15"},
      {"name": "photo.jpg", "type": "file", "size": 1024000, "modified": "2025-01-14"}
    ]
  }
  ```

**Task 1.3: Update mDNS advertisement**
- Add TXT records to WebDAV service advertisement:
  - `css_endpoint=/layout.css`
  - `data_endpoint=/api/directory` (or appropriate path)
  - `data_format=json`
- File: Likely in BonjourFramework.swift or service registration code

### Phase 2: Web Server Updates (Port 80)
Location: `/home/ubuntu/4webserver/VirtualHostServer.swift`

**Task 2.1: Extend DiscoveredService to include CSS metadata**
- Add fields for CSS endpoint from TXT records
- Parse TXT records from mDNS for `css_endpoint`, `data_endpoint`, `data_format`

**Task 2.2: Add CSS cache to VirtualHostServer**
- In-memory cache: `[String: String]` (hostname → CSS content)
- Fetch CSS once on first request to a service
- Cache invalidation: Simple TTL or on service restart

**Task 2.3: Add CSS fetching logic**
- When routing to a service, check if CSS is cached
- If not cached, fetch from `http://service_ip:port/css_endpoint`
- Store in cache

**Task 2.4: Add JSON → HTML converter**
- Generic function: `convertJSONToHTML(json: Data) -> String`
- Converts JSON objects to semantic HTML with data attributes
- Example:
  ```json
  {"name": "docs", "type": "folder"}
  ```
  Becomes:
  ```html
  <div class="item" data-name="docs" data-type="folder">
    <span class="name">docs</span>
    <span class="type">folder</span>
  </div>
  ```

**Task 2.5: Modify response wrapping**
- When proxying to a service that has CSS:
  - Check if client is a browser (User-Agent contains Mozilla/Chrome/Safari)
  - If browser + service returns JSON:
    - Convert JSON to HTML
    - Wrap in full HTML document with CSS link
    - Return HTML to browser
  - If not browser or no CSS endpoint:
    - Pass through response as-is

**Task 2.6: Handle CSS serving**
- Add endpoint: `GET /__internal/css/{hostname}`
- Serves cached CSS for a given hostname
- Referenced in HTML wrapper: `<link rel="stylesheet" href="/__internal/css/webdav.zilogo.com">`

### Phase 3: Testing
Location: Manual testing or test scripts

**Task 3.1: Test WebDAV CSS endpoint**
- `curl http://webdav-service:8081/layout.css`
- Verify CSS is returned

**Task 3.2: Test WebDAV JSON endpoint**
- `curl -H "Accept: application/json" http://webdav-service:8081/api/directory?path=/`
- Verify JSON directory listing is returned

**Task 3.3: Test mDNS advertisement**
- Use `dns-sd -B _webdav._tcp` or equivalent
- Verify TXT records include css_endpoint, data_endpoint

**Task 3.4: Test web server routing**
- `curl http://webdav.zilogo.com/` (from browser or with User-Agent)
- Verify HTML wrapper with CSS is returned

**Task 3.5: Test browser rendering**
- Open `http://webdav.zilogo.com/` in actual browser
- Verify directory listing renders with proper layout

### Phase 4: Integration
**Task 4.1: Ensure all modules are running**
- mDNS listener (Module 3)
- WebDAV service (with new endpoints)
- Web server on port 80 (Module 4)

**Task 4.2: Verify end-to-end flow**
- Service advertises via mDNS
- Web server discovers service
- Web server fetches CSS (once)
- Web server proxies requests and wraps responses
- Browser displays formatted directory listing

## Files to Modify
1. `/home/ubuntu/4webserver/VirtualHostServer.swift` - Web server with CSS caching and HTML wrapping
2. WebDAV service file (location TBD) - Add CSS endpoint and JSON response
3. mDNS advertisement file (likely BonjourFramework.swift) - Add TXT records
4. Possibly create new file: `/home/ubuntu/4webserver/JSONToHTMLConverter.swift` - JSON to HTML logic

## Notes
- **Crash prevention**: Save work frequently, commit to git if possible
- **Simplicity first**: Start with basic CSS, basic JSON structure
- **Test incrementally**: Test each phase before moving to next
- **Cache is simple**: Just a dictionary, no expiration logic needed initially
- **Browser detection**: Simple User-Agent check, not perfect but good enough

## Open Questions
1. Where exactly is the WebDAV service code? Need to locate it first.
2. Does WebDAV already have JSON endpoints or only XML?
3. Is mDNS advertisement already in place for WebDAV?

## Success Criteria
✅ WebDAV advertises CSS endpoint via mDNS
✅ WebDAV returns JSON directory listings
✅ WebDAV serves static CSS file
✅ Web server caches CSS in memory
✅ Web server converts JSON to HTML
✅ Web server wraps HTML with CSS link
✅ Browser displays formatted directory listing using WebDAV's CSS