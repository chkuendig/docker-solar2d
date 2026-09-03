# docker-solar2d

A Linux Docker image for [Solar2D](https://solar2d.com): **HTML5 and Android builds**,
a **headless simulator**, and an **MCP server** for driving it.

```
ghcr.io/chkuendig/solar2d:latest
ghcr.io/chkuendig/solar2d:3731     # pinned to a Solar2D release
```

Solar2D ships no Linux builder. The official HTML5 and Android tooling is macOS and
Windows only, even though the C++ underneath compiles fine on Linux — the packagers
are simply behind `#ifdef` gates the Linux CMake never sets. This image builds
Solar2D from [a fork](https://github.com/chkuendig/corona) that opens those gates,
so HTML5 and Android builds run anywhere Docker does, CI included.

## Use it

```bash
# HTML5 → MyApp.html5/
docker run -v $(pwd)/corona:/project -v $(pwd)/out:/output \
  ghcr.io/chkuendig/solar2d build --app-name MyApp

# Android → MyApp.apk + MyApp.aab
docker run -v $(pwd)/corona:/project -v $(pwd)/out:/output \
  ghcr.io/chkuendig/solar2d build-android --app-name MyApp --package com.example.myapp

# Headless simulator (Xvfb)
docker run -v $(pwd)/corona:/project ghcr.io/chkuendig/solar2d simulate

# MCP server over stdio, simulator inside
docker run -i -v $(pwd)/corona:/project ghcr.io/chkuendig/solar2d mcp
```

### Warm MCP runtime

Keep Xvfb and the image warm, then start one bounded stdio server per MCP
client with `docker exec`:

```bash
mkdir -p /tmp/solar2d-review
docker run -d --init --name solar2d-runtime \
  --cpus=1 --memory=1g --pids-limit=128 \
  -v /absolute/workspace/root:/absolute/workspace/root \
  -v /tmp/solar2d-review:/artifacts \
  ghcr.io/chkuendig/solar2d runtime

docker exec -i solar2d-runtime entrypoint.sh session
```

The workspace bind mount must preserve its absolute path because MCP clients pass
host project paths to the server. Encoded MP4s are exported through `/artifacts`,
so review media can be uploaded without committing it to a repository.

Simulator access is one slot per runtime. A second MCP connection stays healthy
and receives a busy response while another client owns the simulator. The session
command defaults to a 20-minute limit; set `SOLAR2D_MCP_SESSION_TIMEOUT` on the
runtime container if a different bound is needed. SIGTERM and normal disconnect
both stop only the owning session's simulator before releasing its slot.

Do not enable parallel simulators yet. They still require separate displays,
homes/Solar2D sandboxes, temporary directories, and per-slot resource accounting.

Without a keystore the Android build is signed with Android's public debug key:
installable, not distributable. Pass `ANDROID_KEYSTORE_BASE64` and friends to sign
for real — see `build-android.sh` for the full list.

An HTML5 build merges anything mounted at `/html5-custom` into the web template, so
you can ship your own `index.html`, icons and manifest.

## What's in it

| | |
|---|---|
| `Solar2DBuilder` | HTML5 + Android packager |
| `Solar2DSimulator` | headless, via Xvfb |
| [`solar2d-mcp`](https://github.com/chkuendig/solar2d-mcp) | MCP server: run projects, screenshots, taps, logs |
| Android SDK, Gradle, JDK 17 | pre-warmed so a build does not start by downloading Gradle |

## It is three repos, not one

Cloning this repo and building does **not** reproduce the published image on its own —
it pulls from two forks that are part of the supply chain:

| Repo | Branch | Why |
|---|---|---|
| [`chkuendig/corona`](https://github.com/chkuendig/corona) | `linux-<tag>` | Solar2D with the Linux gaps closed |
| [`chkuendig/solar2d-mcp`](https://github.com/chkuendig/solar2d-mcp) | `linux-fixes` | MCP server with Linux launch fixes and shared-runtime coordination |

The Solar2D fork carries three changes, each also on its own branch for offering
upstream:

- **HTML5 builder** — `CORONABUILDER_HTML5` in the Linux CMake. Without it the binary
  answers *"building for HTML5 is not supported on this operating system"*, despite
  having the packager compiled in.
- **Android builder** — the same gate for Android, plus the Linux branches
  CoronaBuilder is missing: a resource directory, the `AndroidValidation` script path,
  and `Rtt_AndroidSupportTools.c` in the source list.
- **`display.save()` colours** — captures came back blue with red and green traded and
  blue taken from the alpha byte. `CaptureFrameBuffer` reads with a *packed*
  `GL_UNSIGNED_INT_8_8_8_8`, so the bytes land as ARGB, and the PNG writer was told
  they were BGRA byte order. macOS and Windows have their own writers and never saw it.

A new Solar2D release needs a matching `linux-<tag>` branch on the fork before the
image can build. That is deliberate — the build fails with a clear message rather
than quietly producing an unpatched tree.

## Build args

| Arg | Purpose |
|---|---|
| `SOLAR2D_VERSION` | Release to build, e.g. `2026.3731`. Picks the MSI and the default fork branch |
| `SOLAR2D_REPO` / `SOLAR2D_REF` | Build a different tree or branch — an upstream tag, a PR branch, another fork |
| `SOLAR2D_REF_SHA` | Expected commit of that branch. Verified after cloning, and busts the layer cache when the branch moves |
| `SOLAR2D_PRS` | Space-separated upstream PR numbers, applied as diffs — e.g. `891`. For trying a PR without committing to it |
| `SOLAR2D_MCP_REF` | solar2d-mcp commit to install |

`SOLAR2D_REF_SHA` matters more than it looks. The ref is a *branch*, so its content
moves without its name moving, and a cached `git clone` layer will happily keep
building last week's tree — silently. CI resolves the branch head and passes it.
Building by hand after pushing to the branch, do the same or use `--no-cache`:

```bash
docker build --build-arg SOLAR2D_VERSION=2026.3731 \
  --build-arg SOLAR2D_REF_SHA=$(gh api repos/chkuendig/corona/commits/linux-3731 --jq .sha) \
  -t solar2d .
```

## Why the webtemplate comes out of a Windows installer

The source tree ships a **0-byte placeholder** for `webtemplate.zip`. The real WASM
engine is built by Solar2D's CI with Emscripten on macOS and shipped only inside the
Windows MSI and macOS DMG. The Linux CMake has no Emscripten step, so it would copy
the placeholder and fail at runtime. The image extracts the real one from the MSI
before building — along with `android-template.zip` and `Corona.aar`, which the Linux
tree does not build either.

## Notes

- Solar2D's iOS packager shells out to `xcodebuild` and `codesign`, so **iOS cannot be
  containerised**. It needs macOS.
- The simulator uses a lot of CPU: the GL render loop is uncapped, Xvfb has no vsync
  and llvmpipe has no frame limiter. `config.lua`'s `fps` limits the Lua loop, not the
  renderer. Cap it with `--cpus`, and stop it when you are done.

## Licence

The image build scripts here are MIT. Solar2D itself is MIT
([coronalabs/corona](https://github.com/coronalabs/corona)); the bundled Android
template, `Corona.aar` and web template come from the official Solar2D release
artifacts and carry their own terms.
