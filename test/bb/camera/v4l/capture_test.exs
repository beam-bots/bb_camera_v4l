# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.CaptureTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.V4L.{Capture, Command, Reaper}
  alias BB.Camera.V4L.Test.{JpegBuilder, StubBackend}

  defp command do
    {:ok, command} =
      Command.new(
        device: "/dev/video0",
        width: 640,
        height: 480,
        frame_rate: 30,
        executable: "/usr/bin/ffmpeg"
      )

    command
  end

  defp start_capture(context, opts \\ []) do
    test = self()

    reaper =
      start_supervised!(
        {Reaper,
         name: :"reaper_#{inspect(context.test)}",
         grace_ms: 0,
         signaller: fn os_pid, signal -> send(test, {:signalled, os_pid, signal}) end},
        id: :reaper
      )

    default_sink = fn frame ->
      send(test, {:frame, frame})
      :ok
    end

    sink = Keyword.get(opts, :sink, default_sink)
    hold? = Keyword.get(opts, :hold, false)

    opts =
      [
        backend: StubBackend,
        backend_opts: [report_to: test] ++ Keyword.take(opts, [:os_pid]),
        command: command(),
        notify: test,
        reaper: reaper,
        sink: sink
      ]
      |> Keyword.merge(Keyword.drop(opts, [:sink, :os_pid, :hold]))

    capture = start_supervised!({Capture, opts}, id: :capture, restart: :temporary)

    assert_receive {:stub_opened, stub, _command}

    unless hold?, do: Capture.go(capture)

    %{capture: capture, stub: stub, reaper: reaper}
  end

  describe "framing" do
    test "delivers a frame with the dimensions the image actually has", context do
      %{stub: stub} = start_capture(context)
      image = JpegBuilder.build(width: 1280, height: 720)

      :ok = StubBackend.feed(stub, image)

      assert_receive {:frame, frame}
      assert frame.data == image
      assert frame.width == 1280
      assert frame.height == 720
      assert frame.sequence == 0
      assert is_integer(frame.monotonic_time)
      assert is_integer(frame.wall_time)
      assert frame.metadata.components == 3
    end

    test "reports what the image says rather than what the camera was asked for", context do
      # The command asks for 640x480; the device hands back something else.
      %{stub: stub} = start_capture(context)

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 320, height: 180))

      assert_receive {:frame, frame}
      assert {frame.width, frame.height} == {320, 180}
    end

    test "reassembles a frame split across reads", context do
      %{stub: stub} = start_capture(context)
      image = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(2048))

      :ok = StubBackend.feed_all(stub, JpegBuilder.chunks(image, 100))

      assert_receive {:frame, frame}
      assert frame.data == image
    end

    test "numbers frames consecutively", context do
      %{stub: stub} = start_capture(context)

      for index <- 0..3 do
        :ok = StubBackend.feed(stub, JpegBuilder.build(width: 16 + index, height: 16))
        assert_receive {:frame, frame}
        assert frame.sequence == index
      end
    end

    test "starts numbering where a previous capture left off", context do
      %{stub: stub} = start_capture(context, sequence_start: 97)

      :ok = StubBackend.feed(stub, JpegBuilder.build())

      assert_receive {:frame, frame}
      assert frame.sequence == 97
    end

    test "reports discarded bytes without reporting their contents", context do
      %{stub: stub, capture: capture} = start_capture(context)
      garbage = :binary.copy(<<0x42>>, 64)

      :ok = StubBackend.feed(stub, garbage <> JpegBuilder.build())

      assert_receive {:bb_camera_v4l, ^capture, {:discarded, 64, :desynchronised}}
      assert_receive {:frame, _frame}
      assert Capture.stats(capture).discarded_bytes == 64
    end

    test "delivers only the newest frame from a read that held several", context do
      %{stub: stub, capture: capture} = start_capture(context)

      images = for size <- [16, 32, 64], do: JpegBuilder.build(width: size, height: size)

      :ok = StubBackend.feed(stub, JpegBuilder.stream(images))

      assert_receive {:bb_camera_v4l, ^capture, {:dropped, 2}}
      assert_receive {:frame, frame}
      assert frame.width == 64

      refute_received {:frame, _other}
      assert Capture.stats(capture) == %{frames: 1, dropped: 2, discarded_bytes: 0}
    end
  end

  describe "confirmation before delivery" do
    test "holds frames until capture has been confirmed", context do
      %{stub: stub, capture: capture} = start_capture(context, hold: true)

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 16, height: 16))

      # Pushing a call through proves the read has been handled, so an empty
      # mailbox here means the frame is being held rather than merely late.
      Capture.stats(capture)
      refute_received {:frame, _frame}

      :ok = Capture.go(capture)
      assert_receive {:frame, %{width: 16}}
    end

    test "delivers the newest held frame and nothing staler", context do
      %{stub: stub, capture: capture} = start_capture(context, hold: true)

      for size <- [16, 32, 48] do
        :ok = StubBackend.feed(stub, JpegBuilder.build(width: size, height: size))
      end

      :ok = Capture.go(capture)

      assert_receive {:frame, %{width: 48}}
      refute_received {:frame, _other}
    end
  end

  describe "ingress bounds" do
    test "sheds frames while the mailbox is backed up, and resumes after", context do
      test = self()

      # Only the first frame holds the capture up; the rest go straight through,
      # so what happens next depends on the backlog and nothing else.
      gate = fn
        %{width: 16} = frame ->
          send(test, {:frame, frame})
          receive do: (:release -> :ok)

        frame ->
          send(test, {:frame, frame})
          :ok
      end

      %{stub: stub, capture: capture} = start_capture(context, sink: gate, drop_queue_len: 1)

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 16, height: 16))
      assert_receive {:frame, %{width: 16}}

      # The capture is blocked inside the sink, so these pile up behind it.
      for size <- [32, 48, 64, 80] do
        :ok = StubBackend.feed(stub, JpegBuilder.build(width: size, height: size))
      end

      send(capture, :release)

      assert_receive {:bb_camera_v4l, ^capture, {:dropped, 1}}

      # The backlog drains and delivery resumes by itself: the last read, with
      # nothing queued behind it, is delivered rather than shed.
      assert_receive {:frame, %{width: 80}}
      assert Capture.stats(capture).dropped > 0
    end

    test "stops rather than letting the mailbox grow without limit", context do
      test = self()

      gate = fn frame ->
        send(test, {:frame, frame})

        receive do
          :release -> :ok
        end
      end

      %{stub: stub, capture: capture} =
        start_capture(context, sink: gate, drop_queue_len: 1, fail_queue_len: 2)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 16, height: 16))
      assert_receive {:frame, _first}

      for size <- [32, 48, 64, 80] do
        :ok = StubBackend.feed(stub, JpegBuilder.build(width: size, height: size))
      end

      send(capture, :release)

      assert_receive {:bb_camera_v4l, ^capture, {:overloaded, queue_len}}
      assert queue_len > 2
      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, :overload}}
    end
  end

  describe "lifecycle" do
    test "asks ffmpeg to stop before signalling it", context do
      %{stub: stub, capture: capture} = start_capture(context)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = Capture.stop(capture)

      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb_camera_v4l, ^capture, {:exited, 0}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, :normal}
      refute_received {:signalled, _os_pid, _signal}
    end

    test "signals the OS process when it ignores the polite request", context do
      os_pid = String.to_integer(System.pid())

      %{stub: stub, capture: capture} =
        start_capture(context, os_pid: os_pid, stop_timeout_ms: 0)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      assert Capture.stop(capture) == :ok

      assert_receive {:stub_stop_requested, ^stub}
      assert_receive {:signalled, ^os_pid, :sigterm}

      # Signalled and gone are different things, and the caller needs the
      # second one before it reopens the device.
      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, :teardown_unconfirmed}}
    end

    test "stays alive until the signalled process really exits", context do
      os_pid = String.to_integer(System.pid())

      %{stub: stub, capture: capture} =
        start_capture(context, os_pid: os_pid, stop_timeout_ms: 0)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      assert Capture.stop(capture) == :ok
      assert_receive {:signalled, ^os_pid, :sigterm}

      # The signal worked, just not instantly.
      :ok = StubBackend.exited(stub, 143)

      assert_receive {:bb_camera_v4l, ^capture, {:exited, 143}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, :normal}
    end

    test "trips overload on a producer whose bytes never become a frame", context do
      test = self()

      gate = fn frame ->
        send(test, {:frame, frame})
        receive do: (:release -> :ok)
      end

      %{stub: stub, capture: capture} =
        start_capture(context, sink: gate, drop_queue_len: 1, fail_queue_len: 2)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 16, height: 16))
      assert_receive {:frame, _first}

      # Garbage that never completes an image, so nothing ever reaches the
      # frame-handling path where the check used to live.
      for _ <- 1..5 do
        :ok = StubBackend.feed(stub, :binary.copy(<<0x5A>>, 4096))
      end

      send(capture, :release)

      assert_receive {:bb_camera_v4l, ^capture, {:overloaded, _queue_len}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, :overload}}
    end

    test "registers the OS process with the reaper so a crash cannot orphan it", context do
      os_pid = String.to_integer(System.pid())

      %{capture: capture, reaper: reaper} = start_capture(context, os_pid: os_pid)

      assert %{watched: watched} = :sys.get_state(reaper)
      assert Map.has_key?(watched, os_pid)

      Process.unlink(capture)
      monitor = Process.monitor(capture)
      Process.exit(capture, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^capture, :killed}
      assert_receive {:signalled, ^os_pid, :sigterm}
    end

    test "reports an unexpected exit and stops", context do
      %{stub: stub, capture: capture} = start_capture(context)

      Process.unlink(capture)
      monitor = Process.monitor(capture)

      :ok = StubBackend.exited(stub, 1)

      assert_receive {:bb_camera_v4l, ^capture, {:exited, 1}}
      assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, 1}}}
    end

    test "reports a sink that refuses a frame", context do
      %{stub: stub, capture: capture} =
        start_capture(context, sink: fn _frame -> {:error, :too_stale} end)

      :ok = StubBackend.feed(stub, JpegBuilder.build())

      assert_receive {:bb_camera_v4l, ^capture, {:sink_error, :too_stale}}
    end
  end
end
