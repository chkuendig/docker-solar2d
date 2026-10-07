# docker-solar2d

A Linux Docker image for [Solar2D](https://solar2d.com): **HTML5 and Android builds**,
and a **headless simulator** you can drive through two FIFOs.

```
ghcr.io/chkuendig/solar2d:latest
ghcr.io/chkuendig/solar2d:3734     # pinned to a Solar2D release
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

# Headless simulator — offscreen EGL, no X server
docker run -v $(pwd)/corona:/project ghcr.io/chkuendig/solar2d simulate

# One screenshot: content box pinned, app given delay-ms to reach its scene
docker run -v $(pwd)/corona:/project -v $(pwd)/out:/output \
  -e MYAPP_PREVIEW_SCENE=home ghcr.io/chkuendig/solar2d capture home 320x480 3000
```

### From GitHub Actions

Both build steps ship as composite actions, so a workflow does not hand-write
`docker run` and its volume mounts. Set `transport: stream` when the Docker
daemon cannot see the runner's checkout paths: inputs and outputs travel through
client-side tar streams, and the temporary container is removed after the build.
The default `bind` transport mounts the workspace directly. Android's optional
`gradle-cache` input names a workspace-relative directory that can be restored
with `actions/cache`; streamed builds copy downloads back even on build failure:

Streamed containers auto-remove on exit and carry their run ID. Their lifetime is
bounded to 1800 seconds by default; set `SOLAR2D_ACTION_KEEPALIVE_SECONDS` in the
calling step's `env` to match longer job budgets (integer 1–86400 seconds).


```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: chkuendig/docker-solar2d/.github/actions/build-html5@main
        with:
          project: corona
          app-name: MyApp

      - uses: chkuendig/docker-solar2d/.github/actions/build-android@main
        with:
          project: corona
          app-name: MyApp
          package: com.example.myapp
          version-code: ${{ github.run_number }}
        env:
          ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          ANDROID_KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          ANDROID_KEYSTORE_ALIAS: ${{ secrets.ANDROID_KEYSTORE_ALIAS }}
          ANDROID_KEYSTORE_ALIAS_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_ALIAS_PASSWORD }}
```

Inputs map one-to-one onto the build scripts' flags (`project`, `output`,
`app-name`, `app-version`, `html5-custom`, `build-version`, and on Android
`package`, `version-code`, `store`, `keystore`). The workspace is mounted into the
container at its own absolute path, so those inputs are plain
workspace-relative paths. Signing credentials travel through `env`, never
`with` — GitHub can mask secrets in logs but not in input values rendered into
workflow UIs.

The action ref selects its code; the `image` input selects the Solar2D release
it runs. For reproducible CI, pin an action commit and an image release or
digest, such as `ghcr.io/chkuendig/solar2d:3734`.

An iOS build cannot come out of the Linux image: it needs Xcode. The
`build-ios` action runs on a macOS runner, installs the official Solar2D macOS
release named by `solar2d-version`, and drives its CoronaBuilder with the same
inputs as the other build actions. Signing is mandatory (the Apple packager
rejects a build without a provisioning profile, Simulator targets included), so
the certificate and profile travel through `env` like the Android keystore:

```yaml
  ios:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v6
      - uses: chkuendig/docker-solar2d/.github/actions/build-ios@main
        with:
          project: corona
          app-name: MyApp
          app-version: 1.4.2
        env:
          IOS_CERTIFICATE_BASE64: ${{ secrets.IOS_CERTIFICATE_BASE64 }}
          IOS_CERTIFICATE_PASSWORD: ${{ secrets.IOS_CERTIFICATE_PASSWORD }}
          IOS_PROVISIONING_PROFILE_BASE64: ${{ secrets.IOS_PROVISIONING_PROFILE_BASE64 }}
```

`IOS_CERTIFICATE_BASE64` is a base64 PKCS#12 holding the Apple Distribution (or
Development) certificate and its key; `IOS_PROVISIONING_PROFILE_BASE64` is the
base64 `.mobileprovision` for the app id, which is also where the builder reads
the bundle id. If OpenSSL 3 makes the p12, export it with `-legacy`: macOS cannot
import its default AES/SHA-256 form and reports a wrong password instead. The
action imports into a throwaway keychain that is deleted when the job ends,
fails if the profile has expired, and packages a bare `.app` into an IPA when the
profile type makes the builder stop short of one. `preflight: true` installs the
toolchain and validates inputs without secrets or a build; macOS minutes cost
ten times Linux ones, so keep iOS off pull-request triggers.

A `walk` action drives the headless simulator through a steps file and
saves a named PNG per `snap` — offscreen, content box pinned, every input
dispatched as a real SDL event and every step waiting for its ack or for a
marker the app prints:

```yaml
      - uses: chkuendig/docker-solar2d/.github/actions/walk@main
        with:
          project: corona
          steps: ci/home.walk
          output: screenshots
          screen: 320x480
          video: "true"           # also screenshots/walk.mp4
          env: |
            MYAPP_DEBUG_PREVIEW=home
            MYAPP_PREVIEW_LANG=de
```

With video enabled, the simulator's framed BGRA stream passes through a Python
reader that validates each 64-byte header and forwards complete pixel payloads
to ffmpeg. Each `snap` holds the scene for one second before the next step,
so its state appears in the video, including the last snapshot.

```text
# ci/home.walk — one step per line
fail MYAPP_DEFECT                 # abort the moment the app prints this
wait 3000                         # let it boot and settle
snap home                         # -> screenshots/home.png
tap 160 420                       # content coordinates, real hit-testing
expect [APP] settings shown       # block until the app prints the marker
snap settings
key escape                        # SDL key names; the app sees Solar2D
                                  # names (SDL "return" -> keyName "enter")
drag 160 400 160 100 400          # press, move over 400ms, release
snap scrolled
```

A single screenshot is a two-line walk (`wait <ms>`, `snap <label>`); the
image's `capture` command is exactly that. `expect` steps give up after
`expect-timeout-ms` (default 30000) and fail the walk. How the app reaches each screen
stays the project's business: the walk pins geometry and sequencing, your
preview hook picks the scene through whatever env vars it already reads, and
your stdout markers are what `expect` and `fail` wait on. Needs release 3734
or newer.
Snapshots come from `display.save`, so native objects (text fields, text
boxes, webviews) are missing from the PNGs; the video is read from the rendered
frame and shows them.

### Warm runtime

`runtime` keeps a container idle so later `docker exec` calls can start and
drive simulators in it without paying container start-up each time:

```bash
docker run -d --init --name solar2d-runtime \
  --cpus=1 --memory=1g --pids-limit=128 \
  -v "$(pwd)/corona:/project:ro" \
  ghcr.io/chkuendig/solar2d runtime
```

Without a keystore the Android build is signed with Android's public debug key:
installable, not distributable. Pass `ANDROID_KEYSTORE_BASE64` and friends to sign
for real — see `build-android.sh` for the full list.

## Driving the headless simulator from outside

Two opt-in channels exist on simulator builds, both FIFOs the container
(or host) provides and the engine serves — no server, no Python:

```bash
mkdir -p /tmp/tap
docker run -d --name sim \
  -e SOLAR2D_VIDEO_PIPE=/dev/shm/video.fifo \
  -e SOLAR2D_INPUT_PIPE=/dev/shm/input.fifo \
  -v "$(pwd)/corona:/project:ro" \
  -v /tmp/tap:/dev/shm \
  ghcr.io/chkuendig/solar2d simulate

# video: every frame after a reader attaches, 64-byte header + raw BGRA;
# probe <path>.ready, never the FIFO itself

# input: one command per line, content coordinates, dispatched as real SDL
# events (real hit-testing); each dispatch acks as [INPUT] on stdout
docker exec sim sh -c 'printf "tap 150 250\n" > /dev/shm/input.fifo'
docker exec sim sh -c 'printf "drag 100 100 100 400 500\n" > /dev/shm/input.fifo'
```

Video readers must decode each frame's header before feeding its BGRA payload
to ffmpeg; both `python3` and `ffmpeg` are in the image for readers that run
inside the container. Full wire format and command grammar: `docs/offscreen-capture-design.md`.

An HTML5 build merges anything mounted at `/html5-custom` into the web template, so
you can ship your own `index.html`, icons and manifest.

## What's in it

| | |
|---|---|
| `Solar2DBuilder` | HTML5 + Android packager |
| `Solar2DSimulator` | headless — offscreen EGL (llvmpipe), no X server |
| `python3`, `ffmpeg` | for reading and encoding the video FIFO inside the container |
| Android SDK, Gradle, JDK 17 | pre-warmed so a build does not start by downloading Gradle |
| `.github/actions/*` | composite actions wrapping build and capture for CI consumers |

## It is two repos, not one

Cloning this repo and building does **not** reproduce the published image on its own —
it pulls from a fork that is part of the supply chain:

| Repo | Branch | Why |
|---|---|---|
| [`chkuendig/docker-solar2d`](https://github.com/chkuendig/docker-solar2d) | `main` | Image, build scripts, and the build and walk actions |
| [`chkuendig/corona`](https://github.com/chkuendig/corona) | `linux-<tag>` (currently `linux-3734`) | Solar2D with the Linux gaps closed |

The Solar2D fork carries Linux fixes on its release branches, with focused
branches for offering individual changes upstream:

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
- **Offscreen capture and input** — resize the EGL surface to the requested window
  dimensions, stream video frames through a FIFO, and dispatch injected input as
  native SDL events.

A new Solar2D release needs a matching `linux-<tag>` branch on the fork before the
image can build. That is deliberate — the build fails with a clear message rather
than quietly producing an unpatched tree. The weekly publish run is therefore the
signal that a release has landed. To cut the branch, start from the release tag and
cherry-pick the previous `linux-<tag>` branch's commits onto it. Then check that the
new branch changes the same files the same way as the old one did:

```bash
git switch -c linux-<new> <new>
git cherry-pick -x <old>..linux-<old>
diff <(git diff <old> linux-<old>) <(git diff <new> HEAD)   # empty
```

Upstream fixes to the HTML5 runtime reach the image only through `SOLAR2D_VERSION`,
not through the fork branch: the WASM engine comes from that release's MSI (below).
Before you count on such a fix, check that the release tag contains it:
`git merge-base --is-ancestor <fix> <tag>`.

## Build args

| Arg | Purpose |
|---|---|
| `SOLAR2D_VERSION` | Release to build, e.g. `2026.3734`. Picks the MSI and the default fork branch |
| `SOLAR2D_REPO` / `SOLAR2D_REF` | Build a different tree or branch — an upstream tag, a PR branch, another fork |
| `SOLAR2D_REF_SHA` | Expected commit of that branch. Verified after cloning, and busts the layer cache when the branch moves |
| `SOLAR2D_PRS` | Space-separated upstream PR numbers, applied as diffs — e.g. `891`. For trying a PR without committing to it |

`SOLAR2D_REF_SHA` matters more than it looks. The ref is a *branch*, so its content
moves without its name moving, and a cached `git clone` layer will happily keep
building last week's tree — silently. CI resolves the branch head and passes it.
Building by hand after pushing to the branch, do the same or use `--no-cache`:

```bash
docker build --build-arg SOLAR2D_VERSION=2026.3734 \
  --build-arg SOLAR2D_REF_SHA=$(gh api repos/chkuendig/corona/commits/linux-3734 --jq .sha) \
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
- The simulator uses a lot of CPU: the offscreen GL render loop is uncapped and
  llvmpipe has no frame limiter. `config.lua`'s `fps` limits the Lua loop, not the
  renderer. Cap it with `--cpus`, and stop it when you are done.

## Licence

The image build scripts here are MIT. Solar2D itself is MIT
([coronalabs/corona](https://github.com/coronalabs/corona)); the bundled Android
template, `Corona.aar` and web template come from the official Solar2D release
artifacts and carry their own terms.
