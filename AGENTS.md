<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Project Overview

`bb_camera_v4l` is a Beam Bots camera driver for Linux V4L2 devices. One
module, `BB.Camera.V4L`, is both a `BB.Sensor` and a `BB.Camera`;
`BB.Camera.V4L.Command` builds the ffmpeg argument vector.

Running ffmpeg, flow control, raw video framing and process cleanup live in
`bb_camera_ffmpeg`, shared with `bb_camera_avf`. A fix there belongs there,
not here.

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

`BB_VERSION=local` resolves `bb`, `bb_camera` and `bb_camera_ffmpeg` from the
sibling checkouts.

## Architecture

| Module | |
|---|---|
| `BB.Camera.V4L` | The driver. Options, lifecycle, and the bridge to `BB.Camera.Hub` |
| `BB.Camera.V4L.Command` | Builds and validates the ffmpeg argument vector. Pure |

Everything else is `bb_camera_ffmpeg`: `BB.Camera.FFmpeg.Capture` runs one
capture, and the driver handles its `{:bb_camera_ffmpeg, pid, event}`
messages.

## Things that are easy to get wrong

**ffmpeg runs under MuonTrap, and that is the cleanup mechanism.** Closing a
port does not kill the program behind it, nor does killing the port's owner —
measured on OTP 29, the process was reparented to init. This package used to
carry a `Reaper` that signalled orphans from inside the VM, checking `/proc`
start times; it could not act once the VM had halted. MuonTrap is ffmpeg's
parent and kills it when the VM's end of the pipe closes. See
`bb_camera_ffmpeg`'s AGENTS.md before changing anything about process
lifetime.

**`-nostdin` is not optional.** ffmpeg's stdin is MuonTrap's flow-control
channel. `Command.argv/1` always emits it, and `bb_camera_ffmpeg` refuses to
start ffmpeg without it. It also means ffmpeg is stopped with `SIGTERM`, not
with `q`.

**Capture is confirmed on the first whole frame, not on ffmpeg starting.**
ffmpeg existing says nothing about whether the device opened — it reports that
by exiting non-zero a moment later. The driver confirms to the hub on
`:ready` and then releases the held frame with `Capture.go/1`.
Confirming earlier announces `BeginCapture` for cameras that are about to
fail.

**Only one ffmpeg may hold the device, so stop and start are a sequence.** A
capture that has been asked to stop keeps its identity in `:stopping` until
its real exit arrives, and whatever wanted to happen next waits in `:pending`.
A capture that exits `{:shutdown, :teardown_unconfirmed}` may still hold the
device, so the driver refuses the replacement rather than opening a second
ffmpeg against it. Do not "simplify" this by forgetting the old capture and
starting a new one.

**`Hub.deliver/2` is synchronous and must stay that way.** It is the delivery
bound between `bb_camera_ffmpeg` and `bb_camera`. Wrapping it in a `Task`
would reintroduce the unbounded queue it exists to prevent.

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

Frames are `{:raw, :I420}`, full-range, at exactly the configured width and
height. Raw video doesn't describe itself and ffmpeg's stderr is not captured,
so nothing could tell the driver what ffmpeg actually produced. The output is
*forced* instead — `-vf scale=W:H:out_range=full,format=yuv420p` in
`Command.argv/1` — and `Command` computes `frame_bytes` from the same numbers
and owns the format (`Command.format/0`), so what the argument vector forces
and what the driver claims can't drift apart. If the device negotiates a
different size, ffmpeg scales to the requested one: consistency over fidelity.

I420 needs even dimensions. `Command.new/1` and `stream_info/1` both refuse
odd ones with `UnsupportedFormat{reason: :invalid_dimensions}`, via
`BB.Camera.Format.frame_size/3`, and `init/1` and `handle_options/2` check
before anything else — so a bad size is refused when the options are read.

`-fps_mode passthrough` is deliberate. The rawvideo muxer otherwise defaults
to a constant rate and duplicates frames to fill gaps, and each duplicate would
reach the hub as a new capture with a new timestamp. There is no `-r`: rate is
asked of the device with `-framerate`, and nothing on the output side should
invent or drop frames.

The frame rate in `stream_info` is only ever the one that was *asked for*:
this driver never queries the device's rate back.

This driver does not measure the real rate, and should not start. Every frame
goes through `BB.Camera.Hub.deliver/2`, so the hub counts them itself and
publishes `BB.Message.Camera.CaptureState`. Measuring here as well would be a
second answer to one question, and a worse one — the hub's window closes on a
clock, so it still reports when frames have stopped, which an every-N-frames
measurement in the driver cannot do.

Do not report a requested value as a negotiated one without adding the query
that would justify it, and do not add a list of supported resolutions: this
driver does not enumerate device capabilities, and
`v4l2-ctl --list-formats-ext` is the honest answer.

## Testing

The test robot declares `BB.Camera.FFmpeg.Test.StubBackend` as its backend,
and tests feed it raw I420 bytes of exactly one frame's size. It ships in
`bb_camera_ffmpeg`'s `lib` for exactly this.

The `:ffmpeg` tests capture ffmpeg's `color` source, which is black: full-range
I420 black is luma 0 and chroma 128, so comparing the bytes proves the size,
the plane layout and the range at once. A frame's length alone proves nothing,
since the framer cuts every `frame_bytes` whatever ffmpeg wrote.

**No test sleeps, and no timed negative assertions.** To show something did
*not* happen, push a synchronous call through the process first and then use
`refute_received`.

Tests tagged `:linux` need ffmpeg's V4L2 input and are excluded on other
systems by `test/test_helper.exs`.

## Dependencies

- `bb` — the framework
- `bb_camera` — the `BB.Camera` behaviour, hub, frame and error types
- `bb_camera_ffmpeg` — ffmpeg under MuonTrap, flow control and raw video framing

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments. `mix check` runs `reuse lint` and fails the build if one is
missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` and use the current year.
