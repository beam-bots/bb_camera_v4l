<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# BB.Camera.V4L Usage Rules

`bb_camera_v4l` provides `BB.Camera.V4L`, a camera driver for Linux V4L2
devices for [Beam Bots](https://hexdocs.pm/bb). It captures through a
supervised ffmpeg process, which decodes to raw `{:raw, :I420}` frames, and
serves them through `bb_camera`. For framework
basics see `bb`'s rules; for the consumer-facing API see `bb_camera`'s. This
file covers only what is specific to this driver.

## Core principles

1. **It is a declared component.** Wire it into a `sensor` slot. BB validates
   its options, injects context, and supervises it. You never call
   `start_link` or write a `child_spec`.
2. **You never start or stop capture.** `bb_camera` refcounts consumers and
   tells the driver. One capture serves all of them; opening a second consumer
   does not start a second ffmpeg.
3. **Frames do not go on pubsub.** The robot's topic carries capture lifecycle
   and periodic capture state only. Frame bytes travel over `BB.Camera.Media` or
   `BB.Camera.subscribe/3`.
4. **What a camera supports is the camera's business.** This driver does not
   enumerate formats or sizes. Ask for one the camera lists: every frame is
   the size you asked for, scaled if the camera chose another.

## Wiring it in

Attach it to the link it is physically mounted on:

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.V4L,
      device: "/dev/video0",
      width: 1280,
      height: 720,
      frame_rate: 30
    }
  end
end
```

Then consume it through `bb_camera`:

```elixir
{:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: {:raw, :I420})
{:ok, frame} = BB.Camera.Media.next(session, 5_000)
BB.Camera.Media.close(session)
```

## Picking a device and a format

Use `v4l2-ctl`, not guesswork:

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --list-formats-ext
```

A webcam usually claims two `/dev/video*` nodes and only the first captures.

If `MJPG` appears, pick a size and rate listed under it and leave
`input_format` alone — over USB 2 it is usually the only way to get a high
frame rate. If only `YUYV` appears, set `input_format: :yuyv422`.

Either way ffmpeg decodes to full-range I420 at exactly `:width` x `:height`,
which costs CPU per frame. Both must be even: I420 halves the chroma in each
direction, and an odd size is refused with
`BB.Error.Invalid.Camera.UnsupportedFormat` when the options are read.

Reading the device needs membership of the `video` group on Debian:

```sh
sudo usermod -aG video "$USER"   # then log out and back in
```

## Frame rates

`:frame_rate` takes a hertz unit, a plain number, or a
`{numerator, denominator}` tuple:

```elixir
frame_rate: ~u(30 hertz)
frame_rate: 30
frame_rate: {30_000, 1001}   # NTSC, exactly
```

Use the tuple when the exact rational matters. `29.97` is a different number
from `30000/1001` and this driver will faithfully ask for the one you wrote.

## What the driver claims to know

- `width` and `height` on a frame and in `BB.Camera.stream_info/2` are the
  ones you asked for, always. If the camera negotiates a different size,
  ffmpeg scales it to the requested one — stretching it if the aspect ratio
  differs — because raw frames carry no size of their own and ffmpeg's console
  output, which would say what was negotiated, is not captured.
- `frame_rate` in `stream_info` is the rate that was *asked for*. This driver
  does not query the device's rate back, so it does not claim to know it.

What the frames actually did is measured by `BB.Camera.Hub`, which sees every
one of them, and published as `BB.Message.Camera.CaptureState` — and stamped
on each frame as `measured_frame_rate`, next to `requested_frame_rate`.
Compare the two rather than trusting either alone. `:publish_rate` sets how
often that is published, `~u(1 hertz)` by default.

## Bounds you may need to change

The defaults suit a desktop. On a small target, lower them:

- `:drop_queue_len` (8) is where frames start being shed because delivery has
  fallen behind. The hub only keeps the newest frame, so a shed frame is one
  no consumer would have seen.
- `:stdio_window` (256 KiB) is how much output ffmpeg may have in flight
  before it waits for the VM. It bounds what can queue in the capture's
  mailbox.

## Failure modes

- **Device missing, busy, or unreadable** — ffmpeg exits non-zero, the driver
  reports `BB.Error.Hardware.Camera.CaptureFailed`, and the hub publishes
  `EndCapture{reason: :error}`. ffmpeg's own explanation goes to the VM's
  console; read it, it is usually exact.
- **Device open but silent** — no frame within `:start_timeout_ms` (10 s);
  ffmpeg is stopped and capture fails with `{:no_frames, ms}`.
- **Capture is not retried.** Reopening is the consumer's decision, taken by
  subscribing again.

## Don't

- Don't start a `BB.Camera.FFmpeg.Capture` for a camera this driver declares.
  The driver owns its capture.
- Don't declare a parameter looser than the option it feeds. A parameter typed
  `:integer` will happily store `-1` for `:width`, which this driver's
  `:pos_integer` then refuses — and `handle_options/2` has no way to refuse a
  change and keep running, so the camera stops, restarts into the stored
  value, and stops again. Bound the parameter to match.
- Don't publish frames on pubsub, or put frame bytes in an error.
- Don't use this on anything but Linux. The platform belongs in the driver,
  not in `bb_camera`'s interface; another platform wants another driver.

## Further reading

- [bb_camera_v4l docs](https://hexdocs.pm/bb_camera_v4l)
- `BB.Camera.V4L` for the options and the parameters they feed
- `bb_camera`'s usage rules for the hub, subscriptions and frames
- `bb_camera_ffmpeg`'s usage rules for the capture this driver runs
