<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# bb_camera_v4l

A [Beam Bots](https://github.com/beam-bots/bb) camera driver for Linux V4L2
devices — webcams, capture cards, CSI cameras — capturing MJPEG through a
supervised ffmpeg process.

It is a `BB.Sensor` and a `BB.Camera`, declared like any other sensor:

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.V4L, device: "/dev/video0", width: 1280, height: 720}
  end
end
```

Consumers go through [`bb_camera`](https://github.com/beam-bots/bb_camera),
which shares one capture between all of them. Two browser tabs previewing the
same camera produce one ffmpeg, not two.

**Frames never travel on the robot's pubsub.** That carries capture lifecycle
only — `BeginCapture` and `EndCapture`. Frame bytes go over `bb_camera`'s
bounded media interface.

## Status

A spike. `bb_camera_v4l` and its `bb_camera` dependency are **not published on
Hex** — both are local checkouts under `bb_workspace`, and `BB_VERSION=local`
is what makes mix resolve them from there. Nothing here installs from Hex yet.

## Requirements

- **Linux.** This driver speaks V4L2 and identifies OS processes through
  `/proc`. Cameras on other platforms want a different driver behind the same
  `BB.Camera` interface.
- **ffmpeg** on `$PATH`.
- **Read access to the device node**, which on Debian means membership of the
  `video` group.

## Smoke test on a Debian laptop

This walks from nothing to two consumers sharing one capture. The first half
needs no camera at all, which is deliberate: if the synthetic source works and
the real one does not, the problem is the camera or its permissions, and you
have narrowed it down without guessing.

### 1. Install the tools

```sh
sudo apt update
sudo apt install ffmpeg v4l-utils
```

`v4l-utils` is not needed at runtime. It is how you ask the camera what it can
do — which this driver deliberately does not guess at on your behalf.

### 2. Prove the pipeline works without a camera

From the package directory:

```sh
BB_VERSION=local mix deps.get
BB_VERSION=local iex -S mix
```

`BB_VERSION=local` is needed on **both** commands. It is read each time mix
runs, not stored in the lockfile, so a shell that resolved `bb` from the
sibling checkout to fetch will resolve it from Hex to compile unless you say
so again.

Paste this robot into the session. It captures one of ffmpeg's own synthetic
sources: real ffmpeg, real JPEG encoder, real pipe, real framing — and no
hardware.

```elixir
defmodule SynthCam do
  use BB

  settings do
    name :synth_cam
  end

  topology do
    link :head do
      sensor :eye, {BB.Camera.V4L, lavfi: "testsrc2", width: 320, height: 240, frame_rate: 10}
    end
  end
end

{:ok, _pid} = SynthCam.start_link([])

{:ok, session} = BB.Camera.Media.open(SynthCam, :eye, format: :jpeg)
{:ok, frame} = BB.Camera.Media.next(session, 10_000)

{frame.width, frame.height, byte_size(frame.data)}
#=> {320, 240, 8625}

File.write!("/tmp/frame.jpg", frame.data)
BB.Camera.Media.close(session)
```

Then, in another terminal, check it really is an image:

```sh
file /tmp/frame.jpg
#=> /tmp/frame.jpg: JPEG image data, JFIF standard 1.02, ... 320x240, components 3
xdg-open /tmp/frame.jpg
```

If that failed, nothing below will work, and the problem is ffmpeg rather than
your camera.

### 3. Find the camera

```sh
v4l2-ctl --list-devices
```

```
Integrated Camera: Integrated C (usb-0000:00:14.0-8):
        /dev/video0
        /dev/video1
        /dev/media0
```

A single webcam usually claims **two** `/dev/video*` nodes. Only the first is
the capture device; the second is a metadata node and will fail to produce
frames. Confirm which is which:

```sh
v4l2-ctl -d /dev/video0 --list-formats-ext
```

```
ioctl: VIDIOC_ENUM_FMT
        Type: Video Capture

        [0]: 'MJPG' (Motion-JPEG, compressed)
                Size: Discrete 1280x720
                        Interval: Discrete 0.033s (30.000 fps)
                Size: Discrete 640x480
                        Interval: Discrete 0.033s (30.000 fps)
        [1]: 'YUYV' (YUYV 4:2:2)
                Size: Discrete 640x480
                        Interval: Discrete 0.033s (30.000 fps)
```

A node that prints nothing under `Video Capture` is not the one you want.

Note what it supports. If `MJPG` is listed, pick a size and rate from under it
and the camera's own encoder does the work. If only `YUYV` is listed, pass
`input_format: :yuyv422` and ffmpeg encodes instead, which costs real CPU per
frame.

This driver does not enumerate any of this for you, and does not pretend to
know it. Ask for what you want; the frames report what you got.

### 4. Check permissions

Ask the only question that matters — can you read it?

```sh
test -r /dev/video0 && echo readable || echo "no access"
```

If that says `readable`, you are done; skip to the next step.

On a desktop Debian install it usually does, even though the node is owned by
the `video` group and you are not in it:

```sh
ls -l /dev/video0
#=> crw-rw----+ 1 root video 81, 0 Nov 17 20:11 /dev/video0
```

The `+` is the giveaway: systemd-logind puts an ACL on the device granting the
user of the active local seat access to it. `getfacl /dev/video0` shows the
entry. That is why adding yourself to `video` is often cited and often
unnecessary.

It *is* necessary when there is no local seat — over SSH, from a service, in a
container, or on a headless board:

```sh
sudo usermod -aG video "$USER"
```

Then **log out and back in**. A new shell is not enough; the group list is
attached to your login session, and `id -nG` is the check.

A camera you have no permission to open fails the same way as one that is not
there: ffmpeg prints `Permission denied` on the console and capture ends. That
message is the fastest way to tell the two apart.

### 5. Capture from the real camera

Same shape as the synthetic one, pointed at the device you found. Defining it
in the IEx session means nothing to recompile and nothing to edit:

```elixir
defmodule MyCam do
  use BB

  settings do
    name :my_cam
  end

  topology do
    link :head do
      sensor :eye, {BB.Camera.V4L, device: "/dev/video0", width: 1280, height: 720, frame_rate: 30}
    end
  end
end

{:ok, _pid} = MyCam.start_link([])
```

Discovery works before anything is capturing:

```elixir
BB.Camera.discover(MyCam)
#=> [%BB.Camera.Info{name: :eye, path: [:head, :eye], status: :running,
#=>   stream_info: %BB.Camera.StreamInfo{format: :jpeg, width: 1280, height: 720, ...}}]
```

Watch the lifecycle, then open a consumer:

```elixir
BB.subscribe(MyCam, [:sensor, :head, :eye])

{:ok, first} = BB.Camera.Media.open(MyCam, :eye, format: :jpeg)
flush()
#=> {:bb, [:sensor, :head, :eye],
#=>   %BB.Message{payload: %BB.Message.Camera.BeginCapture{subscriber_count: 1, ...}}}

{:ok, frame} = BB.Camera.Media.next(first, 10_000)
{frame.width, frame.height}
File.write!("/tmp/camera.jpg", frame.data)
```

`frame.width` and `frame.height` are read out of the JPEG the camera actually
produced. If you asked for a size it does not support and it quietly gave you
another, this is where you find out:

```elixir
BB.Camera.stream_info(MyCam, :eye)
```

### 6. Two consumers, one capture

Open a second one, and count the ffmpeg processes:

```elixir
{:ok, second} = BB.Camera.Media.open(MyCam, :eye, format: :jpeg)
{:ok, _frame} = BB.Camera.Media.next(second, 10_000)
```

```sh
pgrep -ax ffmpeg
#=> 2193841 /usr/bin/ffmpeg -hide_banner -loglevel error -f v4l2 -input_format mjpeg ...
```

One line. Both consumers are reading the same capture.

Note `pgrep -x`, matching the process name exactly: `pgrep -f ffmpeg` also
matches the shell command containing the word, which makes it look like there
are several when there is one.

### 7. Shut it down

```elixir
BB.Camera.Media.close(first)
BB.Camera.Media.close(second)
flush()
#=> {:bb, [:sensor, :head, :eye],
#=>   %BB.Message{payload: %BB.Message.Camera.EndCapture{reason: :no_subscribers, ...}}}
```

```sh
pgrep -ax ffmpeg
```

Nothing. Capture stops when the last consumer leaves, and the camera's light
goes out.

This is worth checking rather than assuming. Closing an Erlang port does *not*
kill the program behind it, and neither does killing the port's owner — both
were measured, and in both cases the process survived and was reparented to
init. A separate reaper signals it, which is why there is nothing left here.

## A preview in a browser

`bb_liveview/examples/camera_spike` is a standalone application wiring this
driver to an MJPEG preview route. Start there if what you want is to see the
picture rather than the bytes.

It has the same three settings as the smoke test above, in the same order:
`bb_camera`'s synthetic camera by default (no hardware, no ffmpeg),
`CAMERA_LAVFI=testsrc2` to run this driver against a synthetic ffmpeg source,
and `CAMERA_DEVICE=/dev/video0` for the real thing. The triage is the same
too — working on synthetic but not on lavfi is a `bb_camera` or `bb_liveview`
problem; working on lavfi but not on the device is the camera or its
permissions, and this README is where that is worked through.

## Options

| Option | Default | |
|---|---|---|
| `:device` | — | V4L2 device node. Required unless `:lavfi` is given |
| `:lavfi` | — | An ffmpeg synthetic source such as `"testsrc2"`, instead of a device |
| `:width`, `:height` | `640`, `480` | Any positive size. Not checked against the device |
| `:frame_rate` | `30` | A hertz unit, a number, or `{numerator, denominator}` for an exact rational such as `{30_000, 1001}` |
| `:input_format` | `:mjpeg` | V4L2 pixel format to ask for. Anything else means ffmpeg must encode |
| `:quality` | `5` | ffmpeg's `-q:v`, 1 (best) to 31. Only used when encoding |
| `:ffmpeg` | `$PATH` | Path to the ffmpeg executable |
| `:max_frame_bytes` | 4 MiB | Largest frame accepted before the stream is resynchronised |
| `:drop_queue_len` | `8` | Shed frames above this capture mailbox depth |
| `:fail_queue_len` | `256` | Stop capture above this mailbox depth |
| `:stop_timeout_ms` | `2000` | How long ffmpeg gets to exit before it is signalled |

## How it holds together

```
ffmpeg ──pipe──> Capture ──frames──> BB.Camera.Hub ──> consumers
                    │                     │
                    │                     └─ lifecycle ──> BB.PubSub
                    └─ os pid ──> Reaper
```

- **`BB.Camera.V4L.Command`** builds the argument vector and validates it.
  `Port.open/2` with `:spawn_executable` calls `execve` directly, so no shell
  ever parses a device path.
- **`BB.Camera.V4L.Jpeg`** walks the JPEG marker structure rather than
  searching for `FF D9`, which is wrong for any camera that embeds an EXIF
  thumbnail, and reads the real dimensions out of the frame header on the way
  past.
- **`BB.Camera.V4L.Framer`** holds the partial frame between reads, with hard
  size caps and one resynchronisation path for everything malformed.
- **`BB.Camera.V4L.Capture`** owns the port and the bounds. Erlang ports have
  no ingress flow control, so it sheds frames when it falls behind and stops
  rather than letting its mailbox grow without limit.
- **`BB.Camera.V4L.Reaper`** kills the OS process when whatever owned it dies,
  checking `/proc` start times first so a recycled pid is never signalled.

## Limitations

- **Linux only**, by design.
- **Timestamps are arrival times, not exposure times, and are not suitable for
  synchronisation.** The raw MJPEG stream ffmpeg writes has no container and
  therefore no timestamps of its own; a frame is stamped when the read
  completing it reached the BEAM. The gap between exposure and that moment
  covers the camera's pipeline, the USB transfer, V4L2's buffers, ffmpeg's
  muxer, the pipe and the BEAM's scheduler — and it **varies**, by whole frame
  intervals under load, since buffering and scheduling are not constant. Do
  not use these stamps to align two cameras with each other, or a camera with
  an IMU or an encoder. Something that carries hardware capture timestamps is
  needed for that, and this driver is not it.
- **The frame rate is reported as requested, not negotiated.** This driver
  does not query the device's rate back, so it does not claim it. What the
  frames actually did is measured by `BB.Camera.Hub` and reported separately
  in `BB.Message.Camera.CaptureState`.
- **No capability enumeration.** `v4l2-ctl --list-formats-ext` is the answer;
  the camera owns it.
- **A failed capture is not retried.** The failure is reported and capture
  ends. Reopening is the consumer's decision, taken by subscribing again.
- **Changing an option that reaches ffmpeg restarts it.** V4L2 negotiates on
  open, so a new size or rate means a new capture: `EndCapture`, then
  `BeginCapture` once the replacement produces a frame. The old ffmpeg is
  confirmed gone before the new one is started, and if its teardown cannot be
  confirmed the replacement is refused rather than left to contend for the
  device.
- **The ingress limits are fail-fast, not a memory bound.** `fail_queue_len`
  counts queued reads this driver has *observed*, and it only observes them
  when it is scheduled; a starved process accumulates messages without running
  the check, and the port keeps reading regardless. What the limits buy is that
  a sustained overload is noticed and reported rather than silently eating
  memory.
- **ffmpeg's diagnostics go to the VM's console**, not into the error, because
  merging its stderr into its stdout would corrupt every frame.
- **JPEG only.** Interframe codecs are refused rather than carried; see
  `bb_camera` for why.

## Testing

```sh
BB_VERSION=local mix deps.get
BB_VERSION=local mix test                   # no camera, no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg  # also runs ffmpeg for real
BB_VERSION=local mix check --no-retry
```

`BB_VERSION=local` goes on every command, including `deps.get`.

The default suite drives capture through an injected backend, so every case —
a frame split across reads, a truncated image, an unexpected exit status, a
consumer falling behind — is a function call rather than something to wait
for. No test sleeps.

The `:ffmpeg` tagged tests run the whole real path against a synthetic ffmpeg
source. They need ffmpeg, but no camera.

## Licence

Apache-2.0. See `LICENSES/`.
