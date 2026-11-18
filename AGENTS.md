<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Project Overview

`bb_camera_v4l` is a Beam Bots camera driver for Linux V4L2 devices. One
module, `BB.Camera.V4L`, is both a `BB.Sensor` and a `BB.Camera`; everything
else in `lib/` exists to make that module's job tractable.

Capture lifecycle is **not** this package's decision. `bb_camera`'s
`BB.Camera.Hub` refcounts consumers and tells the driver when to start and
stop, so there is one capture per camera no matter how many consumers there
are. Do not add a second path that starts capture.

## Build and Test Commands

```bash
BB_VERSION=local mix check --no-retry        # everything
BB_VERSION=local mix test                    # no camera and no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg   # also runs ffmpeg for real
```

`BB_VERSION=local` resolves `bb` and `bb_camera` from the sibling checkouts.

## Architecture

| Module | |
|---|---|
| `BB.Camera.V4L` | The driver. Options, lifecycle, and the bridge to `BB.Camera.Hub` |
| `BB.Camera.V4L.Command` | Builds and validates the ffmpeg argument vector. Pure |
| `BB.Camera.V4L.FrameRate` | Exact rational frame rates. Pure |
| `BB.Camera.V4L.Jpeg` | Resumable structural scan of a JPEG stream. Pure |
| `BB.Camera.V4L.Framer` | Buffer, size caps, resynchronisation. A struct, no process |
| `BB.Camera.V4L.Capture` | Owns the port and the ingress bounds. One per running capture |
| `BB.Camera.V4L.Backend` | How capture gets bytes: ffmpeg for real, a stub in tests |
| `BB.Camera.V4L.Reaper` | Kills orphaned OS processes. Outside every robot |

The split between `Jpeg`, `Framer` and `Capture` is deliberate: the two
hardest things here are JPEG structure and process lifetime, and neither is
testable when they are tangled together.

## Things that are easy to get wrong

**Framing is structural, not a marker search.** `FF D9` appears inside EXIF
thumbnails, which plenty of webcams emit. `BB.Camera.V4L.Jpeg` walks segment
lengths and entropy-coded data properly. Do not replace it with
`:binary.match/2` on the end marker.

**Erlang ports have no ingress backpressure.** `Port.open/2`'s
`busy_limits_msgq` is accepted on OTP 29 and does nothing for port-to-owner
data; it maps to `erl_drv_busy_msgq_limits`, which governs the other
direction. Measured: a `cat /dev/zero` port queues gigabytes into the owner's
mailbox in seconds with the limits set. The bounds in `Capture` are the only
thing standing between a fast producer and the VM — and they are **fail-fast,
not a memory bound**: `fail_queue_len` counts reads this process has observed,
which it can only do when scheduled, and `max_frame_bytes` caps one image
rather than a byte rate. The mailbox depth is checked on every read, before
framing, because a producer whose bytes never complete a frame would otherwise
never reach the check. Do not write documentation claiming a calculable memory
ceiling.

**Closing a port does not kill the program behind it.** Nor does killing the
port's owner. Measured on OTP 29 for `Port.close/1`, `Process.exit(owner,
:kill)` and an owner crash: the process survived all three and was reparented
to init. It usually dies of `SIGPIPE` on its next write to the dead pipe,
which is exactly what does not happen when a camera has wedged. `Reaper` is
not belt-and-braces; it is the mechanism.

**Capture is confirmed on the first whole image, not on `Port.open/2`
returning.** ffmpeg existing says nothing about whether the device opened — it
reports that by exiting non-zero a moment later. `Capture` holds its first
frame and sends `{:ready, info}`; the driver confirms to the hub and then
releases it with `Capture.go/1`. Confirming earlier announces `BeginCapture`
for cameras that are about to fail.

**Only one ffmpeg may hold the device, so stop and start are a sequence.** A
capture that has been asked to stop keeps its identity in `:stopping` until
its real exit arrives, and whatever wanted to happen next waits in `:pending`.
`Capture` likewise stays alive until the port reports an exit status, and exits
`{:shutdown, :teardown_unconfirmed}` when even `SIGKILL` produced none — in
which case the driver refuses the replacement rather than opening a second
ffmpeg against a device the first may still hold. Do not "simplify" this by
forgetting the old capture and starting a new one.

**`Hub.deliver/2` is synchronous and must stay that way.** It is the ingress
bound between this package and `bb_camera`. Wrapping it in a `Task` would
reintroduce the unbounded queue it exists to prevent.

**Reconfiguring is `handle_options/2`, and there is no second channel.** This
driver once had a `settings_schema/0` holding `width`, `height` and
`frame_rate` — the same three keys as its own `options_schema/0` — reached by
a `put_settings` round trip. It was deleted: a robot fills those options from
parameters with `param/1`, and `handle_options/2` is where a change lands.
Restart capture only when the new options actually change the ffmpeg argument
vector, so an option that never reaches the command line doesn't drop frames.

**`stream_info/1` must stay pure.** Discovery calls it against robots that are
not running, with options straight out of the DSL and parameter references
unresolved. It must not touch hardware, and must return an error rather than a
guess when the options cannot imply a format.

**The sensor traps exits.** A camera that cannot be opened is ordinary — an
unplugged webcam, a busy device — and the hub has an event for saying so.
Without trapping, the linked capture's exit would kill the sensor and replace
that diagnosis with a restart loop against hardware that is simply absent.

## Honesty about what is known

The driver reports dimensions parsed from each frame's own `SOF` marker, which
is the negotiated geometry rather than the requested one, and hands it to
`Hub.update_stream_info/2`. The frame rate in `stream_info` is only ever the
one that was *asked for*: this driver never queries the device's rate back.

This driver does not measure the real rate, and should not start. Every frame
goes through `BB.Camera.Hub.deliver/2`, so the hub counts them itself and
publishes `BB.Message.Camera.CaptureState`. Measuring here as well would be a
second answer to one question, and a worse one — the hub's window closes on a
clock, so it still reports when frames have stopped, which an every-N-frames
measurement in the driver cannot do.

The chroma subsampling in `stream_info.metadata[:pixel_format]` is derived
from the frame header's sampling factors, and is `nil` before any frame has
arrived. It is a chroma format such as `:I420` — what `Membrane.JPEG` means by
that name — not a codec and not a V4L2 input format.

Do not report a requested value as a negotiated one without adding the query
that would justify it, and do not add a list of supported resolutions: this
driver does not enumerate device capabilities, and
`v4l2-ctl --list-formats-ext` is the honest answer.

## Testing

Tests drive capture through `BB.Camera.V4L.Test.StubBackend`, which delivers
exactly the bytes a test asks for, exactly when it asks. JPEG fixtures come
from `BB.Camera.V4L.Test.JpegBuilder`, which builds structurally valid images
with stuffed bytes, restart markers, fill bytes and embedded thumbnails on
demand.

**No test sleeps, and no timed negative assertions.** Backpressure cases use a
gated sink that blocks until the test releases it, so a backlog is arranged
rather than raced for. To show something did *not* happen, push a synchronous
call through the process first and then use `refute_received`. Observing an OS
process exit — which the BEAM cannot wait on for a process that is not its
child — borrows an event from `tail --pid` behind a port.

## Dependencies

- `bb` — the framework
- `bb_camera` — the `BB.Camera` behaviour, hub, frame and error types

There is no NIF and no port driver: ffmpeg is an ordinary executable behind an
ordinary port.

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments. `mix check` runs `reuse lint` and fails the build if one is
missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` and use the current year.
