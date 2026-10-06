# Offscreen capture: three follow-ups, verified and designed

Status: design, 2026-10-06. Companion to `offscreen-capture-design.md`
(read that first). Verified against the local checkouts: corona fork
`linux-frame-tap` @ 309411d6, solar2d-mcp `video-tap` @ f1efc5f,
docker-solar2d `ci/solar2d-ref-input` @ 1413757.

Verification was by code reading plus small host-side measurements. Nothing
was run against the image (the simulator counts as heavy work on this host);
what that leaves unverified is listed at the end of each issue.

Summary of verdicts:

| # | Issue | Verdict | Recommendation |
|---|---|---|---|
| 1 | Relaunch/reload during recording untested | **Real, medium.** Every piece is unit-tested with fakes; the chain that actually runs on a relaunch (`_prepare_and_spawn` → `stop_tracked_simulators` → `take_finished_recording`, and the engine's context reload under a live tap) is never executed by any test. | Build it: one engine-level image test in the fork, one MCP chain test in solar2d-mcp, one CI job in docker-solar2d that runs both against the candidate image. |
| 2 | Per-frame allocation in the video tap | **Real, minor.** One `malloc` + zero-fill per *emitted* frame; measured cost ≈ 0.2–1.1 ms per frame at 1043×1409 to 1080×1939, i.e. about 1–3 % of one core at 30 fps, under the app's own 10–30 ms llvmpipe render. | Do not implement now. Design recorded below so it is a half-day change when a larger surface or a different allocator makes it matter. |
| 3 | UTF-8-unsafe text truncation in the input tap | **Real, low–medium.** `text` accepts up to 256 bytes, `PushText` delivers at most 31, a split codepoint becomes U+FFFD in the field, and the ack reports the requested byte count as "chars". | Implement: boundary-safe split into several `SDL_TEXTINPUT` events in one tick, UTF-8 validation at parse time, honest ack. Half a day plus tests. |

---

## Issue 1 — reload/relaunch during recording is untested

### Verification

**The engine claim holds by construction, untested.** The tap is created once
in `SolarApp::InitSDL` (`Rtt_LinuxApp.cpp:143`) and destroyed in
`~SolarApp` (`:78`). Every relaunch — menu, file watcher, or MCP — goes
through `SolarSimulator::LoadApp`, which replaces the context
(`Rtt_LinuxSimulator.cpp:111`, `fContext = new SolarAppContext(fWindow)`).
The three hook sites reach the tap through `app->GetVideoTap()`
(`Rtt_LinuxContext.cpp:444`, `:462`, `:479`), never through the context, so a
reload keeps streaming on the same FIFO, same writer thread, same sequence
counter. Two details matter for the test:

- The reload happens inside `PollEvents` (SolarEvent → `OnRelaunch`), before
  `advance()` in the same tick, so the staging buffer never straddles two
  contexts and no partial frame is committed.
- `SolarAppContext::LoadApp` → `SetSize` → `RecreateWindowForOffscreen`
  returns early when the size is unchanged (`Rtt_LinuxApp.cpp:170-178`), so a
  same-size reload does not swap the window and the recording does not end
  with "resized". A reload that changes `app.conf` w/h does swap, and the
  relay ends the segment — the documented v1 policy.

**The MCP fresh-spawn chain is real and reachable, untested end to end.**
`_prepare_and_spawn` (`run_project.py:1122-1145`) calls
`stop_tracked_simulators()` (`runtime.py:198-230`), which finalizes the
recording *before* killing the simulator, parks it in
`_unreported_recordings[project_dir]`, and the new launch picks it up via
`take_finished_recording`. `handle_stop_recording` (`video.py:670-697`) then
reports it with the relaunch note. Each link has a unit test, but:

- `test_stop_reports_recording_finalized_on_relaunch` hand-carries the dict
  from `take_finished_recording` into a hand-built launch; it never runs
  `_prepare_and_spawn`.
- Every test in `test_reload.py` mocks `_prepare_and_spawn` wholesale
  (`fake_prepare`), so no test has ever run the real sequence with a
  recording attached — including the ordering (finalize, then SIGTERM, then
  spawn) that the "loud finalization" claim depends on.
- No test uses the simulator binary. The `FakeTap` in
  `test_video_recording.py` is faithful to the wire format but cannot show
  that a *second process* can take over the same FIFO path: the first
  simulator dies by `killpg(SIGTERM)` (`runtime.py:148`) with no handler, so
  its destructor never runs and `.ready`/`.lock` are left stale. The new tap
  must win the (now free) flock and `rename` a fresh marker over the stale
  one (`Rtt_LinuxVideoTap.cpp:207-233`). That is correct by reading; nothing
  exercises it.

**The MCP in-place reload (`reload: true`) is a different outcome and is
also untested with a tap.** `_attempt_reload` (`run_project.py:1238`) touches
`main.lua` and does not touch `video_recording`, so if the engine reloads the
recording survives — matching validation item 7's first half. The task notes
that touching `main.lua` did *not* trigger a reload in earlier experiments.
I could not reproduce that or find a dead link by reading: the watcher adds
`IN_MODIFY` on the project directory (`Rtt_LinuxApp.cpp:653`), a rewrite via
`open(O_TRUNC)`+`write` produces `IN_MODIFY` with the file name, the handler
accepts any `*.lua` not starting with `.#` and relaunches when
`relaunchOnFileChange == "Always"` (`Rtt_LinuxSimulator.cpp:282-299`), which
is both the compiled default (`:87`) and what the MCP writes into the
homescreen `app.conf`. The usual cause of exactly this symptom is a bind
mount under Docker Desktop, where host-side writes do not raise inotify
events inside the container; writes from the same kernel (the MCP inside the
container) do. The test below settles this empirically rather than assuming
either way — and if it fails, the `reload: true` tool is dead in containers,
which is worth knowing on its own.

**Stated shape: correct, with one addition.** Two outcomes must be asserted
separately: (a) in-place reload → one continuous recording spanning the
reload, no segment break, drops accounted; (b) fresh-spawn relaunch → the
old recording is finalized, reportable from the new launch with the note,
*and* a new recording can start on the new simulator over the same FIFO path.
The addition is (b)'s second half: it is the only thing that proves the
marker/lock/FIFO reuse across processes.

### Design

Three layers, each living in the repository that owns the behaviour, all
parameterised by an image tag, all driven from docker-solar2d's
`test-actions.yml` because that is the only CI that has the image. The fork
already has the precedent for layer A: `platform/linux/test/native-input/run.sh
<image>` drives a project in the image through the input FIFO and asserts on
stdout.

#### A. Engine-level: `platform/linux/test/video-reload/` (corona fork)

Files: `run.sh <image>`, `main.lua`, `scene.lua`, `config.lua`.

- `main.lua` requires `scene.lua`, fills the screen with the colour
  `scene.lua` names, prints `[T] loaded <colour>` once up, and nothing else.
  `scene.lua` is one line (`return "red"`); rewriting it to `return "blue"`
  is a `*.lua` modification that both triggers the watcher and changes the
  pixels, so the test can prove *which* generation is on screen.
- `run.sh` copies the project into the container's own filesystem
  (`--entrypoint sh`, `cp -r /src /tmp/project && exec
  /usr/local/bin/entrypoint.sh simulate /tmp/project/main.lua`) so the
  reload trigger never depends on bind-mount inotify semantics. It sets
  `SOLAR2D_VIDEO_PIPE=/dev/shm/video.fifo` and
  `SOLAR2D_VIDEO_FPS=30`.
- Reader: `docker exec … python3 -` (the image ships python3 for the MCP)
  running a 40-line script that opens the FIFO, parses the 64-byte headers,
  and prints one line per frame: `seq w h time_ns centre_bgra` (centre pixel
  sampled from the payload; the payload is otherwise read and discarded).
  It keeps the fd open for the whole test — a reopen would hide the
  survival property.
- Sequence: wait for `[T] loaded red` and `.ready`; wait for ≥ 60 reader
  lines with the red centre; `docker exec` rewrites `scene.lua` to blue;
  wait for `[T] loaded blue`; wait for ≥ 60 further lines with the blue
  centre.
- Assertions (all on captured text, in the `expect` style of
  `native-input/run.sh`):
  1. `Loading project from:` appears exactly twice; `[VIDEOTAP] streaming`
     exactly once; `.ready` pid unchanged across the reload.
  2. The reader never saw EOF; `seq` is strictly increasing across the
     whole run; the gap total is reported and must be 0 under
     `--cpus 2` (a nonzero gap is a drop, which is legal but means the
     runner was starved — print it and fail, since it masks a stall).
  3. `w h` constant across the reload (same-size reload does not swap the
     window).
  4. Centre pixel is red for every frame before `[T] loaded blue` and blue
     for every frame after a 2-frame grace.
  5. Optional, for issue 2's regression: sample `VmRSS` from
     `/proc/<pid>/status` at 10 s and at the end; assert the delta is below
     one frame's size.
- Failure handling: on failure dump `[T]`, `[VIDEOTAP]` and
  `Loading project` lines plus the first and last 5 reader lines, as the
  native-input script does.

If assertion 1 fails because the second `Loading project from:` never
appears, the watcher is dead in this environment and the fallback trigger
is a menu-equivalent path (`PushEvent(sdl::OnRelaunch)` reachable from the
input tap as a `relaunch` command). That is a scope expansion and is not
designed here; the test's job is to tell us whether it is needed.

#### B. MCP chain: `tests/test_video_relaunch_integration.py` (solar2d-mcp)

`unittest`, not pytest — the image purges pip and has no pytest, and the
existing video tests are already `unittest.TestCase`. Skipped unless
`SOLAR2D_MCP_INTEGRATION_SIMULATOR` names an executable and `ffmpeg` and
`ffprobe` resolve; **never** skipped on the inotify question.

Fixture: `tests/fixtures/video_relaunch/{main.lua,config.lua}` — a 320×480
project whose fill colour cycles every frame (so x264 always has motion and
the frame count is honest) and which prints `[T] generation <n>` from a
counter in `system.TemporaryDirectory`, so the test can tell a reload from a
fresh process by the counter continuing versus restarting. `setUp` copies the
fixture to a temp dir (the MCP injects `require` lines into `main.lua`) and
points `HOME`, `SOLAR2D_MCP_RUNTIME_DIR` and `SOLAR2D_MCP_ARTIFACT_DIR` at
temp dirs via `os.environ` (the simulator reads `HOME` through
`GetHomePath`, `Rtt_LinuxUtils.cpp:99`, and `Popen` copies the environment,
so both sides agree on the homescreen `app.conf`). `config.get_simulator_or_detect`
is patched to the binary. `tearDown` calls `runtime.stop_tracked_simulators()`
and clears `_unreported_recordings`, like the existing tests.

Cases, each going through the real `run_project.handle`,
`video.handle_start_recording` and `video.handle_stop_recording`:

1. **Fresh-spawn relaunch finalizes loudly and the new tap takes over.**
   Launch → start recording → wait `recording["frames"] >= 30` → launch
   again (no `reload`) → assert the reply says `Launch path: fresh spawn`
   and a different PID; assert `running_projects[dir]["finished_video_recording"] is recording`
   and `"video_recording" not in` the new launch; assert `_tap_pid(ready)`
   equals the new PID (marker overwritten, stale lock won); stop → assert
   `finalized automatically when the simulator relaunched`, `finalized and
   verified`, probe `frames > 0`, `duration` within ±15 % of the recorded
   wall clock. Then start a second recording on the new launch, wait for
   30 frames, stop → verified. This is the cross-process FIFO reuse proof.
2. **In-place reload keeps one recording.** Launch → start → ≥ 30 frames →
   `run_project.handle({…, "reload": True})` → assert `Launch path:
   reload` (a fallback or timeout reply **fails** the test with the tool's
   text — that is the inotify verdict) → assert the same `video_recording`
   object is still attached and its relay thread alive → wait until
   `frames` has grown by ≥ 30 and `[T] generation` advanced → stop →
   `finalized and verified`, no `Segments:` line (no resize), `drops == 0`,
   probe frames ≥ 60.
3. **Relaunch latency with a recording attached.** Wrap case 1's second
   launch in a timer and assert it completes well inside
   `LAUNCH_TIMEOUT_SECONDS` (say < 12 s), which guards the budget problem in
   adjacent finding 2 below.
4. **Cross-project relaunch** (currently documents a defect, adjacent
   finding 1): record on project A, launch project B, call stop on A.
   Today this returns "No current Solar2D launch is tracked" although a
   finished MP4 exists. Write the test against the fixed behaviour and land
   it with the fix, or mark `expectedFailure` until then; do not leave the
   case out.

#### C. CI: a `simulator` job in `test-actions.yml` (docker-solar2d)

Alongside the `capture` job and pinned the same way
(`ghcr.io/chkuendig/solar2d:frame-tap-candidate` with the same "until a
release image carries them" comment):

```yaml
simulator:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v6
    - name: Fork test scripts
      uses: actions/checkout@v6
      with: { repository: chkuendig/corona, ref: linux-frame-tap,
              sparse-checkout: platform/linux/test, path: fork }
    - name: MCP source at the image's pinned commit
      run: echo "ref=$(sed -n 's/^ARG SOLAR2D_MCP_REF=//p' Dockerfile)" >> "$GITHUB_OUTPUT"
      id: mcp
    - uses: actions/checkout@v6
      with: { repository: chkuendig/solar2d-mcp, ref: ${{ steps.mcp.outputs.ref }}, path: mcp }
    - run: fork/platform/linux/test/native-input/run.sh "$IMAGE"
    - run: fork/platform/linux/test/video-reload/run.sh "$IMAGE"
    - name: MCP relaunch chain inside the image
      run: |
        docker run --rm --cpus 2 --memory 2g \
          -v "$PWD/mcp:/mcp:ro" -v "$PWD/out:/out" \
          -e PYTHONPATH=/mcp -e HOME=/tmp/home \
          -e SOLAR2D_MCP_RUNTIME_DIR=/tmp/rt -e SOLAR2D_MCP_ARTIFACT_DIR=/out \
          -e SOLAR2D_MCP_INTEGRATION_SIMULATOR=/usr/local/bin/Solar2DSimulator \
          --entrypoint python3 "$IMAGE" -m unittest tests.test_video_relaunch_integration -v
    - uses: actions/upload-artifact@v4
      if: failure()
      with: { name: simulator-logs, path: out }
```

`paths:` triggers gain `Dockerfile` (the job tests the image). The MCP ref is
read from the Dockerfile so the job can never drift from what the image
installs. The fork is checked out by branch because the image does not record
the fork commit it was built from (adjacent finding 6).

Locally the same three commands run against the local
`frame-tap-candidate` image; nothing in the harness is CI-specific.

### Effort

| Piece | Estimate |
|---|---|
| A. fork `video-reload` test | 0.5 day |
| B. MCP integration test + fixture | 1 day |
| C. CI job | 0.5 day |
| Settling the reload trigger if the watcher is dead in-container | 0–1 day, unknown until A/B run |

### Risks

- **Flakiness on shared runners.** llvmpipe at 320×480 is light, but x264
  and the relay compete for 2–4 vCPUs. Assert on counts and on the ±15 %
  duration bound only; never on absolute timings except the relaunch-latency
  guard, which has a wide margin.
- **The launch deadline swallows finalize** (adjacent 2): under load, case 3
  may fail for a reason that is a product defect, not a test defect. That is
  the point of the case; fix the budget rather than loosening the assertion.
- **Cross-repo pins.** The job tests the *candidate* image against the
  fork's branch head; a later fork push can make the scripts and the image
  disagree. Mitigation in adjacent 6.
- **Host-side runs** on Docker Desktop will fail A's reload if the project
  is bind-mounted — A deliberately copies the project into the container to
  avoid exactly that; keep it that way.

### Not verified

- Nothing was run against the image. The claims above are by reading.
- The "touch did not reload" observation: not reproduced, no dead link
  found; environment-dependent inotify is the leading hypothesis.

---

## Issue 2 — per-frame allocation in the video tap

### Verification

**Real, and precisely one allocation per emitted frame.** `StageFrame` sizes
the fill buffer with `fFill.data.resize(kHeaderSize + payload)`
(`Rtt_LinuxVideoTap.cpp:323`); `CommitFrame` moves it into the queue and
resets it with `fFill = Frame{}` (`:401-402`); the writer frees it when its
local `Frame frame` goes out of scope (`:528-570`). So each emitted frame
costs `malloc(n)` + a value-initialising zero-fill of `n = w·h·4 + 64` bytes
on the render thread, and a `free(n)` on the writer thread. Two non-costs
worth recording:

- A staged-but-not-committed frame (pacing says not yet, `:376-380`) keeps
  its buffer; the next `resize` to the same size is a no-op, so the fps cap
  and queue-full skips allocate nothing.
- `OpenFifo`'s `fQueue.clear()` (`:431`) frees queued frames; that is a
  reconnect event, not per frame.

**Measured cost** on this host (Xeon E3-1265L v2, DDR3; `dd` from
`/dev/zero` into a resident buffer runs at 7–8 GB/s, a fair memset proxy).
The C++ path itself could not be measured here (no compiler on this host,
and writing a benchmark file was outside the brief), so Node's zero-filled
`Buffer.alloc` stands in for `malloc` + value-init and `fill(0)` for the
zero-fill alone:

| Surface (window + menu) | Bytes | alloc + zero (proxy) | zero-fill only | memcpy (≈ the readback's own write) |
|---|---|---|---|---|
| 320×499 | 0.6 MB | 0.14 ms | 0.03 ms | 0.05 ms |
| 640×1409 | 3.6 MB | 0.46 ms | 0.18 ms | 0.43 ms |
| 1043×1409 | 5.9 MB | 0.71 ms | 0.23 ms | 0.81 ms |
| 1080×1939 | 8.4 MB | 1.10 ms | 0.43 ms | 1.25 ms |

Interpretation for the real tap under glibc (the image is Debian bookworm):
after the first `free` of an mmapped chunk, glibc raises its dynamic mmap
threshold to that size (up to 32 MB), so steady-state 6–8 MB allocations come
from the heap without page faults and the recurring cost is the zero-fill
column, 0.2–0.4 ms. The proxy's "alloc + zero" column is the pessimistic
bound (every allocation faulting fresh pages), which the tap would only pay
on its first frames, under `MALLOC_MMAP_THRESHOLD_`, or on a musl base. At
30 fps that is **0.7 % (steady state) to 2.1 % (worst case) of one core at
1043×1409, and 1.3 % to 3.3 % at 1080×1939** — against a `glReadPixels`
that moves the same bytes once more and an app render that takes 10–30 ms
per frame under llvmpipe at those sizes.

**Verdict: real but negligible at the sizes the image is used at.
Recommendation: do not implement now.** Revisit if any of these appear: a
surface ≥ 2× the largest above, a non-glibc base image, allocator contention
in a profile, or a second consumer of the fill buffer (render-on-demand). The
design below makes that a half-day change. If a zero-cost improvement is
wanted meanwhile, replacing the vector with a default-initialised
`std::unique_ptr<uint8_t[]>` removes the zero-fill (the only recurring cost in
steady state) in three lines without any pool; it is not worth a separate
change on its own.

### Design (recorded for when it is needed)

**Ownership.** Every buffer is in exactly one place at any time: the render
thread's `fFill`, the bounded `fQueue`, the writer's in-flight `frame`, or
the pool. Steady state has four buffers alive (1 + 2 + 1); the pool holds
whichever of those are momentarily idle. Nothing is shared, so no new
synchronisation: pool operations happen under the existing `fMutex` at the
points that already take it.

**Data.** `std::vector<std::vector<uint8_t>> fPool;` plus
`static const size_t kMaxPooledBuffers = kMaxQueuedFrames + 2;` (4). Keep
`struct Frame { std::vector<uint8_t> data; }`.

**Flow.**

- `CommitFrame` (enqueue branch, `:398-404`): after
  `fQueue.push_back(std::move(fFill))`, take a buffer back: if
  `!fPool.empty()` then `fFill.data.swap(fPool.back()); fPool.pop_back();`
  else leave `fFill` empty (the next `resize` allocates — this is the only
  allocation path left, and it runs at most four times per size).
- Writer (`WriterLoop`, after `WriteAll` regardless of success): under
  `fMutex`, `if (fPool.size() < kMaxPooledBuffers) fPool.push_back(std::move(frame.data));`
  otherwise let it free. Return happens even on EPIPE — the bytes are gone
  either way.
- `OpenFifo`'s `fQueue.clear()` becomes "move every queued `data` into the
  pool, then clear", under the same lock it already holds.
- `StageFrame`'s `resize` stays. On a recycled buffer of the same size it
  is a no-op (no zero-fill); on a larger-capacity buffer after a shrink it
  is a free shrink; on a smaller buffer after a grow it reallocates and
  zero-fills only the grown tail once.

**Resize invalidation.** Track `fLastStageBytes` on the render thread. When
`StageFrame` computes a different byte count, take `fMutex` and
`fPool.clear()` before resizing, so a shrink does not pin four oversize
buffers for the rest of the run and a grow does not hand out undersized
ones to be regrown one by one. Buffers still in the queue or in flight carry
their own header w/h (already true) and return to the pool afterwards with
the old capacity; they are at most three, are reused at the new size by
`resize`, and the next size change clears them. No writer-side size check
is needed.

**Interaction with the bounded queue.** Unchanged. The queue bound (2) still
decides drops; the pool never blocks and never grows the number of live
buffers past four, so memory is bounded exactly as today (≈ 34 MB at
1080×1939) and lower on average because the four buffers are no longer
churned through the allocator.

**Teardown.** `~LinuxVideoTap` joins the writer first (already), then the
pool's vectors are destroyed with the object.

### Tests

The fork has no C++ test target (`CMakeList.txt` has no `enable_testing`).
Two options; recommend both, the first shared with issue 3:

1. **Extract the pool into a header-only `Rtt_LinuxFramePool.h`** (take /
   give-back / clear / cap, no GL, no threads inside) and add a
   `Solar2DTapTests` executable under
   `option(SOLAR2D_TAP_TESTS OFF)` with `add_test`. Plain asserts, no
   framework. Cases: take from empty allocates; give-back beyond cap is
   dropped; clear on size change; a buffer taken after same-size give-back
   has unchanged capacity and `resize` does not reallocate (assert
   `data()` pointer stable).
2. **Behavioural, in the image:** the `VmRSS` sample in
   `video-reload/run.sh` (issue 1, assertion 5) and validation item 13
   (300 s recording, flat RSS, drop counter equals the relay's seq-gap
   count) are the end-to-end regression for this change.

### Effort

0.5 day implementation, 0.5 day for the header split and test target (the
target is shared with issue 3, so count it once).

### Risks

Low. The two real hazards — a buffer returned while still referenced, and
oversize buffers pinned after a shrink — are closed by moving (never
copying) and by `fPool.clear()` on size change. The change touches the one
hot path in the tap; the image test from issue 1 is the gate.

### Not verified

The C++ allocation cost itself; the figures are proxies plus the glibc
threshold argument. If someone wants the exact number, a 20-line benchmark
built in the compile stage of the image settles it in a minute.

---

## Issue 3 — UTF-8-unsafe text truncation in the input tap

### Verification

**Real.** The chain:

- The reader accepts `text <string>` with up to 256 bytes of payload
  (`Rtt_LinuxInputTap.cpp:257`, `line.size() < 5 + 257`), keeps the whole
  string in `cmd.arg`, and never inspects its encoding.
- `PushText` (`:392-400`) does `snprintf(e.text.text, sizeof(e.text.text),
  "%s", …)` — `SDL_TEXTINPUTEVENT_TEXT_SIZE` is 32 in SDL2 (bookworm ships
  2.26.5), so at most 31 bytes are delivered and the cut is at a byte, not a
  codepoint, boundary.
- The only consumer is ImGui's SDL backend
  (`imgui/imgui_impl_sdl.cpp:276-279`, `io.AddInputCharactersUTF8`). Its
  decoder (`imgui/imgui.cpp:1831-1875`, vendored 1.87 WIP 18616) treats a
  sequence truncated by the NUL as invalid and yields
  `IM_UNICODE_CODEPOINT_INVALID` (U+FFFD), consuming the partial bytes. So
  a field receives the first ≤ 31 bytes with a trailing "�" when a
  multibyte character straddles the cut, and the rest of the text is lost.
- The ack says `dispatched text (%d chars)` with `cmd.arg.size()` — the
  requested byte count, labelled "chars", regardless of what was pushed
  (`:509`).
- Invalid UTF-8 input is pushed as-is and becomes one U+FFFD per bad byte.

**Stated shape: correct.** Three adjacent facts shape the design:

- The native field's buffer is `fValue[1024]`
  (`Rtt_LinuxTextBoxObject.h:64`); ImGui's `InputText` drops characters
  beyond capacity, and filters such as `CharsDecimal` drop others. The tap
  cannot see any of that — the ack is dispatch-level by design and must say
  so.
- `DispatchEditing` (`Rtt_LinuxTextBoxObject.cpp:343-373`) diffs the old and
  new buffer once per `Draw` and fires one `editing` event with
  `newCharacters` = the inserted run. Several `SDL_TEXTINPUT` events applied
  in the same frame therefore produce **one** `editing` event carrying the
  whole string — the same thing a paste or an IME commit produces on a
  device.
- ImGui trickling (`imgui.cpp:7861-7866`): char events are applied in the
  frame they are queued unless a key or mouse event was queued earlier in
  that frame, in which case they move to the next frame. Chars never
  trickle *among themselves*. A `text` right after a `key` in the same tick
  is delivered one frame later; still whole, still one event.

### Design

**Validation and splitting are string work, so they belong on the reader
thread** (the file's stated rule: parse on the reader, dispatch on the main
thread).

- New header `platform/linux/src/Rtt_LinuxUtf8.h` (header-only, no SDL, so
  it is unit-testable):
  - `bool Utf8Validate(const std::string& s, size_t* badOffset, size_t* codepoints)` —
    rejects continuation bytes without a lead, truncated sequences,
    overlongs (C0/C1, E0 80–9F, F0 80–8F), surrogates (ED A0–BF), and
    anything above U+10FFFF (F4 90+, F5+). Counts codepoints on success.
  - `std::vector<std::string> Utf8SplitChunks(const std::string& s, size_t maxBytes)` —
    greedy split at lead-byte boundaries, each chunk ≤ `maxBytes` bytes,
    never cutting inside a sequence. Precondition: valid input.
- Reader (`:257-261`): after the prefix check, run `Utf8Validate`; on
  failure `[INPUT] ignored: text … (invalid UTF-8 at byte N)` and skip, in
  line with the malformed-line policy. Store `codepoints` in the command
  (new `size_t count` field) so the ack does not recount on the main thread.
  The 256-byte line cap stays; longer text is several `text` commands, and
  the header comment says so.
- `PushText`: `for (const std::string& chunk : Utf8SplitChunks(text,
  SDL_TEXTINPUTEVENT_TEXT_SIZE - 1))` push one `SDL_TEXTINPUT` per chunk,
  same `windowID`, in order, **all within the same `DispatchPending`
  call**. Do not spread chunks over ticks: that would turn one logical input
  into N `editing` events and change listener behaviour (the numeric-code
  field in `native-input/main.lua` is exactly the kind of listener that
  cares). Check `SDL_PushEvent`'s return (≤ 0 on a full queue) and stop at
  the first failure, remembering how many went out.
- Ack: `[INPUT] dispatched text (%zu codepoints, %zu bytes, %d events)`, and
  on a push failure `[INPUT] dispatched text (… , %d of %d events)` so the
  driver sees a partial delivery. Keep the `dispatched text` prefix: the
  existing driver script does not grep the ack, but external drivers per the
  README may.
- Header comment in `Rtt_LinuxInputTap.h`: `text` is ≤ 256 bytes of valid
  UTF-8 per command, delivered as one insertion; the field's own capacity
  (1023 bytes) and input filters are outside the ack's knowledge.

### Tests

1. **Unit, `Solar2DTapTests` (shared with issue 2):** table-driven over
   `Utf8Validate`/`Utf8SplitChunks`:
   - ASCII of 31, 32, 33 and 256 bytes → chunk count 1, 2, 2, 9; every chunk
     ≤ 31 bytes; concatenation equals input.
   - 2-, 3- and 4-byte characters positioned so the sequence starts at byte
     29, 30 and 31 (ü, €, 😀) → the chunk ends before the character; no
     chunk contains a partial sequence (check each chunk validates).
   - Invalid inputs: lone continuation `80`, truncated lead at end `E2 82`,
     overlong `C0 80`, surrogate `ED A0 80`, out of range `F4 90 80 80`,
     `F5` → validate fails with the right offset.
2. **End to end, extend `platform/linux/test/native-input/`:** add a third
   field (`long`) to `main.lua`; in `run.sh` send
   - a 40-character ASCII string → expect one
     `[T] long editing … new=<all 40>` and the ack
     `dispatched text (40 codepoints, 40 bytes, 2 events)`;
   - `"ääääääääääääääää€x"` (16×2 + 3 + 1 = 36 bytes, with `€` starting at
     byte 32 and `ä` at byte 30 straddling the old cut) → `new=` equals
     the full string, ack `(18 codepoints, 36 bytes, 2 events)`;
   - one emoji after 29 ASCII bytes → full string, 2 events;
   - `printf 'text \377\n'` → `[INPUT] ignored: text` and **no** `[T] long
     editing` line.
   The `send` helper already routes through `printf '%s\n'` inside the
   container, so multibyte text passes untouched; the invalid case uses an
   octal escape. Because `text` may trickle one frame behind a preceding
   `key`, the script asserts on presence, never on same-frame ordering.

### Effort

0.5 day implementation (header, reader validation, `PushText`, ack,
comments), 0.5 day tests; plus 0.5 day for the shared `Solar2DTapTests`
target if issue 2's option 1 has not landed first.

### Risks

Low. The ImGui decoder and trickle rules were read in the vendored copy, not
assumed from a newer release. The one behavioural change visible to drivers
is the ack text; the one visible to projects is that long text now arrives
whole — which is what the field would have received from a real keyboard
paste.

### Not verified

`SDL_TEXTINPUTEVENT_TEXT_SIZE == 32` is from SDL2 knowledge (the headers
are not on this host); it has been 32 in every SDL2 release.

---

## Adjacent findings that affect these designs

1. **Cross-project relaunch loses the report.** `stop_tracked_simulators`
   parks the finished recording under the *old* project's directory
   (`runtime.py:216-218`); launching a different project leaves it there,
   and `handle_stop_recording` on the old project returns "No current Solar2D
   launch is tracked" because `running_projects` was cleared
   (`video.py:649-666`). The MP4 exists; the report is unreachable until
   that project is launched again, and `shutdown_runtime` deletes its log.
   Fix: have `handle_stop_recording` fall back to
   `take_finished_recording(project_dir)` before erroring. Issue 1, case 4.
2. **The launch deadline includes finalization.** `_prepare_and_spawn`
   runs `stop_tracked_simulators()` — relay join up to 10 s plus encoder
   wait up to 8 s — inside the 20 s `LAUNCH_TIMEOUT_SECONDS` budget
   (`run_project.py:1407-1424`). A slow or wedged encoder can make the
   relaunch time out and `abandon` kill the *new* simulator while the tool
   reports a launch timeout. Start the deadline after the stop returns, or
   finalize off the critical path and carry the recording. Issue 1, case 3.
3. **`native-input/run.sh` runs in no CI** today (the fork's `build.yml` is
   the upstream macOS matrix). The proposed `simulator` job runs it.
4. **`reload: true` depends on inotify** in the simulator's mount
   namespace; if issue 1's tests show it dead in containers, both the MCP
   tool and the engine-level reload test need another trigger (a `relaunch`
   input-tap command is the obvious candidate). Not designed here.
5. **SIGTERM leaves stale tap files.** The simulator has no handler, so
   `.ready` and `.lock` survive the kill; the next tap wins the free flock
   and renames a fresh marker, and the MCP's pid check
   (`video.py:134`) ignores the stale one meanwhile. Correct by reading;
   issue 1 case 1 is the first test of it.
6. **The image does not record the fork commit it was built from.**
   `publish.yml` resolves `SOLAR2D_REF_SHA` but the Dockerfile sets no
   label from it, so CI cannot check out the fork's test scripts at exactly
   the built revision. Add `LABEL io.solar2d.fork.revision=$SOLAR2D_REF_SHA`
   in the runtime stage (one `ARG` re-declaration, one line).
7. **The MCP still drives touch through the Lua control-file path**
   (`tools/touch.py`); the input tap has no MCP consumer yet, so issue 3
   only affects direct FIFO drivers today. The design document's "control
   file path moves onto the tap and is deleted" is still open work and is
   not part of these three items.
