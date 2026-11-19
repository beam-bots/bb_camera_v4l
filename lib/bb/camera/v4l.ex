# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L do
  @moduledoc """
  A camera on a Linux V4L2 device, captured through ffmpeg.

  Declared like any other sensor:

      topology do
        link :head do
          sensor :eye, {BB.Camera.V4L, device: "/dev/video0", width: 1280, height: 720}
        end
      end

  Consumers never talk to this module. They go through `BB.Camera`, which
  refcounts them and asks the driver to start capturing when the first one
  arrives and to stop when the last one leaves. Two browser tabs on the same
  camera produce one ffmpeg, not two.

  ## What it captures

  MJPEG, and only MJPEG. The camera is asked for `mjpeg` and ffmpeg copies the
  packets through without decoding them, so a frame reaches the BEAM as the
  bytes the camera's own encoder produced: no transcode, no quality loss, and
  almost no CPU regardless of resolution.

  A camera with no MJPEG mode can still be used by naming the pixel format it
  does have — `input_format: :yuyv422` — and ffmpeg will encode to JPEG on the
  way past. That costs real CPU per frame and is a fallback rather than the
  intended path.

  ## What it reports

  Capture is confirmed to the hub on the **first whole image**, not when ffmpeg
  starts. `Port.open/2` returning says only that ffmpeg exists — a missing or
  busy device would otherwise announce `BeginCapture` a moment before failing.

  Dimensions come from the `SOF` marker of each frame, which is what the camera
  actually encoded. They are not the numbers in the DSL: V4L2 is free to hand
  back the nearest size it supports, and when it does, `BB.Camera.stream_info/2`
  reports the real one.

  The frame rate in `stream_info` is the one that was **requested**, not the
  negotiated one. This driver does not query the device's rate back and does
  not parse it out of ffmpeg's console output, so claiming it as actual would
  be a guess dressed up as a measurement. What the frames actually did is
  measured by `BB.Camera.Hub`, which sees every one of them, and reported
  separately in `BB.Message.Camera.CaptureState`.

  Nothing here enumerates the device's capabilities. Any positive width and
  height and any positive rational frame rate can be asked for; if the device
  refuses, ffmpeg says so on the console and capture fails. Use `v4l2-ctl
  --list-formats-ext` to find out what a camera supports — the answer belongs
  to the camera, not to this driver.

  ## Frames do not go on pubsub

  A robot's pubsub carries capture lifecycle only:
  `BB.Message.Camera.BeginCapture` and `EndCapture`, published by the hub.
  Frame bytes travel over `BB.Camera`'s bounded media interface, and never
  appear in an event or an error.

  ## Options

  See `options_schema/0`. The ones most worth knowing about are `:device`,
  `:width`, `:height` and `:frame_rate`; the rest are bounds with defaults that
  suit a desktop and may want lowering on a small target.

  Any of them can be filled from a parameter with `param/1`, and changing that
  parameter while the robot runs reconfigures the camera - see
  `handle_options/2`.

  ## Limitations

  - **Linux only.** It drives V4L2 through ffmpeg.
  - **Timestamps are arrival times.** The raw MJPEG stream carries no
    timestamps of its own, so a frame is stamped when the read completing it
    reached the BEAM. See `BB.Camera.FFmpeg.Capture` for what that does and
    does not mean.
  - **A failed capture is not retried.** The failure is reported and capture
    ends; reopening the device is the consumer's decision, taken by subscribing
    again. A driver that quietly reopened hardware on its own would be claiming
    to capture during a window where it is not.
  - **Changing an option that reaches ffmpeg restarts it**, because V4L2
    negotiates format and rate when the device is opened. Capture ends and
    begins again around the change, with the events to match; it is not a
    seamless transition and does not pretend to be.
  - **ffmpeg's diagnostics go to the VM's console**, not into the error. They
    cannot be merged into the frame stream without corrupting it.
  """

  use BB.Sensor
  use BB.Camera

  import BB.Unit
  import BB.Unit.Option

  alias BB.Camera.FFmpeg.{Capture, FrameRate}
  alias BB.Camera.{Frame, Hub, StreamInfo}
  alias BB.Camera.V4L.Command
  alias BB.Error.Hardware.Camera.CaptureFailed

  require Logger

  @impl BB.Sensor
  def options_schema do
    Spark.Options.new!(
      device: [
        type: :string,
        required: false,
        doc: "Path to the V4L2 device node, e.g. \"/dev/video0\". Required unless `:lavfi` is"
      ],
      lavfi: [
        type: :string,
        required: false,
        doc: """
        An ffmpeg synthetic source such as `"testsrc2"` to capture instead of a
        device. Runs the whole real pipeline — real ffmpeg, real encoder, real
        pipe, real framing — with no hardware, which is how you tell a broken
        camera from a broken setup. Not a substitute for `BB.Camera.Synthetic`,
        which needs no ffmpeg at all.
        """
      ],
      width: [
        type: :pos_integer,
        default: 640,
        doc: "Width in pixels to ask the device for"
      ],
      height: [
        type: :pos_integer,
        default: 480,
        doc: "Height in pixels to ask the device for"
      ],
      frame_rate: [
        type: FrameRate.option_type(),
        default: 30,
        doc: "Frames per second to ask the device for; see `BB.Camera.FFmpeg.FrameRate`"
      ],
      input_format: [
        type: {:or, [:atom, :string]},
        default: :mjpeg,
        doc: "V4L2 pixel format to request. Anything but `:mjpeg` means ffmpeg must encode"
      ],
      quality: [
        type: :pos_integer,
        default: 5,
        doc: "ffmpeg's `-q:v`, 1 (best) to 31. Only used when encoding"
      ],
      ffmpeg: [
        type: :string,
        required: false,
        doc: "Path to the ffmpeg executable. Defaults to the one on $PATH"
      ],
      publish_rate: [
        type: unit_type(compatible: :hertz),
        default: ~u(1 hertz),
        doc: "How often the hub publishes `BB.Message.Camera.CaptureState`"
      ],
      max_frame_bytes: [
        type: :pos_integer,
        default: 4 * 1024 * 1024,
        doc: "Largest frame to accept. See `BB.Camera.FFmpeg.Framer`"
      ],
      drop_queue_len: [
        type: :pos_integer,
        default: 8,
        doc: "Shed frames while more reads than this are waiting"
      ],
      stdio_window: [
        type: :pos_integer,
        default: 256 * 1024,
        doc: "Bytes of output ffmpeg may have in flight before they are acknowledged"
      ],
      start_timeout_ms: [
        type: :pos_integer,
        default: 10_000,
        doc: """
        How long to wait for the first frame before failing capture. A wedged
        device can leave ffmpeg open and silent. See `BB.Camera.FFmpeg.Capture`
        """
      ],
      stop_timeout_ms: [
        type: :non_neg_integer,
        default: 2_000,
        doc: "How long ffmpeg gets to exit on `SIGTERM` before it is sent `SIGKILL`"
      ],
      backend: [
        type: {:behaviour, BB.Camera.FFmpeg.Backend},
        default: BB.Camera.FFmpeg.Backend.MuonTrap,
        doc: """
        What produces the bytes. The default runs ffmpeg under MuonTrap; tests
        declare `BB.Camera.FFmpeg.Test.StubBackend` here to drive capture read
        by read without a device.
        """
      ],
      backend_opts: [
        type: :keyword_list,
        default: [],
        doc: "Passed to the backend's `open/3`"
      ]
    )
  end

  @doc """
  The format this camera is declared to produce.

  Pure: it is called during discovery against robots that are not running, so
  it reads the options and nothing else. Options that still hold unresolved
  parameter references cannot imply a format, and produce an error rather than
  a guess.
  """
  @impl BB.Camera
  def stream_info(opts) do
    with {:ok, width} <- fetch_dimension(opts, :width),
         {:ok, height} <- fetch_dimension(opts, :height),
         {:ok, frame_rate} <- fetch_frame_rate(opts) do
      StreamInfo.new(
        format: :jpeg,
        width: width,
        height: height,
        frame_rate: frame_rate,
        metadata: %{pixel_format: nil}
      )
    end
  end

  @impl BB.Sensor
  def init(opts) do
    # A camera that cannot be opened is an ordinary condition - an unplugged
    # webcam, a device another process already holds - and the hub has an
    # event for saying so. Letting the linked capture's exit kill the sensor
    # instead would replace that diagnosis with a crash, and a restart loop
    # against hardware that is simply absent.
    Process.flag(:trap_exit, true)

    with {:ok, stream_info} <- stream_info(opts),
         {:ok, command} <- build_command(opts) do
      {:ok, hub} =
        Hub.start_link(
          bb: opts[:bb],
          stream_info: stream_info,
          publish_rate: opts[:publish_rate]
        )

      {:ok,
       %{
         bb: opts[:bb],
         capture: nil,
         command: command,
         dimensions: nil,
         hub: hub,
         opts: opts,
         pending: nil,
         sequence: 0,
         stopping: nil,
         stream_info: stream_info
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl BB.Sensor
  def handle_info({:bb_camera, :start_capture}, state), do: {:noreply, request_start(state)}

  def handle_info({:bb_camera, :stop_capture}, state),
    do: {:noreply, request_stop(state, :driver_stopped)}

  def handle_info({:bb_camera_ffmpeg, capture, {:ready, info}}, %{capture: capture} = state),
    do: {:noreply, confirm(state, info)}

  def handle_info({:bb_camera_ffmpeg, capture, event}, %{capture: capture} = state),
    do: {:noreply, handle_capture_event(state, event)}

  def handle_info({:EXIT, capture, reason}, %{stopping: capture} = state) do
    state = %{state | stopping: nil}

    if teardown_confirmed?(reason) do
      {:noreply, run_pending(state)}
    else
      {:noreply, abandon_pending(state, reason)}
    end
  end

  def handle_info({:EXIT, capture, reason}, %{capture: capture} = state) do
    Logger.warning("capture for #{inspect(camera_name(state))} ended: #{inspect(reason)}")

    Hub.capture_failed(state.hub, %CaptureFailed{camera: camera_name(state), reason: reason})

    {:noreply, run_pending(%{state | capture: nil, dimensions: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Take up options that changed while the robot was running.

  Reached when a `param/1` reference in the camera's DSL options resolves to a
  new value. Only a change that alters the ffmpeg invocation restarts capture:
  V4L2 negotiates format and rate when the device is opened, so a new size or
  rate means a new ffmpeg. Capture stops and starts again around the change; it
  is not a seamless transition and does not pretend to be. An option that
  doesn't reach the command line - a framer bound, say - takes effect without
  disturbing the stream.

  **New options this driver cannot use stop the camera.** `handle_options/2`
  has no way to refuse a change and stay running, so a value that satisfies
  the parameter's declared type but not this driver - a width of `-1` against
  a `:pos_integer` - takes the sensor down, and down again on each restart,
  because the parameter was stored before anyone was asked about it. Declare
  parameters with bounds that match the options they feed.
  """
  @impl BB.Sensor
  def handle_options(opts, state) do
    with {:ok, stream_info} <- stream_info(opts),
         {:ok, command} <- build_command(opts) do
      state = %{state | opts: opts, stream_info: stream_info}

      if command == state.command do
        {:ok, state}
      else
        {:ok, restart_for(%{state | command: command})}
      end
    end
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl BB.Sensor
  def terminate(_reason, state) do
    if state.capture, do: Capture.stop(state.capture)

    :ok
  end

  # ----------------------------------------------------------------------------
  # Lifecycle
  #
  # Only one ffmpeg may hold the device at a time, which makes "stop" and
  # "start again" a sequence rather than two independent events. A capture that
  # has been asked to stop keeps its identity in `:stopping` until its real
  # exit arrives, and whatever wanted to happen next waits in `:pending`. The
  # alternative - forgetting the old capture and opening a new one immediately -
  # produces two ffmpegs contending for one `/dev/video*`, and the second one
  # fails in a way that looks like broken hardware.
  # ----------------------------------------------------------------------------

  defp request_start(%{capture: capture} = state) when is_pid(capture), do: state

  defp request_start(%{stopping: stopping} = state) when is_pid(stopping),
    do: queue(state, :start)

  defp request_start(state), do: start_capture(state)

  defp request_stop(%{capture: capture} = state, reason) when is_pid(capture),
    do: begin_stop(state, {:stop, reason})

  defp request_stop(%{stopping: stopping} = state, reason) when is_pid(stopping),
    do: queue(state, {:stop, reason})

  defp request_stop(state, reason) do
    Hub.capture_stopped(state.hub, reason)

    state
  end

  # A camera that isn't capturing has nothing to restart: the new command is
  # already in state, and whenever the hub next asks for capture it is used.
  defp restart_for(%{capture: capture} = state) when is_pid(capture),
    do: begin_stop(state, :reconfigure)

  defp restart_for(%{stopping: stopping} = state) when is_pid(stopping),
    do: queue(state, :reconfigure)

  defp restart_for(state), do: state

  defp begin_stop(state, pending) do
    capture = state.capture
    state = %{state | sequence: next_sequence(state)}

    Capture.stop(capture)

    %{state | capture: nil, dimensions: nil, stopping: capture, pending: pending}
  end

  defp queue(state, pending), do: %{state | pending: pending}

  defp run_pending(%{pending: nil} = state), do: state

  defp run_pending(%{pending: {:stop, reason}} = state) do
    Hub.capture_stopped(state.hub, reason)

    %{state | pending: nil}
  end

  defp run_pending(%{pending: :start} = state), do: start_capture(%{state | pending: nil})

  defp run_pending(%{pending: :reconfigure} = state) do
    # The docs promise an end and a beginning around an option change, because
    # that is what actually happens: V4L2 negotiates on open, so a new size or
    # rate means a new ffmpeg.
    Hub.capture_stopped(state.hub, :driver_stopped)

    start_capture(%{state | pending: nil})
  end

  # A capture whose teardown could not be confirmed may still be holding the
  # device. Opening a second one would contend with it, so whatever was waiting
  # is abandoned and said so, rather than attempted and blamed on the camera.
  defp abandon_pending(state, reason) do
    Logger.error(
      "capture for #{inspect(camera_name(state))} did not confirm teardown: #{inspect(reason)}"
    )

    error = %CaptureFailed{camera: camera_name(state), reason: reason}

    case state.pending do
      {:stop, stop_reason} -> Hub.capture_stopped(state.hub, stop_reason)
      pending when pending in [:start, :reconfigure] -> Hub.capture_failed(state.hub, error)
      nil -> :ok
    end

    %{state | pending: nil}
  end

  defp teardown_confirmed?({:shutdown, :teardown_unconfirmed}), do: false
  defp teardown_confirmed?(_reason), do: true

  defp start_capture(state) do
    hub = state.hub

    # The dimensions the hub has been told about, shared between this process
    # and the capture process that writes them.
    dimensions = :atomics.new(2, signed: false)

    opts =
      [
        args: Command.argv(state.command),
        executable: state.command.executable,
        notify: self(),
        sequence_start: state.sequence,
        sink: fn frame -> deliver(hub, state.stream_info, dimensions, frame) end
      ] ++ Keyword.take(state.opts, capture_option_keys())

    case Capture.start_link(opts) do
      {:ok, capture} ->
        %{state | capture: capture, dimensions: dimensions}

      {:error, reason} ->
        Hub.capture_failed(state.hub, %CaptureFailed{
          camera: camera_name(state),
          reason: reason
        })

        state
    end
  end

  # Capture is confirmed on the first whole image, not when ffmpeg starts.
  # `Port.open/2` returning tells us ffmpeg exists; it says nothing about
  # whether the device opened, and a missing camera would otherwise announce
  # `BeginCapture` a moment before it failed.
  defp confirm(state, info) do
    stream_info = %{
      state.stream_info
      | width: info.width,
        height: info.height,
        metadata: Map.put(state.stream_info.metadata, :pixel_format, info.chroma_format)
    }

    :atomics.put(state.dimensions, 1, info.width)
    :atomics.put(state.dimensions, 2, info.height)

    Hub.capture_started(state.hub, stream_info)
    Capture.go(state.capture)

    %{state | stream_info: stream_info}
  end

  defp deliver(hub, declared, dimensions, frame) do
    known = {:atomics.get(dimensions, 1), :atomics.get(dimensions, 2)}

    if {frame.width, frame.height} != known do
      Hub.update_stream_info(hub, %{declared | width: frame.width, height: frame.height})
      :atomics.put(dimensions, 1, frame.width)
      :atomics.put(dimensions, 2, frame.height)
    end

    Hub.deliver(
      hub,
      Frame.new!(
        format: :jpeg,
        width: frame.width,
        height: frame.height,
        data: frame.data,
        sequence: frame.sequence,
        monotonic_time: frame.monotonic_time,
        wall_time: frame.wall_time,
        metadata: frame.metadata
      )
    )
  end

  defp handle_capture_event(state, {:exited, status}) do
    Logger.info("ffmpeg for #{inspect(camera_name(state))} exited with status #{status}")

    state
  end

  defp handle_capture_event(state, {:discarded, bytes, reason}) do
    Logger.warning(
      "#{inspect(camera_name(state))} discarded #{bytes} bytes of capture: #{reason}"
    )

    state
  end

  defp handle_capture_event(state, {:dropped, count}) do
    Logger.debug("#{inspect(camera_name(state))} shed #{count} frames to keep up")

    state
  end

  defp handle_capture_event(state, {:no_frames, timeout_ms}) do
    Logger.warning(
      "#{inspect(camera_name(state))} produced no frame within #{timeout_ms}ms; " <>
        "ffmpeg's console output above says why, if it knows"
    )

    state
  end

  defp handle_capture_event(state, {:sink_error, reason}) do
    Logger.warning("#{inspect(camera_name(state))} could not deliver a frame: #{inspect(reason)}")

    state
  end

  defp handle_capture_event(state, _event), do: state

  # Sequence numbers have to keep climbing across a restart: the hub rejects a
  # frame whose sequence does not strictly increase, and a capture that reset
  # its counter would have every frame refused as stale.
  defp next_sequence(%{capture: nil} = state), do: state.sequence

  defp next_sequence(state) do
    case Capture.stats(state.capture) do
      %{frames: frames} -> state.sequence + frames
      _other -> state.sequence
    end
  catch
    :exit, _reason -> state.sequence
  end

  defp build_command(opts) do
    command_opts =
      opts
      |> Keyword.take([:device, :lavfi, :width, :height, :frame_rate, :input_format, :quality])
      |> Keyword.put(:executable, opts[:ffmpeg])

    case Command.new(command_opts) do
      {:ok, command} -> {:ok, command}
      {:error, reason} -> {:error, %CaptureFailed{camera: opts[:bb][:path], reason: reason}}
    end
  end

  defp capture_option_keys,
    do: [
      :backend,
      :backend_opts,
      :drop_queue_len,
      :max_frame_bytes,
      :start_timeout_ms,
      :stdio_window,
      :stop_timeout_ms
    ]

  defp camera_name(state), do: List.last(state.bb.path)

  defp fetch_dimension(opts, key) do
    case Keyword.get(opts, key, default_for(key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> unknown_stream_info({key, other})
    end
  end

  defp fetch_frame_rate(opts) do
    case FrameRate.new(Keyword.get(opts, :frame_rate, 30)) do
      {:ok, rate} -> {:ok, FrameRate.to_float(rate)}
      {:error, reason} -> unknown_stream_info({:frame_rate, reason})
    end
  end

  defp default_for(:width), do: 640
  defp default_for(:height), do: 480

  defp unknown_stream_info(reason) do
    {:error, %BB.Error.Invalid.Camera.UnknownStreamInfo{module: __MODULE__, reason: reason}}
  end
end
