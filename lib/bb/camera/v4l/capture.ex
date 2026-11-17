# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Capture do
  @moduledoc """
  One running capture: the ffmpeg process, the framer, and the bounds.

  There is exactly one of these per camera while capture is running, and none
  when it is not. Consumers never reach it — they talk to `BB.Camera.Hub`,
  which refcounts them and tells the driver when to start and stop. Two browser
  tabs on the same camera produce one of these, not two.

  It is a process of its own rather than part of the sensor so that the sensor
  stays answerable while a frame delivery is in flight. `BB.Camera.Hub.deliver/2`
  is a synchronous call by design, and a sensor blocked inside one would not be
  reading the `stop_capture` message asking it to shut down.

  ## Bounding ingress, and what that does not mean

  Erlang ports have no flow control: a port reads its file descriptor as fast
  as the OS will give it up and posts every read to the owner's mailbox,
  whether or not the owner is keeping up. `Port.open/2`'s `busy_limits_msgq`
  does not change that — on OTP 29 it is accepted and ignored for port-to-owner
  data, and a `cat /dev/zero` port will queue gigabytes in seconds with it set.
  So what bounds exist are built here:

  1. **A drain-only owner.** This process frames bytes and hands frames on. It
     does no decoding, no encoding and no consumer work, so it falls behind
     only when something downstream is slow.
  2. **Shedding.** Past `:drop_queue_len` queued messages, frames are framed
     but not delivered: the pipeline is behind, the hub keeps only the newest
     frame anyway, and a frame that would be superseded before anyone could see
     it is not worth a blocking call. This is self-balancing — the queue drains
     while frames are shed, delivery resumes below the threshold, and a
     permanently slow consumer settles at the rate it can take rather than
     starving.
  3. **Failing.** Past `:fail_queue_len` the backlog is not transient and the
     capture stops with `{:shutdown, :overload}`.

  The mailbox depth is checked on **every read**, before framing, because a
  producer emitting bytes that never complete a frame would otherwise never
  reach the check.

  **This is fail-fast, not a memory bound.** `:fail_queue_len` limits the
  number of queued reads this process has *observed*, and it can only observe
  them when it is scheduled. A process starved of CPU accumulates messages
  without running the check, and nothing here can stop that — the port keeps
  reading regardless. Nor is `:max_frame_bytes` a byte-rate cap: it bounds one
  image, not what a malfunctioning producer can write per second. What these
  limits buy is that a sustained overload is noticed and reported rather than
  silently eating memory. They do not make the memory ceiling a number you can
  calculate in advance.

  Within a single read, only the newest frame is delivered and the rest are
  counted as dropped, for the same reason — the hub holds one frame, so the
  others would be overwritten before any consumer saw them.

  ## Timestamps, honestly

  A frame is stamped when the read that completed it arrived in this process.
  That is **not** the moment the sensor was exposed. Between the two sit the
  camera's own pipeline, the USB transfer, V4L2's buffers, ffmpeg's muxer, the
  pipe, and the BEAM's scheduler.

  Nothing better is available on this path: the raw MJPEG stream ffmpeg writes
  is a bare concatenation of images with no container and therefore no
  timestamps at all. Carrying real capture times would mean reading a container
  format out of ffmpeg and demuxing it, which this spike does not do. The
  stamps are monotonic, they are in arrival order, and the error between them
  and exposure is roughly constant — so inter-frame intervals are meaningful
  even though absolute times are offset.
  """

  use GenServer

  alias BB.Camera.V4L.{Framer, Reaper}

  require Logger

  @default_drop_queue_len 8
  @default_fail_queue_len 256
  @default_stop_timeout_ms 2_000
  @default_measure_every 30
  @interval_smoothing 0.1

  @type frame :: %{
          data: binary(),
          width: pos_integer(),
          height: pos_integer(),
          sequence: non_neg_integer(),
          monotonic_time: integer(),
          wall_time: integer(),
          metadata: map()
        }

  @typedoc """
  What capture tells its owner about, beyond the frames themselves.
  """
  @type event ::
          {:exited, status :: integer()}
          | {:discarded, bytes :: pos_integer(), reason :: atom()}
          | {:dropped, frames :: pos_integer()}
          | {:overloaded, queue_len :: pos_integer()}
          | {:sink_error, term()}
          | {:measured_frame_rate, float()}
          | {:ready, BB.Camera.V4L.Jpeg.info()}

  @doc """
  Start a capture.

  ## Options

  - `:command` — the validated `BB.Camera.V4L.Command`. Required.
  - `:sink` — a 1-arity function called with each `t:frame/0`, returning
    `:ok` or `{:error, reason}`. Called inline, so a synchronous sink is what
    bounds delivery. Required.
  - `:notify` — process to send `t:event/0`s to, tagged
    `{:bb_camera_v4l, capture_pid, event}`. Default the starting process.
  - `:sequence_start` — first sequence number. A camera that restarts its
    capture must keep counting up, because the hub rejects a sequence that does
    not strictly increase. Default `0`.
  - `:max_frame_bytes` — passed to `BB.Camera.V4L.Framer`.
  - `:drop_queue_len` — shed frames above this mailbox depth. Default
    #{@default_drop_queue_len}.
  - `:fail_queue_len` — stop above this mailbox depth. Default
    #{@default_fail_queue_len}.
  - `:stop_timeout_ms` — how long ffmpeg gets to exit on its own after being
    asked politely, before the reaper signals it. Default
    #{@default_stop_timeout_ms}.
  - `:measure_every` — report the measured frame rate every this many frames.
    Default #{@default_measure_every}.
  - `:backend`, `:backend_opts` — defaults `BB.Camera.V4L.Backend.FFmpeg`
    and `[]`.
  - `:reaper` — the `BB.Camera.V4L.Reaper` to register the OS process with.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :notify, self()))

  @doc """
  Stop the capture, giving ffmpeg a chance to release the device first.

  Asynchronous, because the caller is the sensor and the sensor has a hub
  waiting to be told that capture has ended. Blocking it for however long
  ffmpeg takes to notice would hold up that answer, and the teardown is
  guaranteed by `BB.Camera.V4L.Reaper` rather than by anybody waiting for it.

  `Process.monitor/1` the capture first when you need to know it has finished.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(capture) do
    GenServer.cast(capture, :stop)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Let frames start flowing to the sink.

  A capture holds its frames until this is called, so that the hub cannot be
  handed a frame before the driver has confirmed to it that capture started —
  it would refuse one, and the frame would be lost for no reason. Opening the
  device and confirming it are two steps in two processes, and this closes the
  gap between them without either having to wait on the other.

  Nothing is dropped in the meantime beyond what the newest-frame-wins policy
  would have dropped anyway: the most recent frame is held and delivered here.
  """
  @spec go(GenServer.server()) :: :ok
  def go(capture) do
    GenServer.cast(capture, :go)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Counters for this capture: frames delivered, frames shed, bytes discarded.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(capture), do: GenServer.call(capture, :stats)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    command = Keyword.fetch!(opts, :command)
    backend = Keyword.get(opts, :backend, BB.Camera.V4L.Backend.FFmpeg)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    reaper = Keyword.get(opts, :reaper, Reaper)

    case backend.open(command, backend_opts) do
      {:ok, handle} ->
        os_pid = backend.os_pid(handle)
        if os_pid, do: Reaper.watch(reaper, os_pid)

        {:ok,
         %{
           backend: backend,
           command: command,
           drop_queue_len: Keyword.get(opts, :drop_queue_len, @default_drop_queue_len),
           fail_queue_len: Keyword.get(opts, :fail_queue_len, @default_fail_queue_len),
           framer: Framer.new(Keyword.take(opts, [:max_frame_bytes])),
           handle: handle,
           notify: Keyword.fetch!(opts, :notify),
           os_pid: os_pid,
           reaper: reaper,
           sequence: Keyword.get(opts, :sequence_start, 0),
           sink: Keyword.fetch!(opts, :sink),
           last_frame_time: nil,
           measure_every: Keyword.get(opts, :measure_every, @default_measure_every),
           mean_interval_ns: nil,
           pending: nil,
           started: false,
           stats: %{frames: 0, dropped: 0, discarded_bytes: 0},
           stop_timeout_ms: Keyword.get(opts, :stop_timeout_ms, @default_stop_timeout_ms),
           stopping: false
         }}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl GenServer
  def handle_cast(:go, %{started: true} = state), do: {:noreply, state}

  def handle_cast(:go, %{pending: nil} = state), do: {:noreply, %{state | started: true}}

  def handle_cast(:go, state) do
    {frame, monotonic_time, wall_time} = state.pending

    {:noreply, deliver(%{state | started: true, pending: nil}, frame, monotonic_time, wall_time)}
  end

  def handle_cast(:stop, %{stopping: true} = state), do: {:noreply, state}

  def handle_cast(:stop, state) do
    state.backend.request_stop(state.handle)
    Process.send_after(self(), :stop_timeout, state.stop_timeout_ms)

    {:noreply, %{state | stopping: true}}
  end

  @impl GenServer
  def handle_info({handle, {:data, chunk}}, %{handle: handle} = state) do
    # Before framing, not after: a producer emitting megabytes of garbage that
    # never completes a frame would otherwise never reach this check at all.
    queue_len = message_queue_len()

    if queue_len > state.fail_queue_len do
      notify(state, {:overloaded, queue_len})
      {:stop, {:shutdown, :overload}, state}
    else
      {:noreply, read(state, chunk, queue_len)}
    end
  end

  def handle_info({handle, {:exit_status, status}}, %{handle: handle} = state) do
    release(state)
    notify(state, {:exited, status})

    state = %{state | handle: nil, os_pid: nil}

    if state.stopping do
      {:stop, :normal, state}
    else
      {:stop, {:shutdown, {:exited, status}}, state}
    end
  end

  def handle_info(:stop_timeout, %{stopping: false} = state), do: {:noreply, state}

  def handle_info(:stop_timeout, state) do
    Logger.warning("ffmpeg did not exit within #{state.stop_timeout_ms}ms, signalling it instead")

    reap(state)
    Process.send_after(self(), :stop_deadline, state.stop_timeout_ms)

    {:noreply, state}
  end

  # Signalling is not the same as having exited, and the caller is waiting to
  # know the device has been released before it opens it again. So the capture
  # stays alive until the port reports the real exit status - and when even
  # SIGKILL has not produced one, says so in its exit reason rather than
  # letting the caller assume otherwise.
  def handle_info(:stop_deadline, state) do
    Logger.error("ffmpeg #{inspect(state.os_pid)} did not exit after being signalled")

    {:stop, {:shutdown, :teardown_unconfirmed}, state}
  end

  def handle_info({:EXIT, handle, _reason}, %{handle: handle} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: terminate_process(state)

  defp read(state, chunk, queue_len) do
    monotonic_time = System.monotonic_time(:nanosecond)
    wall_time = System.system_time(:nanosecond)

    {frames, discards, framer} = Framer.push(state.framer, chunk)

    %{state | framer: framer}
    |> report_discards(discards)
    |> handle_frames(frames, queue_len, monotonic_time, wall_time)
  end

  defp handle_frames(state, [], _queue_len, _monotonic_time, _wall_time), do: state

  defp handle_frames(state, frames, queue_len, monotonic_time, wall_time) do
    if queue_len > state.drop_queue_len do
      shed(state, frames)
    else
      # Everything but the newest frame in this read would be overwritten in
      # the hub before a consumer could ask for it.
      {superseded, [newest]} = Enum.split(frames, length(frames) - 1)

      state
      |> shed(superseded)
      |> take(newest, monotonic_time, wall_time)
    end
  end

  defp take(%{started: true} = state, frame, monotonic_time, wall_time),
    do: deliver(state, frame, monotonic_time, wall_time)

  defp take(state, {_data, info} = frame, monotonic_time, wall_time) do
    if state.pending do
      notify(state, {:dropped, 1})
    else
      # The first whole image is the only evidence that the device opened and
      # is producing. Until it arrives, nothing should be claiming capture has
      # started - ffmpeg returning from `Port.open/2` says only that ffmpeg
      # exists.
      notify(state, {:ready, info})
    end

    %{state | pending: {frame, monotonic_time, wall_time}}
  end

  defp shed(state, []), do: state

  defp shed(state, frames) do
    count = length(frames)
    notify(state, {:dropped, count})

    update_in(state.stats.dropped, &(&1 + count))
  end

  defp deliver(state, {data, info}, monotonic_time, wall_time) do
    frame = %{
      data: data,
      width: info.width,
      height: info.height,
      sequence: state.sequence,
      monotonic_time: monotonic_time,
      wall_time: wall_time,
      metadata: %{
        components: info.components,
        precision: info.precision,
        progressive?: info.progressive?
      }
    }

    case state.sink.(frame) do
      :ok -> :ok
      {:error, reason} -> notify(state, {:sink_error, reason})
    end

    state
    |> Map.put(:sequence, state.sequence + 1)
    |> update_in([:stats, :frames], &(&1 + 1))
    |> measure(monotonic_time)
  end

  # The requested frame rate is what ffmpeg was told; this is what the frames
  # actually did. They are reported separately and labelled differently,
  # because one of them is a measurement and the other is a request.
  defp measure(state, monotonic_time) do
    state = %{state | mean_interval_ns: smooth(state, monotonic_time)}

    if state.mean_interval_ns && rem(state.stats.frames, state.measure_every) == 0 do
      notify(state, {:measured_frame_rate, 1_000_000_000 / state.mean_interval_ns})
    end

    %{state | last_frame_time: monotonic_time}
  end

  defp smooth(%{last_frame_time: nil}, _monotonic_time), do: nil

  defp smooth(state, monotonic_time) do
    interval = monotonic_time - state.last_frame_time

    cond do
      interval <= 0 -> state.mean_interval_ns
      is_nil(state.mean_interval_ns) -> interval * 1.0
      true -> @interval_smoothing * interval + (1 - @interval_smoothing) * state.mean_interval_ns
    end
  end

  defp report_discards(state, discards) do
    Enum.reduce(discards, state, fn {:discarded, bytes, reason}, state ->
      notify(state, {:discarded, bytes, reason})

      update_in(state.stats.discarded_bytes, &(&1 + bytes))
    end)
  end

  defp notify(state, event), do: send(state.notify, {:bb_camera_v4l, self(), event})

  defp message_queue_len do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)

    length
  end

  defp reap(%{os_pid: nil}), do: :ok
  defp reap(state), do: Reaper.reap(state.reaper, state.os_pid)

  defp terminate_process(%{os_pid: nil}), do: :ok

  defp terminate_process(state) do
    if state.handle, do: state.backend.close(state.handle)
    Reaper.reap(state.reaper, state.os_pid)
    Reaper.release(state.reaper, state.os_pid)

    :ok
  end

  defp release(%{os_pid: nil}), do: :ok
  defp release(state), do: Reaper.release(state.reaper, state.os_pid)
end
