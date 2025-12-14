
### Smart Caching & Conditional GET

**Status**: Implemented

**Objective**: efficient feed fetching that respects server resources and data usage while keeping content fresh.

**Strategy**:
1.  **Client-Side TTL (1 Hour)**:
    -   The app maintains a strictly simplified local timer.
    -   If a feed was checked < 1 hour ago, we **do not** touch the network. We serve the cached content instantly.
    -   This protects "dumb" servers (no ETag support) from being hammered.

2.  **Conditional GET (> 1 Hour)**:
    -   After 1 hour, we contact the server.
    -   We explicitly check for `ETag` and `Last-Modified` headers from the previous response.
    -   **If Supported**: We send these values back (`If-None-Match`, `If-Modified-Since`).
        -   Server returns `304 Not Modified` (Body empty). -> We update the timestamp, keep old data.
        -   Server returns `200 OK` (New Body). -> We parse and replace data.
    -   **If Not Supported**: We send a standard GET request.
        -   Server returns `200 OK`. -> We parse and replace data.
        -   This ensures compatibility with ALL servers.

3.  **Forced Refresh**:
    -   Pull-to-refresh ignores the 1-hour timer but *still* uses Conditional GET.
    -   This means manually refreshing is fast and cheap if there is no new news.
