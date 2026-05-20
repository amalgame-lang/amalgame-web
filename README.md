# amalgame-web (Mosaic runtime library)

The runtime library half of the **Mosaic** web stack — Router,
Sessions, WebContext. Pure-Amalgame classes you `import` from your
code.

```
amalgame-tls          (OpenSSL — TLS 1.2/1.3)
   └── amalgame-net-http   (HTTP/1.1 + HTTP/2 — parser, client, h2c)
          └── amalgame-web    (this package — Router, Sessions, WebContext)
```

The **build tool** (filesystem routing, DEV mode, scaffolding) is
a separate project: [`amalgame-lang/mosaic`](https://github.com/amalgame-lang/mosaic).
Install it once via `curl … install.sh | bash`, run from any
project. amalgame-web stays pure-library.

## What this package ships

- **Router** with `:param` and `*splat` path matching
- **Route** + **RouteMatch** primitives
- **Session** + **MemorySessionStore** (dev / test storage)
- **WebContext** — per-request bag (path params + app state + session)
- **SecurityHeaders** (v0.4.0) — builder + `Apply(resp)` for the
  standard browser-side hardening headers (CSP, HSTS, XFO, nosniff,
  Referrer-Policy, Permissions-Policy, COOP, COEP)

## Roadmap

- v0.4.x — Security pack: CORS, CSRF, rate-limit middlewares
- v0.5.x — ACME / Let's Encrypt integration via amalgame-tls
- v0.6.x — `JsonFileSessionStore`, `RedisSessionStore`
- v0.7.x — Reverse proxy + layout/nested-layout helpers

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

## SecurityHeaders

Response-side hardening. Defaults are *off* — start from a preset
(`StrictHtml` for HTML pages, `StrictApi` for JSON APIs) and tweak
with the builder methods.

```amalgame
let sec = SecurityHeaders.StrictHtml()
    .WithHsts(31536000, true, false)        // 1 year, includeSubDomains, no preload

// in the accept loop, after running the handler:
let resp: HttpResponse = match.Route.Handler(ctx)
sec.Apply(resp)                              // stamps the configured headers
TcpConn_Send(conn, resp.Render())
```

`Apply` never overwrites a header the handler itself set — the
handler wins. This lets a route opt out of (or specialize) a
configured policy without disabling the global config.

HSTS is the one header that no preset sets for you: pinning a
year-long HSTS on a response served over HTTP can lock users out
of the site. Always opt in explicitly *and only when serving HTTPS*.

| Builder | Default | Header it controls |
|---|---|---|
| `WithCsp(policy)` / `WithoutCsp()` | preset-dependent | `Content-Security-Policy` |
| `WithHsts(maxAge, sub, preload)` | unset | `Strict-Transport-Security` |
| `WithFrameOptions("DENY")` | `"DENY"` (Strict*) | `X-Frame-Options` |
| `WithContentTypeOptions(true)` | on (Strict*) | `X-Content-Type-Options: nosniff` |
| `WithReferrerPolicy(value)` | strict-origin-when-cross-origin (Html) / no-referrer (Api) | `Referrer-Policy` |
| `WithPermissionsPolicy(value)` | `camera=(), microphone=(), geolocation=()` (Html) | `Permissions-Policy` |
| `WithCoop(value)` | unset | `Cross-Origin-Opener-Policy` |
| `WithCoep(value)` | unset | `Cross-Origin-Embedder-Policy` |

## Test

```bash
./tests/run_tests.sh /path/to/amc
```

## License

Apache-2.0. See [LICENSE](./LICENSE).
