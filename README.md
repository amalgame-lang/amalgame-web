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
  Referrer-Policy, Permissions-Policy, COOP, COEP).
  `SecurityHeaders.FromMap(...)` (v0.4.1) wires it to flat key/value
  config (consumed by the Mosaic CLI when it flattens `mosaic.toml`'s
  `[security.headers]` table).
- **Cors** (v0.5.0) — CORS middleware: `Preflight(req)` handles
  OPTIONS preflight, `Apply(req, resp)` decorates normal cross-origin
  responses. Presets `AllowAll` / `Strict`, builders for fine-grained
  control, `Cors.FromMap(...)` for TOML-driven wiring.
- **RateLimit** (v0.6.0) — fixed-window per-key throttle.
  `Check(req)` returns a 429 response on overflow (with Retry-After),
  null when allowed. Per-IP keying via `RemoteAddr`. Time source:
  monotonic nanoseconds via `amalgame-datetime`. Presets `PerIp` /
  `Disabled`, builders, `RateLimit.FromMap(...)`.
- **Csrf** (v0.7.0) — double-submit cookie CSRF guard.
  `EnsureToken(req, resp)` bootstraps the cookie (256-bit entropy
  via `amalgame-random`), `Validate(req)` returns a 403 on mismatch
  (or null when the method/path is exempt). Presets `Default` /
  `Disabled`, builders for cookie attributes + safe methods +
  exempt paths, `Csrf.FromMap(...)`.
- **WebApp** (v0.8.0) — orchestrator chaining every middleware into
  a single `Handle(req)` entry point.
- **LogConfig + WebApp.WithLogging** (v0.8.2) — bridges Mosaic's
  `[logging]` TOML table into `amalgame-logging`. Sets the
  process-wide level + file sink at startup; emits a one-liner
  per request at INFO level when `access_log = true`.
- **SignedCookieSessionStore** (v0.8.3) — stateless sessions
  signed with HMAC-SHA-256 via `amalgame-crypto`. No server-side
  storage — the cookie value IS the session payload. Default of
  Rails/Flask/Phoenix; zero ops for new apps. Signed-only in v0.1
  (data visible but tamper-proof) — AEAD encryption arrives with
  amalgame-crypto v0.2.

## Roadmap

- v0.7.x — `JsonFileSessionStore`, `RedisSessionStore`, cookie attribute config
- v0.8.x — Reverse proxy + layout/nested-layout helpers

## Install

```bash
amc package add tls          # for HTTPS later
amc package add net-http     # HTTP parser + types
amc package add datetime     # for RateLimit (monotonic clock)
amc package add random       # for Csrf (crypto entropy)
amc package add logging      # for LogConfig + access logs
amc package add crypto       # for SignedCookieSessionStore (HMAC)
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

### Config-file driven (v0.4.1)

`SecurityHeaders.FromMap(Map<string, string>)` builds an instance
from a flat key/value map — designed for the Mosaic CLI to feed in
the result of flattening `mosaic.toml`'s `[security.headers]` table:

```toml
[security.headers]
preset                  = "strict_html"      # starting point
csp                     = "default-src https:"   # override preset CSP
hsts_max_age            = 31536000
hsts_include_subdomains = true
hsts_preload            = false
```

Recognised keys: `preset` (`strict_html` | `strict_api`), `csp`,
`frame_options`, `content_type_options` (`true`/`false`),
`referrer_policy`, `permissions_policy`, `coop`, `coep`, `hsts`
(pre-composed) OR `hsts_max_age` + `hsts_include_subdomains` +
`hsts_preload`. Unknown keys are ignored (forward-compat).

## Cors (v0.5.0)

Cross-origin resource sharing — preflight handler + response decorator.

```amalgame
let cors = Cors.Strict()
    .WithAllowedOrigins(["https://app.example.com"])
    .WithAllowedHeaders(["Content-Type", "Authorization"])
    .WithAllowCredentials(true)
    .WithMaxAge(86400)

// in dispatch:
let pf: HttpResponse = cors.Preflight(req)
if (pf != null) {
    TcpConn_Send(conn, pf.Render())
    continue                                 // short-circuit — handler not called
}
let resp = match.Route.Handler(ctx)
cors.Apply(req, resp)                        // decorates resp with Allow-Origin / Vary / etc.
TcpConn_Send(conn, resp.Render())
```

- **`Preflight(req)`** returns a 204 response when `req` is a CORS
  preflight (OPTIONS + `Access-Control-Request-Method`), `null`
  otherwise. The 204 carries the allow-* headers when origin
  matches, or none when not (browser then rejects).
- **`Apply(req, resp)`** stamps `Access-Control-Allow-Origin`,
  `Access-Control-Allow-Credentials`, `Access-Control-Expose-Headers`
  onto a normal response. Always sets `Vary: Origin` when a cross-
  origin request is detected, even on non-matching origins, so
  HTTP caches don't cross-serve.
- **Wildcard + credentials are spec-incompatible**: when
  `AllowCredentials = true`, the wildcard `"*"` is suppressed and
  the specific request origin is echoed back instead.
- **Handler-wins**: if your route already set
  `Access-Control-Allow-Origin`, `Apply` leaves it alone.

`Cors.FromMap(Map<string, string>)` mirrors the `SecurityHeaders`
pattern. Recognised keys:

```toml
[security.cors]
preset             = "strict"            # or "allow_all" / "disabled"
allowed_origins    = "https://a.example.com, https://b.example.com"
allowed_methods    = "GET, POST"
allowed_headers    = "Content-Type, Authorization"
exposed_headers    = "X-Request-Id"
allow_credentials  = true
max_age_sec        = 86400
```

Lists are comma-separated with optional whitespace; each element is trimmed.

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

## RateLimit (v0.6.0)

Fixed-window per-key throttle. Counts requests per IP per window;
returns a 429 response with `Retry-After` when over.

```amalgame
let rl = RateLimit.PerIp(100, 60)         // 100 req per 60 s per IP

// in dispatch:
let limited: HttpResponse = rl.Check(req)
if (limited != null) {
    TcpConn_Send(conn, limited.Render())
    continue                              // short-circuit handler
}
let resp = match.Route.Handler(ctx)
...
```

Time source is `DateTime.NowMonotonicNanos()` from
[amalgame-datetime](https://github.com/amalgame-lang/amalgame-datetime)
— monotonic, immune to NTP slews + DST jumps. The store is an
in-process `Map<key, RateLimitBucket>`; v0.7 will add a Redis backend
for multi-process / multi-host deployments.

Known limitation: the **fixed-window algorithm** can allow up to
`2 × MaxRequests` across a single window boundary (a burst that
straddles two windows). For Mosaic v1 this is acceptable; v2 will
offer sliding-window / token-bucket variants.

`RateLimit.FromMap(Map<string, string>)` for the `[security.rate_limit]`
TOML table:

```toml
[security.rate_limit]
enabled       = true
rps           = 100                        # shortcut: 100 per 1 s
# OR explicit max + window:
# max_requests  = 1000
# window_sec    = 60
key_strategy  = "ip"                       # only one supported today
```

When `enabled = false`, returns `RateLimit.Disabled()` regardless of
other keys. `rps` is a shortcut for `max_requests=N, window_sec=1`.

## Csrf (v0.7.0)

Double-submit cookie CSRF guard. The browser's same-origin policy
keeps cross-origin pages from reading the cookie or setting custom
headers without our consent, so the attacker can't forge the
matching header even if they trick the user into submitting a form.

```amalgame
let csrf = Csrf.Default()                  // 256-bit token, Secure + SameSite=Lax

// in dispatch — BEFORE the handler:
let forbid: HttpResponse = csrf.Validate(req)
if (forbid != null) {
    TcpConn_Send(conn, forbid.Render())   // 403
    continue
}

let resp = match.Route.Handler(ctx)
csrf.EnsureToken(req, resp)                // bootstraps cookie on first hit
TcpConn_Send(conn, resp.Render())
```

- **Safe methods** (GET / HEAD / OPTIONS) bypass `Validate` by
  default. Override with `WithSafeMethods(...)`.
- **Exempt paths** (e.g. `/api/webhooks/*` for inbound third-party
  callbacks that can't carry your CSRF token) bypass via
  `ExemptPath(prefix)`. Prefix-match, applied in order.
- **Token**: 32-byte (256-bit) hex string from `amalgame-random`'s
  crypto-grade `Random.SystemBytes` (`/dev/urandom` /
  `BCryptGenRandom`). `WithTokenBytes(...)` to tune.
- **Cookie attributes**: defaults are `Secure=true`, `SameSite=Lax`,
  `Path=/`, no `HttpOnly` (the SPA needs to read it to echo back).
  Tweak with `WithCookieSecure(...)`, `WithCookieSameSite(...)`, etc.

`Csrf.FromMap(Map<string, string>)` for the `[security.csrf]`
TOML table:

```toml
[security.csrf]
enabled         = true
cookie_name     = "csrf_token"
header_name     = "X-CSRF-Token"
token_bytes     = 32
cookie_secure   = true
cookie_samesite = "Lax"
cookie_max_age  = 0                        # 0 = session cookie
exempt_paths    = "/api/webhooks/, /healthz"
```

Set `enabled = false` to get `Csrf.Disabled()` regardless of other
keys — useful for tearing down validation in dev without removing
the wiring.
