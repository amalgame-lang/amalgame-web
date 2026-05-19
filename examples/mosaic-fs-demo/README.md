# mosaic-fs-demo

Filesystem-routing demo for **amalgame-web v0.2** served over
**HTTP/2 cleartext** via amalgame-net-http v0.2's `Http2.Serve`.

## Layout

```text
mosaic-fs-demo/
├── amalgame.toml        # web + net-http deps
├── server.am            # entry — wires Router + Http2.Serve
└── app/                 # filesystem-routed handlers
    ├── index.am         → GET /
    ├── about.am         → GET /about
    ├── users/[id].am    → GET /users/:id
    └── api/info.am      → GET /api/info  +  POST /api/info
```

## Convention (Next.js App Router style)

Each `app/<path>.am` declares **one `public class Page`** with one
static method per HTTP verb:

```amalgame
// app/users/[id].am
import Amalgame.Web

public class Page {
    public static HttpResponse GET(WebContext ctx) {
        return HttpResponse.New().Text("user " + ctx.Param("id"))
    }
    public static HttpResponse POST(WebContext ctx) {
        return HttpResponse.New().Status(201).Text("created")
    }
}
```

No `namespace` declaration in route files — the build tool
(`tools/mosaic-routes.sh`) puts them all in `namespace App` and
renames each `class Page` to `<PathPrefix>_Page` (`Users_Id_Page`,
etc.) at generation time, so collisions are impossible.

Path-to-route mapping:

| File                     | Route          |
|--------------------------|----------------|
| `app/index.am`           | `/`            |
| `app/about.am`           | `/about`       |
| `app/users/[id].am`      | `/users/:id`   |
| `app/blog/[...slug].am`  | `/blog/*slug`  |
| `app/api/info.am`        | `/api/info`    |

## Build & run

Requires:
- `amc` ≥ v0.8.34 (multi-class dispatch fix)
- `amalgame-web@v0.2.0` (this package, for the build tool)
- `amalgame-net-http@v0.2.0` (for `Http2.Serve`)
- `libgc-dev`, `libnghttp2-dev`

```bash
amc package add web@v0.2.0
amc package add net-http@v0.2.0
mosaic-build.sh                # → ./server
./server                       # listens on :3000 (h2c)
```

`mosaic-build.sh` runs three steps:
1. `mosaic-routes.sh app _routes.am` — scan + emit glue
2. `amc server.am _routes.am -o server` — compile
3. `gcc` with package archives + `-lnghttp2 -lgc -lm -lz`

## Verify

```bash
curl --http2-prior-knowledge http://localhost:3000/
curl --http2-prior-knowledge http://localhost:3000/about
curl --http2-prior-knowledge http://localhost:3000/users/42
curl --http2-prior-knowledge http://localhost:3000/api/info
curl --http2-prior-knowledge -X POST http://localhost:3000/api/info
```

Every status line is `HTTP/2 2xx` (or `HTTP/2 404` for an unknown
path) — real h2 framing on the wire.

## What's NOT in v0.2 (yet)

- **DEV mode hot-reload.** Editing an `app/*.am` file requires a
  rebuild + restart for now. v0.2.x will add `mosaic dev`: file
  watcher (inotify) + `app.so` via `gcc -shared -fPIC` + `dlopen`
  hot-swap.
- **Per-package precompile invoked by `amc package add`.** Today
  the wrapper precompiles missing facades on first build. Once
  package install does this consistently, the warmup step
  disappears.
- **Layout files / nested layouts.** v0.2 is one handler per route;
  shared layouts come in v0.3.
