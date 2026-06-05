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
- **Static** (v0.13.0) — file-serving middleware mounted at a URL
  prefix. MIME by extension (~35 types), strong ETag from
  `size-mtime`, `If-None-Match → 304`, path-traversal guard via
  `Path_Normalize` + root containment, 403 for dir / 404 for missing.
  Binary-safe wire-out via `HttpResponse.File(path)` → net-http's
  v0.9.6 `H1Conn_RespondFile` (PNG / JPEG / PDF survive NUL bytes).
  See [Static section](#static-v0130) below for usage.

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

## Server entry points

`WebApp` exposes seven drop-in serve methods; pick by deployment
model. The first five speak plain HTTP/1.1; the last two terminate
TLS in-process (HTTPS, ALPN `http/1.1`) via the cert/key pair you
provide.

| Method | Concurrency | Best for | Platform |
|---|---|---|---|
| `app.Serve(port)` | serial | dev / smoke / single-user | all |
| `app.ServeMt(port)` | 1 thread per conn (~8 MB lazy stack) | CPU-bound handlers | all |
| `app.ServeWith(port, cfg)` | serial + `HttpServerConfig` knobs | keep-alive + size limits | all |
| `app.ServeMtWith(port, cfg)` | multi-thread + config | the previous default for prod | all |
| `app.ServeAsync(port)` (v0.12.0) | 1 thread, N fibers (~64 KB / conn) | I/O-bound handlers | Linux only (epoll) |
| **`app.ServeHttps(port, certPath, keyPath)`** (v0.14.0) | **serial, in-process TLS termination** | **HTTPS dev / single-user** | **all (OpenSSL)** |
| **`app.ServeHttpsMt(port, certPath, keyPath)`** (v0.14.0) | **1 thread per conn + TLS** | **HTTPS prod (no reverse proxy needed)** | **all (OpenSSL)** |

Pair `ServeHttps*` with [`amalgame-tls`](https://github.com/amalgame-lang/amalgame-tls)
to issue + auto-renew the cert in-process — `AcmeNative.EnsureCert(domain, email, dir, "")`
provisions a Let's Encrypt cert at startup, `AcmeNative.AutoRenewTimer`
spawns a background thread that re-issues when the cert hits
the configured threshold (default 30 days). See the `amalgame-live`
demo for a complete pattern.

### When to pick `ServeAsync`

Per the benchmark in
[`amalgame-net-http/bench/`](https://github.com/amalgame-lang/amalgame-net-http/tree/main/bench)
(100 ms sleeping handler, asyncio client opening N concurrent
connections on a 2-core / 4 GB Linux box):

| N    | `ServeMt`              | `ServeAsync`            |
|------|------------------------|-------------------------|
| 100  | 1152 ms · 100/100      | **123 ms** · 100/100    |
| 500  | 2071 ms · 500/500      | **1374 ms** · 500/500   |
| 1000 | 2932 ms · 1000/1000    | **1628 ms** · 1000/1000 |
| 2000 | 31220 ms · **1665/2000** ⚠ | **1453 ms · 2000/2000** ✅ |

- **Pick `ServeAsync` when handlers do downstream I/O** (DB
  queries, HTTP client calls, file writes). The fiber parks
  during the wait; the scheduler advances another connection
  on the same OS thread. ServeMt blocks one OS thread per
  in-flight request.
- **Pick `ServeMtWith` when handlers are CPU-bound.** Async only
  amortises over I/O parks — pure compute can't be overlapped
  on a single OS thread.
- **`ServeAsync` is Linux-only in v0.12.0** (epoll). kqueue (BSD
  + macOS) lands in `amalgame-async` v0.2.1, IOCP (Windows) in
  v0.3; `ServeAsync` will become cross-platform automatically
  once those backends ship.
- HTTP/1.1 keep-alive is on by default (RFC 7230 rules).
- `HttpServerConfig` knobs (per-conn timeouts, body size limits)
  aren't wired into `ServeAsync` yet — that's `ServeAsyncWith` in
  v0.12.1 once `amalgame-net-http` v0.9.3 ships
  `Http1.ServeAsyncWith`.

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

### Automatic sessions (v0.20.0)

The snippet above is the manual API. In a `WebApp`, wire a store with
`WithSession(store)` and the pipeline does the cookie plumbing for you:
it loads `ctx.Session` from the request cookie before the handler and
persists it (backend write + `Set-Cookie`) afterwards.

```amalgame
let app = WebApp.New()
    .WithSession(new SignedCookieSessionStore(Env_Get("SESSION_SECRET")))
    .Get("/login", (ctx: WebContext) => {
        ctx.Session.Set("uid", "42")          // persisted automatically
        return HttpResponse.New().Text("ok")
    })
    .Get("/me", (ctx: WebContext) =>
        HttpResponse.New().Text("uid=" + ctx.Session.Get("uid")))
```

`WithSession` accepts any **`SessionStore`** — the interface implemented
by all three stores, so you swap storage without touching handlers:

- **`MemorySessionStore`** — dev / single process. Fresh visitors get a
  crypto-random id (`Session.NewId()`), stored in-process.
- **`RedisSessionStore`** — multi-node, survives restarts. Same id model,
  persisted to Redis with a TTL.
- **`SignedCookieSessionStore`** — stateless: the (optionally AES-GCM
  encrypted) cookie *is* the storage. Zero ops, scales horizontally.

`ctx.Session` is never null when sessions are enabled — returning
visitors get their existing session, everyone else a fresh empty one.
`SessionStore` exposes exactly two pipeline operations:
`LoadSession(req) -> Session` and `SaveSession(session, resp)`.

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

## Static (v0.13.0)

Serve files from disk at a URL prefix — the Mosaic equivalent of
nginx's `location /assets { root … }` or Apache's `Alias`.

```amalgame
let app = WebApp.New()
    .WithStatic(Static.New("/assets", "./public").WithCacheMaxAge(3600))
    .Get("/", ctx => HttpResponse.New().Html("<h1>Hi</h1>"))

app.Serve(8080)
```

That's the 10-line example. Behind it:

- **Prefix routing**: `GET /assets/logo.png` → `./public/logo.png`.
  Boundary check means `/assets-other` does NOT match `/assets`.
- **Path traversal blocked**: `/assets/../../etc/passwd` collapses
  via `Path_Normalize` to `/etc/passwd`, which is no longer under
  the `./public` root prefix → 403.
- **Dir vs file**: serving the mount point itself or any
  sub-directory yields 403 (no auto-index listing). Missing
  files yield 404.
- **Method gate**: only `GET` / `HEAD` reach the file; other
  methods get 405.
- **MIME**: inferred from extension — HTML, CSS, JS, WASM, JSON,
  SVG / PNG / JPEG / GIF / WEBP / AVIF / ICO, WOFF / WOFF2 /
  TTF / OTF, PDF, ZIP / GZ / TAR, YAML / TOML, …
  Unknown → `application/octet-stream`. Case-insensitive.
- **ETag**: strong, computed as `"size-mtime"` (both decimal,
  quoted per RFC 7232). Browsers re-cache on it.
- **Conditional GET**: `If-None-Match` match → `304 Not Modified`
  with no body and the same `ETag` header.
- **Binary-safe transport**: response uses
  `HttpResponse.File(path)` → `H1Conn_RespondFile` (net-http
  v0.9.6). PNG / JPEG / PDF / WASM with NUL bytes survive
  intact.
- **Cache-Control**: opt-in via `.WithCacheMaxAge(seconds)` →
  emits `Cache-Control: public, max-age=N`.

### Multiple mounts

Order matters — checked first-to-last; first matching prefix
wins. Declare more-specific mounts before catchalls:

```amalgame
let app = WebApp.New()
    .WithStatic(Static.New("/assets/v2", "./public-v2"))   // pinned
    .WithStatic(Static.New("/assets",    "./public"))      // current
    .Get("/api/users", ctx => /* … */)
```

### Config-file driven

`Static.FromMap(Map<string, string>)` for TOML-driven wiring:

```toml
[[static]]
prefix         = "/assets"
dir            = "./public"
cache_max_age  = 3600
```

### What's NOT in v0.1

- **`Range:` requests**. Today the whole file is sent. Adding
  partial-content needs a runtime `H1Conn_RespondFileRange`
  (deferred — see [`docs/proposals/beyond-http.md`](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/beyond-http.md)).
- **`Last-Modified` / `If-Modified-Since`**. Skipped pending an
  HTTP-date helper in `amalgame-datetime`. ETag covers the common
  cache-revalidation path on its own.
- **`sendfile(2)`** zero-copy. The runtime currently `GC_MALLOC`s
  the bytes — fine for typical assets (<10 MB), wasteful for
  large downloads.
- **Pre-compressed variant selection** (serve `.css.gz` /
  `.css.br` when the browser sends `Accept-Encoding`). Punt to v0.2.
- **Auto-index listing** of directories. Intentional: Apache's
  `Options +Indexes` has been a recurring source of accidental
  data exposure. If you need it, register a route handler.

## Auth & protected routes (v0.19.0)

`BasicAuth` (RFC 7617) and `JwtAuth` (HS256 Bearer) are first-class
middleware: register a scheme with `WithBasicAuth` / `WithJwt`, then
gate specific routes with the `Protected()` group. Public routes are
never challenged; a protected route with no scheme configured fails
closed (401), so a wiring mistake can't silently expose a handler.

```amalgame
let auth = new JwtAuth(Env_Get("JWT_SECRET"))

let app = WebApp.New()
    .WithJwt(auth)
    .WithSecurityHeaders(SecurityHeaders.StrictApi())
    .Get("/",       ctx => HttpResponse.New().Text("public landing"))
    .Get("/health", ctx => HttpResponse.New().Text("ok"))

// Everything in the group requires a valid token (401 otherwise):
app.Protected()
    .Get("/api/me",      ctx => HttpResponse.New().Json(currentUser(ctx)))
    .Post("/api/widgets", ctx => createWidget(ctx))
    .End()
    .Get("/about", ctx => HttpResponse.New().Text("public again"))

app.ServeHttps(443, "/etc/ssl/cert.pem", "/etc/ssl/key.pem")
```

`Protected()` returns a route group whose `Get/Post/Put/Patch/Delete`
register guarded routes and chain; `End()` climbs back to the `WebApp`
so public routes can follow. Configure **both** schemes to accept
either — e.g. Bearer JWT for the API plus Basic for a curl-friendly
admin endpoint:

```amalgame
let basic = new BasicAuth("Admin")
    .WithVerifier((u, p) => u == "admin" && p == Env_Get("ADMIN_PASSWORD"))

let app = WebApp.New()
    .WithJwt(new JwtAuth(Env_Get("JWT_SECRET")))
    .WithBasicAuth(basic)
    .Get("/", ctx => HttpResponse.New().Text("home"))
app.Protected()
    .Get("/admin", ctx => HttpResponse.New().Text("dashboard"))
```

Pipeline placement: auth runs **after** a route matches, before its
handler — so unmatched paths (404) and public routes pay nothing. A
denial still flows through the response-side middlewares, so the 401
carries `SecurityHeaders` / CORS just like any other response.

- **MUST ship over TLS.** Basic puts the password and Bearer puts
  the token on every request. Pair with `ServeHttps` / `ServeHttpsMt`.
- **JWT**: HS256 only (v0.19.0); verifies signature + `exp` / `nbf`.
  Read claims in the handler with your own `Json.Parse(jwt.Payload(req))`.
- **`OAuth2Client`** (authorization-code flow helper) ships in the
  package for login redirects + token exchange; wire its callback as
  an ordinary route handler. Call `.WithPkce()` to enable **PKCE**
  (RFC 7636, S256): `StartLogin` then sends a `code_challenge`
  (`base64url(SHA-256(code_verifier))`) + `code_challenge_method=S256`
  and stashes the verifier in the signed state cookie; `HandleCallback`
  replays `code_verifier` in the token exchange. Opt-in (the plain flow
  is unchanged) but recommended — it shuts the authorization-code
  interception window even when the client secret is exposed
  (SPAs / mobile / public clients). Available since web v0.34.0.
