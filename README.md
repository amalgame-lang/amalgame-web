# amalgame-web (Mosaic)

The Amalgame web framework. Top layer of the web stack:

```
amalgame-tls          (OpenSSL — TLS 1.2/1.3)
   └── amalgame-net-http   (HTTP/1.1 — parser + client + helpers)
          └── amalgame-web    (this package — Router, Sessions, WebContext)
```

## v0.1 — foundation pieces

Focused, working set:

- **Router** with `:param` and `*splat` path matching
- **Route** + **RouteMatch** primitives
- **Session** + **MemorySessionStore** (dev / test storage)
- **WebContext** — per-request bag (path params + app state + session)

## v0.1.x — coming next

These pieces are blocked on a language-level upgrade to amc
(first-class function types so `app.Get("/path", handler)` can take
a real callable). Once that lands, all of this drops in:

- `WebApp.Get/Post/Put/Patch/Delete(path, handler)` programmatic routing
- `WebApp.Use(middleware)` middleware pipeline
- Filesystem-based routing (`app/users/[id].am` → `/users/:id`)
- DEV mode (file watcher + hot dlopen)
- ACME / Let's Encrypt integration via amalgame-tls
- Security middleware (CSRF, CORS, rate limit, ...)
- JsonFileSessionStore, RedisSessionStore
- Reverse proxy

## Install

```bash
amc package add tls          # for HTTPS later
amc package add net-http     # HTTP parser + types
amc package add web          # this package
```

## v0.1 user pattern

Because we don't have first-class function types yet, route handlers
are dispatched by name (a string registered with each route). The
user writes their own if/else dispatch in the accept loop — verbose
but works today.

```amalgame
namespace App

import Amalgame.Collections
import Amalgame.String
import Amalgame.Net
import Amalgame.Net.Http
import Amalgame.Web

public class Program {
    public static void Main(string[] args) {
        let router = new Router()
        router
            .Get("/",              "home")
            .Get("/users",         "users_index")
            .Get("/users/:id",     "user_show")
            .Post("/users",        "user_create")
            .Get("/files/*path",   "file_serve")

        let srv = TcpServer_Listen(3000, 16)
        while (TcpServer_IsListening(srv)) {
            let conn = TcpServer_Accept(srv)
            let raw  = TcpConn_Receive(conn, 65536)
            let req  = HttpParser.ParseFull(raw)
            if (req == null) {
                TcpConn_Send(conn, HttpServer.BadRequestResponse())
                TcpConn_Close(conn)
                continue
            }
            let m = router.Match(req.Method, req.Path)
            var resp: HttpResponse = new HttpResponse()
            if (m == null) {
                resp = HttpResponse.New().Status(404).Text("Not found")
            } else if (m.HandlerName == "home") {
                resp = HttpResponse.New().Html("<h1>Welcome</h1>")
            } else if (m.HandlerName == "user_show") {
                resp = HttpResponse.New().Text("User " + m.Params.Get("id"))
            } else if (m.HandlerName == "file_serve") {
                resp = HttpResponse.New().Text("File: " + m.Params.Get("path"))
            } else {
                resp = HttpResponse.New().Status(501).Text("Not implemented")
            }
            TcpConn_Send(conn, resp.Render())
            TcpConn_Close(conn)
        }
        TcpServer_Close(srv)
    }
}
```

## Router matching rules

| Pattern | Matches | Captures |
|---|---|---|
| `/about` | exact `/about` | nothing |
| `/users/:id` | `/users/42`, `/users/alice` | `id` |
| `/posts/:year/:slug` | `/posts/2026/hello` | `year`, `slug` |
| `/files/*path` | `/files/x`, `/files/css/main.css` | `path` (joined with `/`) |

- Methods compared exactly (case-sensitive, uppercase convention).
- First-match-wins (registration order).
- Static routes should be registered before parameterized ones.

## Sessions

```amalgame
let store = new MemorySessionStore()
let s = store.Create("session_abc_123")   // caller-supplied id
s.Set("user_id", "42")
s.Set("theme", "dark")

let retrieved = store.Find("session_abc_123")
let theme = retrieved.Get("theme")     // "dark"

store.Destroy("session_abc_123")
```

Session ids should be 256-bit random tokens in production (use
`amalgame-random` once available; `tests/` shows the test-id pattern).

## Test

```bash
./tests/run_tests.sh /path/to/amc
```

## License

Apache-2.0. See [LICENSE](./LICENSE).
