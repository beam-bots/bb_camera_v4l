# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.CommandTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.V4L.Command
  alias BB.Error.Invalid.Camera.UnsupportedFormat

  doctest BB.Camera.V4L.Command

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        device: "/dev/video0",
        width: 640,
        height: 480,
        frame_rate: 30,
        executable: "/usr/bin/ffmpeg"
      ],
      overrides
    )
  end

  describe "new/1" do
    test "accepts arbitrary positive even dimensions" do
      assert {:ok, command} = Command.new(options(width: 2, height: 2))
      assert {command.width, command.height} == {2, 2}

      assert {:ok, command} = Command.new(options(width: 3840, height: 2160))
      assert {command.width, command.height} == {3840, 2160}

      assert {:ok, command} = Command.new(options(width: 1234, height: 566))
      assert "1234x566" in Command.argv(command)
    end

    test "rejects odd dimensions, which I420 cannot take" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions, width: 641}} =
               Command.new(options(width: 641))

      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions, height: 481}} =
               Command.new(options(height: 481))
    end

    test "knows the size of one frame of what it writes" do
      assert {:ok, command} = Command.new(options(width: 1280, height: 720))
      assert command.frame_bytes == div(1280 * 720 * 3, 2)
      assert Command.format() == {:raw, :I420}
    end

    test "rejects dimensions that are not positive integers" do
      assert {:error, {:invalid_dimension, 0}} = Command.new(options(width: 0))
      assert {:error, {:invalid_dimension, -1}} = Command.new(options(height: -1))
      assert {:error, {:invalid_dimension, "640"}} = Command.new(options(width: "640"))
      assert {:error, {:invalid_dimension, 640.0}} = Command.new(options(width: 640.0))
    end

    test "keeps an exact rational frame rate" do
      assert {:ok, command} = Command.new(options(frame_rate: {30_000, 1001}))
      assert "30000/1001" in Command.argv(command)
    end

    test "accepts a frame rate as a hertz unit" do
      import BB.Unit

      assert {:ok, command} = Command.new(options(frame_rate: ~u(15 hertz)))
      assert "15" in Command.argv(command)
    end

    test "rejects a frame rate that is not positive" do
      assert {:error, {:invalid_frame_rate, 0}} = Command.new(options(frame_rate: 0))
      assert {:error, {:invalid_frame_rate, -5}} = Command.new(options(frame_rate: -5))
      assert {:error, {:invalid_frame_rate, {30, 0}}} = Command.new(options(frame_rate: {30, 0}))
    end

    test "rejects a device path that ffmpeg would read as a flag" do
      assert {:error, {:invalid_device, "-f"}} = Command.new(options(device: "-f"))
    end

    test "rejects a device path that is not absolute" do
      assert {:error, {:invalid_device, "video0"}} = Command.new(options(device: "video0"))
    end

    test "rejects a device path containing a null byte" do
      assert {:error, {:invalid_device, _}} = Command.new(options(device: "/dev/video0" <> <<0>>))
    end

    test "accepts a by-id device symlink" do
      path = "/dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920-video-index0"

      assert {:ok, command} = Command.new(options(device: path))
      assert path in Command.argv(command)
    end

    test "rejects a pixel format that is not a format name" do
      assert {:error, {:invalid_input_format, "mjpeg; rm -rf /"}} =
               Command.new(options(input_format: "mjpeg; rm -rf /"))

      assert {:error, {:invalid_input_format, "-i"}} = Command.new(options(input_format: "-i"))
    end

    test "accepts any plausible format name without a list of its own" do
      for format <- [:mjpeg, :yuyv422, :nv12, "rgb565le"] do
        assert {:ok, _command} = Command.new(options(input_format: format))
      end
    end
  end

  describe "argv/1" do
    test "forces full-range I420 at the configured size, whatever the camera sends" do
      for input_format <- [:mjpeg, :yuyv422] do
        {:ok, command} =
          Command.new(options(input_format: input_format, width: 1280, height: 720))

        assert argv_pair(command, "-input_format") == Atom.to_string(input_format)
        assert argv_pair(command, "-vf") == "scale=1280:720:out_range=full,format=yuv420p"
      end
    end

    test "never invents frames to hold a constant rate" do
      {:ok, command} = Command.new(options())
      argv = Command.argv(command)

      assert argv_pair(command, "-fps_mode") == "passthrough"
      refute "-r" in argv
    end

    test "writes raw video to stdout, never to a file" do
      {:ok, command} = Command.new(options())
      argv = Command.argv(command)

      assert Enum.take(argv, -5) == ["-f", "rawvideo", "-flush_packets", "1", "pipe:1"]
      assert argv_pair(command, "-f") == "v4l2"
    end

    test "never lets ffmpeg read stdin, which belongs to MuonTrap" do
      {:ok, command} = Command.new(options())

      assert "-nostdin" in Command.argv(command)
    end

    test "never produces an argument that is not a plain string" do
      {:ok, command} = Command.new(options(frame_rate: {30_000, 1001}, width: 1280, height: 720))

      assert Enum.all?(Command.argv(command), &is_binary/1)
    end
  end

  defp argv_pair(command, flag) do
    argv = Command.argv(command)

    Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)
  end
end
