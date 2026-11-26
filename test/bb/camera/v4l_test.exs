# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4LTest do
  @moduledoc false
  # The stub reports to a registered name, which is global.
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Test.StubBackend
  alias BB.Camera.{Format, Media}
  alias BB.Camera.V4L
  alias BB.Camera.V4L.Test.StubBot
  alias BB.Error.Invalid.Camera.{UnknownStreamInfo, UnsupportedFormat}
  alias BB.Message.Camera.{BeginCapture, EndCapture}

  @format {:raw, :I420}
  @topic [:sensor, :head, :eye]

  setup do
    Process.register(self(), :bb_camera_v4l_stub_observer)
    start_supervised!(StubBot)

    :ok
  end

  describe "discovery" do
    test "finds the camera on a running robot" do
      assert [camera] = BB.Camera.discover(StubBot)
      assert camera.name == :eye
      assert camera.path == [:head, :eye]
      assert camera.module == BB.Camera.V4L
      assert camera.stream_info.format == @format
      assert {camera.stream_info.width, camera.stream_info.height} == {640, 480}
    end

    test "reports no device path, url or credential through discovery" do
      [camera] = BB.Camera.discover(StubBot)

      refute camera |> Map.from_struct() |> Map.has_key?(:options)
      refute camera |> inspect(limit: :infinity) |> String.contains?("/dev/video0")
    end
  end

  describe "stream_info/1" do
    test "is pure, and answers for a robot that was never started" do
      assert {:ok, info} =
               V4L.stream_info(device: "/dev/video9", width: 320, height: 200)

      assert {info.width, info.height} == {320, 200}
      assert info.format == @format
    end

    test "refuses to guess when an option is an unresolved parameter reference" do
      assert {:error, %UnknownStreamInfo{}} =
               V4L.stream_info(device: "/dev/video0", width: {:param, [:camera, :w]})
    end
  end

  describe "one capture, many consumers" do
    test "two consumers share a single capture" do
      {:ok, first} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      {:ok, second} = Media.open(StubBot, :eye, format: @format)

      # A second ffmpeg would have announced itself here.
      refute_received {:stub_opened, _other, _command}

      image = frame_of(640, 480)
      :ok = StubBackend.feed(stub, image)

      assert {:ok, frame_one} = Media.next(first, 5_000)
      assert {:ok, frame_two} = Media.next(second, 5_000)
      assert frame_one.data == image
      assert frame_two.data == image

      Media.close(first)
      Media.close(second)
    end

    test "no second capture is opened until the first has really gone" do
      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}

      # The stub has been asked to stop but has not exited, so as far as this
      # driver knows ffmpeg still holds the device.
      {:ok, _session} = Media.open(StubBot, :eye, format: @format)

      # A synchronous round trip through the hub proves the request has been
      # handled, so an empty mailbox means no second capture was opened.
      BB.Camera.stream_info(StubBot, :eye)
      refute_received {:stub_opened, _other, _command}

      # Once the old one is really gone, the new one starts.
      :ok = StubBackend.exited(stub, 0)
      assert_receive {:stub_opened, second, _command}
      refute second == stub
    end

    test "capture stops when the last consumer leaves, and starts again for the next" do
      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, _stub, _command}

      Media.close(session)
    end
  end

  describe "lifecycle on pubsub" do
    test "publishes capture start and end, and never a frame" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      # Nothing has been captured yet, so nothing claims it has been.
      BB.Camera.stream_info(StubBot, :eye)
      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = StubBackend.feed(stub, frame_of(640, 480))

      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{} = begun}}
      assert begun.stream_info.format == @format

      assert {:ok, _frame} = Media.next(session, 5_000)

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason in [:no_subscribers, :driver_stopped]

      refute_received {:bb, @topic, %BB.Message{payload: %{data: _data}}}
    end

    test "a capture that never produces a frame is a failure, not a beginning" do
      BB.subscribe(StubBot, @topic)

      {:ok, _session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      # ffmpeg exits non-zero without ever writing a frame, which is what a
      # missing or busy device looks like.
      :ok = StubBackend.exited(stub, 1)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason == :error
      assert ended.error

      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}
    end
  end

  describe "the frames it delivers" do
    test "are I420 at the configured size, with the bytes ffmpeg wrote" do
      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}

      data = frame_of(640, 480)
      :ok = StubBackend.feed(stub, data)

      assert {:ok, frame} = Media.next(session, 5_000)
      assert frame.format == @format
      assert {frame.width, frame.height} == {640, 480}
      assert frame.data == data

      Media.close(session)
    end
  end

  describe "dimensions I420 cannot take" do
    test "are refused when the options are read" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions}} =
               V4L.stream_info(device: "/dev/video0", width: 641, height: 480)

      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions}} =
               V4L.stream_info(device: "/dev/video0", width: 640, height: 479)
    end
  end

  describe "reconfiguring from a parameter" do
    test "a new width restarts capture with it" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, stub, _command}
      :ok = StubBackend.feed(stub, frame_of(640, 480))
      assert {:ok, _frame} = Media.next(session, 5_000)
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = BB.Parameter.set(StubBot, [:camera, :width], 320)

      # The running capture has to be gone before a replacement is opened.
      assert_receive {:stub_stop_requested, ^stub}
      refute_received {:stub_opened, _other, _command}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{reason: :driver_stopped}}}
      assert_receive {:stub_opened, restarted, {_executable, args, _opts}}
      assert "320x480" in args

      # And the replacement only claims to be capturing once it really is.
      :ok = StubBackend.feed(restarted, frame_of(320, 480))
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}
    end

    test "a value the parameter's own type refuses never reaches the driver" do
      assert {:error, _reason} = BB.Parameter.set(StubBot, [:camera, :width], "wide")
    end

    test "a value only the driver refuses takes the camera down with it" do
      # `-1` satisfies the parameter's `type: :integer` and is stored, then
      # fails the driver's `:pos_integer`. `handle_options/2` has no way to
      # refuse and stay running, so the sensor stops - and restarts into the
      # same stored value. This asserts the trap rather than endorsing it;
      # see the note on `handle_options/2` in `BB.Camera.V4L`.
      sensor = BB.Process.whereis(StubBot, :eye)
      monitor = Process.monitor(sensor)

      :ok = BB.Parameter.set(StubBot, [:camera, :width], -1)

      assert_receive {:DOWN, ^monitor, :process, ^sensor, _reason}
    end
  end

  describe "the ffmpeg command" do
    test "is built from the declared options without a shell" do
      {:ok, session} = Media.open(StubBot, :eye, format: @format)
      assert_receive {:stub_opened, _stub, {executable, argv, _opts}}

      assert executable == "/nonexistent/ffmpeg"
      assert "-nostdin" in argv
      assert "/dev/video0" in argv
      assert "640x480" in argv
      assert "30" in argv
      assert Enum.all?(argv, &is_binary/1)

      Media.close(session)
    end
  end

  defp frame_of(width, height) do
    {:ok, size} = Format.frame_size(@format, width, height)

    :binary.copy(<<128>>, size)
  end
end
