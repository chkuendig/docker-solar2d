# Offscreen capture: design for the Solar2D frame tap and the X-free pipeline

Status: v3 — implemented; engine patch validated offscreen end-to-end on the
`linux-frame-tap` branch (corona fork), MCP relay on `video-tap` (solar2d-mcp).
Scope: one engine patch (corona fork), one server change (solar2d-mcp), one
image change (docker-solar2d), and the consumer-side capture flow. Written to
be upstreamable to `coronalabs/corona` and isolated to `platform/linux`.

## Goals

1. Video recording from the headless simulator **without any X server**
   (today: `ffmpeg -f x11grab` against Xvfb).
2. The engine change is small, default-off, Linux-only, simulator-only, and
   clean enough to offer upstream as "headless CI capture support".
3. Once the tap + MCP rework land, the Docker image drops Xvfb/x11-utils
   entirely and every simulator path goes through `SDL_VIDEODRIVER=offscreen`
   (EGL pbuffer + llvmpipe).

Non-goals: render-on-demand (later, can reuse the tap's readback);
`media.playSound` on Linux (separate upstream-able fix); audio (appendix —
image-level only).

## Engine patch: `SOLAR2D_INPUT_PIPE` (input injection)

`platform/linux/src/Rtt_LinuxInputTap.{h,cpp}`, simulator target only, same
conventions as the video tap (env-gated, default off, flock + ready marker,
env consumed so children cannot inherit the channel, ownership by `SolarApp`).

### Command grammar — one command per line written to the FIFO

| Command | Meaning |
|---|---|
| `tap <x> <y>` | tap at **content** coordinates |
| `wtap <x> <y>` | tap at raw window pixels (y includes the menu bar) |
| `drag <x1> <y1> <x2> <y2> [ms]` | press, frame-paced move over ms (default 300), release; content coords |
| `key <name>` | SDL key name: `return`, `escape`, `a`, … |
| `text <string>` | SDL text input (needs a focused native field) |

- Content coordinates are converted through the display's own
  `ContentToScreen` transform with the menu height added back — the exact
  inverse of what `LinuxMouseListener` does on the way in, so injected events
  are indistinguishable from real ones downstream: listener → hit-testing →
  native focus. This is the headless equivalent of an OS-level tap; Lua-side
  handler dispatch bypasses that pipeline and is not this.
- Every pushed SDL event carries the correct `windowID` — the poll loop
  filters on it.
- **Ack semantics: commands are fire-and-forget from the writer's
  perspective** — writing to the FIFO only queues the command. Each dispatched
  command prints one `[INPUT] ...` line to stdout, at most one frame later.
  Application-level waits stay with the project's own stdout markers; the
  `[INPUT]` line is the dispatch-level ack if one is needed.
- Malformed lines are logged (`[INPUT] ignored: ...`) and skipped, never
  fatal. The queue is bounded (256); overflow drops with a log line.
- EOF is normal on this FIFO (every `echo tap 150 250 > fifo` opens and
  closes it); the reader reopens and keeps serving. Probe `<path>.ready`,
  never the FIFO, for capability/liveness.

This channel is intended to become the **only** input path — MCP's current
Lua control-file injection moves onto it, and the control-file path is deleted
outright (dead, not deprecated-but-alive).

## Prerequisite fix: the offscreen surface never resizes (review B1)

**Confirmed from SDL 2.26 source**: the offscreen driver creates its EGL
**pbuffer** once, in `OFFSCREEN_CreateWindow`, at the window's creation size,
and implements no `SetWindowSize`. The simulator creates its window at 0×0
(`Rtt_LinuxApp.cpp`) — clamped to 1×1 — and only later calls
`SDL_SetWindowSize`, which is a no-op for the surface. The default framebuffer
therefore stays 1×1 under offscreen. `display.save` never noticed because
`Display::Capture` renders into its own FBO.

**Implemented remedy**: when the video driver is offscreen and `SetSize` sees a
different size, `SolarApp` creates a replacement window at the target size and
does `SDL_GL_MakeCurrent(newWindow, existingContext)`, then re-initializes only
ImGui's SDL backend. **The GL context survives** — an earlier draft destroyed
and recreated it, which orphaned every GL object the runtime owns (programs,
textures) and left a simulator that rendered its menu bar and nothing else.
Keeping the context makes the swap transparent to the renderer; the live
`SolarAppContext` is handed the new window pointer
(`SolarAppContext::SetWindow`) since it holds its own copy for swaps/titles.

The tap takes its bounds from the actual EGL surface (`eglQuerySurface`),
clamped, never trusting `SDL_GL_GetDrawableSize`. Readback goes to `GL_FRONT`
on single-buffered pbuffer contexts (probed once at first use; `GL_BACK` is
silently accepted but reads black there). Note for docs: it is an EGL
**pbuffer**, not a surfaceless context.

## Why a FIFO frame tap

- The engine has no movie/frame-stream infra. `Display::Capture()` re-renders
  the whole scene into a fresh FBO per capture — fine for stills, 2× render
  cost for video; that is the ceiling of any Lua-level approach.
- Every presented frame converges on `SolarAppContext::Flush()`
  (`platform/linux/src/Rtt_LinuxContext.cpp`), after ImGui, before
  `SDL_GL_SwapWindow`, GL context current. But `Flush()` also runs during
  `Display::Capture`'s re-render (`Rtt_Scene.cpp:376`), so the tap must not
  commit per `Flush()` — see "commit point".
- Under llvmpipe the back buffer is already CPU memory; `glReadPixels` is a
  memcpy (but it is a sync point for llvmpipe's threaded rasterizer — skipping
  it when the queue is full is a real win, not just a byte saving).
- LD_PRELOAD on `eglSwapBuffers` rejected: nothing off-the-shelf supports the
  offscreen driver, and we own the fork.

## Engine patch: `SOLAR2D_VIDEO_PIPE`

New files `platform/linux/src/Rtt_LinuxVideoTap.{h,cpp}`. **Listed only in the
simulator target** (`CMakeList.txt`), not the player — a shipped Linux game
must not grow an env-triggered frame streamer (review S10). A compile
definition gates the hook sites so player builds have no reference at all.

| Env var | Meaning | Default |
|---|---|---|
| `SOLAR2D_VIDEO_PIPE` | absolute path of a FIFO to stream framed BGRA to | unset = feature off |
| `SOLAR2D_VIDEO_FPS` | cap on frames emitted per wall-clock second | runtime fps |

Validation at startup: path must be absolute, fps must parse; otherwise log
once and disable.

### Wire format — self-describing, versioned (review B2)

Every frame carries a fixed 64-byte header, then payload:

```
magic     u32   'S2VT'
version   u16   (1)
headerlen u16   (64)
width     u32
height    u32
stride    u32   (= width * 4)
fourcc    u32   'BGRA' (bgra byte order; consumer may read as bgr0 — alpha is meaningless)
bottom_up u8    (1; GL row order)
seq       u64   monotonic per process
time_ns   u64   CLOCK_MONOTONIC at capture
reserved  …     zero
```

The consumer can detect misalignment (magic), size changes (per-frame w/h),
and dropped frames (seq gaps). **No sidecar carrying dimensions exists** —
that design deadlocked (engine waits for reader, MCP waits for sidecar before
spawning ffmpeg) and raced across resizes.

### Marker file — capability + liveness

At startup (env set, path checks passed) the tap writes `<path>.ready`
(containing pid + protocol version), kept for the process lifetime and removed
on exit. This is what the MCP probes — **never** the FIFO itself, because any
open of the FIFO connects a reader and starts the stream (review S9).

### Ownership and lifetime (review B3)

The tap is owned by **`SolarApp`** (process lifetime), created once after
`InitSDL`, not by `SolarAppContext` — every reload/relaunch constructs a new
context (`Rtt_LinuxSimulator.cpp:111`), which would otherwise kill the tap and
end every recording, and briefly overlap two writers on one pipe. `Flush()`
reaches the tap through `app`.

### Commit point (review S5)

`Flush()` only *stages*: it marks the tap's fill buffer dirty (rendering into
FBO 0 happened; extra Flushes from `Display::Capture` just re-mark). The
readback + enqueue commit happens **once per tick, at the end of
`SolarAppContext::advance()`** — the last presented frame of the tick wins, and
screenshots taken mid-recording produce no extra or bogus frames.

### Threading, pacing, backpressure (reviews S2, S6, B4, B5)

Three buffers: one being filled (readback), one queued, one in flight to the
writer. Each buffer owns its w/h/seq/time copy — the writer never reads shared
size state.

- **Render thread**: when the queue is full, skip the `glReadPixels` entirely.
  Otherwise readback into the fill buffer, enqueue, swap.
- **Pacing**: accumulator (`next_emit += 1/fps`, half-interval slack, hard
  reset if fallen > 2 intervals behind) — the naive "≥ 1/fps since last emit"
  rule aliases against the main loop's truncated millisecond sleeps and yields
  ~15–20 fps.
- **Timestamps**: every frame carries `time_ns` (capture time). Consumers
  produce wall-clock-faithful output (below). Dropped frames therefore never
  compress the timeline.
- **Writer thread**:
  - `pthread_sigmask(SIG_BLOCK, {SIGPIPE})` first thing — EPIPE is returned
    from `write()`, no process-wide disposition is ever touched (review S1).
  - `open(O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)`; `ENXIO` (no
    reader) → wait on an eventfd (200 ms) and retry. Connected →
    `poll(POLLOUT | eventfd)`; loop short writes and `EINTR`.
  - Reader disappears → `EPIPE`/`POLLERR` → close, re-enter the retry loop.
    While idle with a *connected-but-silent* pipe, poll for `POLLERR` so a
    stale tail cannot leak to a new reader (review S3).
  - Shutdown: signal the eventfd; join is unconditional and prompt (no timed
    join, no detach — `std::thread` has neither, review S2). A SIGSTOPped
    reader cannot hang exit because writes are non-blocking polled.

### Path hardening (review S4)

- `mkfifo(path, 0600)`; if the path exists, `open` must satisfy `O_NOFOLLOW`,
  `fstat` → `S_ISFIFO` and `st_uid == geteuid()`, else log once and disable
  (a regular file would be written at ~180 MB/s; a symlink would clobber its
  target).
- `flock(LOCK_NB)` on `<path>.lock`: a second tap on the same path disables
  itself rather than interleaving >`PIPE_BUF` writes.
- `O_CLOEXEC` everywhere, and `unsetenv("SOLAR2D_VIDEO_PIPE")` after the tap
  reads it — the simulator spawns children via `system()` (built apps, adb,
  xdg-open) which must neither hold the write end nor become second writers.
- Optional `F_SETPIPE_SZ` to 1 MB: a 6 MB frame becomes ~6 poll wakeups
  instead of ~96.

### GL state around the readback (review S7)

Bind `GL_READ_FRAMEBUFFER` 0 and `GL_PIXEL_PACK_BUFFER` 0, `glReadBuffer(GL_BACK)`,
read, restore all three. Bounds = real EGL surface size, clamped.

### Resize (review S8)

A size change (which only happens under remedy above) ends the current segment:
the next frame simply carries the new w/h — the consumer sees it per frame.
The MCP's policy for v1: a size change mid-recording finalizes the MP4 at the
old size and returns both the path and an explicit "recording ended: window
resized" message. Padding/scaling across segments is deliberately out of scope.

### Sequence numbers (validated in implementation)

Seq is assigned **at commit** (per emitted frame), not at staging: a consumer's
seq gap then always means "the tap dropped this frame under backpressure" and
never "the fps cap skipped a stage". The two are different facts; only the
first is a problem. The relay counts drops this way and the engine's own drop
counter must agree (validation item).

### What the patch deliberately does not do

No color conversion, no flip (payload is GL bottom-up rows; consumer `vflip`s),
no encode, no Lua API, no config surface. Framed raw bytes + one ready-marker.
Every smart bit lives in the consumer, testable without rebuilding the engine.

## solar2d-mcp: relay-based recording

`tools/video.py` keeps its lifecycle scaffold; the input path becomes:

- **Launcher** (`run_project.py`) builds an explicit env for the simulator:
  `SOLAR2D_VIDEO_PIPE=$SOLAR2D_MCP_RUNTIME_DIR/video.fifo` (today `Popen`
  passes no env at all).
- `start_recording`:
  1. Check `<pipe>.ready` exists (capability probe that never touches the
     FIFO; its absence on a fresh runtime or old engine → the old
     "recording unsupported on this runtime" message, within a second — no
     8 s hang).
  2. Start a **relay thread**: it `open()`s the FIFO itself, parses frame
     headers, and `os.splice()`s payloads into ffmpeg's stdin. The relay owns
     size changes (reports them), drop counting (seq gaps — see the sequence
     note above), and alignment.
  3. ffmpeg: `-f rawvideo -pixel_format bgr0 -video_size WxH` taken from the
     **first frame's header** (the relay spawns ffmpeg lazily, on frame one),
     `-framerate` from the requested fps, `-i pipe:0`, then
     `-vf vflip,crop=…,format=yuv420p`, `-use_wallclock_as_timestamps 1
     -fps_mode cfr -r <fps>` on the output side (a 60 fps app recorded at 30
     yields a 30 s video for 30 s of wall clock, with duplication exactly
     where frames were dropped — review B4), and **fragmented MP4 output**
     (`-movflags +frag_keyframe+empty_moov+default_base_moof`, not
     `+faststart`) so a recording survives a SIGKILL of the whole run —
     harness hang-detectors kill the job, and that recording is the evidence
     wanted. Encode otherwise unchanged (`libx264 ultrafast crf 20`).
  4. `bgr0` (alpha is meaningless).
- `stop`: signal the relay (which closes ffmpeg's stdin → clean finalize).
  ffmpeg never blocks in `open()` because only the relay touches the FIFO.
- **Relaunch semantics**: `stop_tracked_simulators` finalizing on relaunch is
  made loud — the launch dict carries the finished recording so
  `stop_video_recording` reports it instead of "no recording active".
- `get_simulator_screenshot` untouched (stills stay on `display.save`).

## docker-solar2d

1. **Slimming** (staged locally, Android+HTML5 validated against the published
   image; note `build.settings` is required for Android builds): drop
   GTK/WebKit (~170M; Linux webview is a stub), `mesa-utils`, system lua,
   duplicate Resources COPY (symlink), SDK `cmdline-tools`+`platform-tools`
   (~170M; the template's `setup.sh` only touches licences), Gradle dist
   `docs/`+`src/` (~369M), pip cache + `python3-pip` purge. Stale comment
   "MCP: stitches recorded frames into an MP4" updated.
2. **Offscreen image-wide**: `ENV SDL_VIDEODRIVER=offscreen` (SDL2 does not
   pick offscreen on its own; setting it only in `simulate` misses simulators
   the MCP spawns under `mcp`/`session`/`docker exec`). `ENV DISPLAY=:99`
   removed once Xvfb goes.
3. **Xvfb removal is coupled to the MCP pin**: the image PR that pins the new
   `SOLAR2D_MCP_REF` deletes `xvfb`, `x11-utils`, `start_xvfb`, and
   `ENV DISPLAY`. `runtime` becomes `exec sleep infinity` (today it is only
   `wait "$XVFB_PID"`); the `session` `xdpyinfo` readiness check is **dropped**
   (offscreen needs no warm-up; the previously suggested lock-file check was
   meaningless — `simulator.lock` is never deleted).
4. **`capture` command + action** (one-shot, no MCP): pin window geometry via
   sandbox `app.conf`, pin the content box by patching `config.lua` on a
   scratch copy, append the generic delayed-capture hook to `main.lua`, run
   offscreen, validate the PNG (magic/IEND/IHDR/min-size), write to `/output`.
   Action inputs: `project`, `output`, `label`, `screen` (WxH), `delay-ms`,
   `env` (multiline `KEY=VALUE` list, forwarded with `-e`), `image`.
   Downstream keeps only its scene hooks and fixtures.
5. `ALSOFT_DRIVERS=null` in the image so `audio.*` works at all (appendix).

## Audio appendix (image-level, no engine change)

`audio.*` is currently a silent no-op in the container (no sound device;
openal-soft excludes its null backend from default selection → `alcOpenDevice`
fails → ALmixer init fails).

1. `ALSOFT_DRIVERS=null` → audio API becomes functional (silent).
2. Later, optional: PulseAudio daemon + null-sink in the runtime container;
   `ffmpeg -f pulse -i <sink>.monitor` muxed into the same MP4. In-engine
   OpenAL loopback in vendored ALmixer documented as the fallback.

## Validation checklist

Order matters: colors and geometry first (the fork's history of channel bugs),
then semantics, then hostile cases.

1. **B1 remedy**: real EGL surface size after `SetSize` under offscreen; after
   a rotation/skin change. Read a known-red pixel at (w−1, h−1).
2. **Colors**: validated — solid red rect switching to blue on an injected
   tap; tap frames sample (255,0,0) → (0,0,255) at content (15,15) through
   the reader. Validate against known colors, **not** `display.save` (that
   comparison leans on a fork commit upstream lacks).
2b. **Input injection**: validated — `tap 150 250` (content) dispatched as
   window (150,269), app's button handler received began/moved/ended at
   (150,250), state change visible in the video stream.
3. Screenshots mid-recording (`display.save`, MCP screenshot tool) produce no
   duplicate/garbage frames.
4. Duration honesty: 30 s wall clock at `--cpus=0.5`, 60 fps app, fps=30 →
   ~30 s video.
5. Pacing: 30 fps steady under `--cpus=1` (accumulator, not aliased ~15).
6. Reader churn: stop→start within one frame interval at low fps; no stale
   tail, header magic aligns.
7. Reload in place and fresh `run_solar2d_project` mid-recording: recording
   survives reload (tap is process-owned); relaunch finalizes loudly.
8. Exit prompt (<1 s) with no reader, with a reader, with a SIGSTOPped
   reader; `os.exit()` and crashes leave nothing that fools the next start
   (ready-marker gone, FIFO reusable).
9. Children: a built app / `xdg-open` inherit neither fd nor env var.
10. SIGKILLed ffmpeg: writer gets EPIPE, simulator survives, disposition of
    any preinstalled SIGPIPE handler untouched.
11. No reader for 10 min: zero CPU, no probe side effects.
12. X11 driver path still works (guards regression; the tap is driver-agnostic).
13. 300 s recording: flat RSS, drop counter == relay's seq-gap count.
14. Old image (no tap): clean "unsupported" within 1 s.
15. Build: simulator target has the tap; player target builds without it.
16. Image-level: Android + HTML5 builds post-slimming (done — APK+AAB and
    HTML5 verified against the published image base).
