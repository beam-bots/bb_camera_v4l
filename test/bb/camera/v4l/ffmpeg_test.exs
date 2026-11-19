# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.FFmpegTest do
  @moduledoc """
  The tests that run this driver's ffmpeg command for real.

  The stubbed suite proves the driver's behaviour, and `bb_camera_ffmpeg`
  proves that capture under MuonTrap leaves nothing behind. Neither proves that
  the argument vector this driver builds is one ffmpeg accepts and turns into
  JPEGs. These do, against a synthetic source and against V4L2 itself.

  Tagged `:ffmpeg` and excluded by default. Run them with
  `mix test --include ffmpeg`. The `:linux` one needs ffmpeg's V4L2 input.
  """
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Capture
  alias BB.Camera.V4L.Command

  @moduletag :ffmpeg

  setup do
    unless System.find_executable("ffmpeg") do
      flunk("ffmpeg is not on $PATH")
    end

    :ok
  end

  defp start_capture(command_opts) do
    test = self()
    {:ok, command} = Command.new(command_opts)

    sink = fn frame ->
      send(test, {:frame, frame})
      :ok
    end

    capture =
      start_supervised!(
        {Capture,
         executable: command.executable, args: Command.argv(command), notify: test, sink: sink},
        id: :capture,
        restart: :temporary
      )

    :ok = Capture.go(capture)

    capture
  end

  test "the command produces JPEG frames of the size it asks for" do
    start_capture(lavfi: "testsrc2", width: 176, height: 144, frame_rate: 10)

    # The bound is an upper limit on an event that must happen, not an
    # estimate of how long ffmpeg takes to start.
    assert_receive {:frame, frame}, 20_000
    assert {frame.width, frame.height} == {176, 144}
    assert <<0xFF, 0xD8, _rest::binary>> = frame.data
  end

  @tag :linux
  test "a device that does not exist fails rather than hanging" do
    capture =
      start_capture(
        device: "/dev/video-definitely-not-here",
        width: 320,
        height: 240,
        frame_rate: 10
      )

    Process.unlink(capture)
    monitor = Process.monitor(capture)

    assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, status}}, 20_000
    assert status != 0
    assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, ^status}}}
    refute_received {:frame, _frame}
  end
end
