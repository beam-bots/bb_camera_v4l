# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.FFmpegTest do
  @moduledoc """
  The one test that runs ffmpeg for real.

  Everything else stubs the backend, which is right for asserting on behaviour
  but proves nothing about whether the command this driver builds actually
  produces JPEGs. This runs the whole path — argv, port, encoder, pipe,
  framer, reaper — against a synthetic ffmpeg source, so it needs ffmpeg but
  not a camera.

  Tagged `:ffmpeg` and excluded by default. Run it with
  `mix test --include ffmpeg`.
  """
  use ExUnit.Case, async: false

  alias BB.Camera.V4L.{Capture, Command, Reaper}

  @moduletag :ffmpeg

  setup do
    unless System.find_executable("ffmpeg") do
      flunk("ffmpeg is not on $PATH")
    end

    :ok
  end

  defp start_capture(context, command_opts) do
    test = self()

    reaper =
      start_supervised!({Reaper, name: :"ffmpeg_reaper_#{inspect(context.test)}", grace_ms: 500},
        id: :reaper
      )

    {:ok, command} = Command.new(command_opts)

    sink = fn frame ->
      send(test, {:frame, frame})
      :ok
    end

    capture =
      start_supervised!(
        {Capture, command: command, notify: test, reaper: reaper, sink: sink},
        id: :capture,
        restart: :temporary
      )

    :ok = Capture.go(capture)

    %{capture: capture, reaper: reaper}
  end

  test "captures real JPEG frames through the real command", context do
    %{capture: capture} =
      start_capture(context, lavfi: "testsrc2", width: 320, height: 240, frame_rate: 10)

    # ffmpeg takes a moment to start; the bound is generous because it is an
    # upper bound on an event that must happen, not an estimate of how long
    # starting takes.
    assert_receive {:frame, first}, 20_000

    # The dimensions come out of the JPEG the encoder actually produced.
    assert {first.width, first.height} == {320, 240}
    assert <<0xFF, 0xD8, _rest::binary>> = first.data
    assert binary_part(first.data, byte_size(first.data) - 2, 2) == <<0xFF, 0xD9>>
    assert first.sequence == 0

    assert_receive {:frame, second}, 20_000
    assert second.sequence > first.sequence
    assert second.monotonic_time >= first.monotonic_time

    assert Capture.stats(capture).frames >= 2
  end

  test "asking for a different size gets a different size", context do
    start_capture(context, lavfi: "testsrc2", width: 176, height: 144, frame_rate: 10)

    assert_receive {:frame, frame}, 20_000
    assert {frame.width, frame.height} == {176, 144}
  end

  test "stopping leaves no ffmpeg behind", context do
    %{capture: capture} =
      start_capture(context, lavfi: "testsrc2", width: 160, height: 120, frame_rate: 10)

    assert_receive {:frame, _frame}, 20_000

    %{os_pid: os_pid} = :sys.get_state(capture)
    assert is_integer(os_pid)
    assert Reaper.running?(os_pid)

    Process.unlink(capture)
    monitor = Process.monitor(capture)
    :ok = Capture.stop(capture)

    assert_receive {:DOWN, ^monitor, :process, ^capture, _reason}, 20_000
    refute Reaper.running?(os_pid)
  end

  test "killing the capture outright still leaves no ffmpeg behind", context do
    %{capture: capture, reaper: reaper} =
      start_capture(context, lavfi: "testsrc2", width: 160, height: 120, frame_rate: 10)

    assert_receive {:frame, _frame}, 20_000

    %{os_pid: os_pid} = :sys.get_state(capture)
    assert Reaper.running?(os_pid)

    Process.unlink(capture)
    monitor = Process.monitor(capture)
    Process.exit(capture, :kill)

    waiter = watch_process_exit(os_pid)

    assert_receive {:DOWN, ^monitor, :process, ^capture, :killed}

    # The reaper is the only thing left that knows about the process, and a
    # round trip through it proves it has handled the owner's death.
    :sys.get_state(reaper)

    assert_receive {^waiter, {:exit_status, _status}}, 20_000
    refute Reaper.running?(os_pid)
  end

  test "a device that does not exist fails rather than hanging", context do
    %{capture: capture} =
      start_capture(context,
        device: "/dev/video-definitely-not-here",
        width: 320,
        height: 240,
        frame_rate: 10
      )

    Process.unlink(capture)
    monitor = Process.monitor(capture)

    assert_receive {:bb_camera_v4l, ^capture, {:exited, status}}, 20_000
    assert status != 0
    assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, ^status}}}
    refute_received {:frame, _frame}
  end

  # A process that is not our child cannot be waited on from the BEAM, and
  # `/proc` offers no event - so this borrows one. `tail --pid` exits when the
  # process it was given exits, and a port on it turns that into a message.
  # Polling still happens, but in coreutils rather than in the test, and what
  # the test waits on is an event rather than an interval.
  defp watch_process_exit(os_pid) do
    case System.find_executable("tail") do
      nil ->
        flunk("`tail` is needed to observe an OS process exiting")

      tail ->
        Port.open({:spawn_executable, tail}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: ["--pid=#{os_pid}", "-f", "/dev/null"]
        ])
    end
  end
end
