# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Command do
  @moduledoc """
  The ffmpeg invocation for one capture, built and validated up front.

  Keeping this separate from the process that runs it means the exact argument
  vector for a given set of camera options is a pure function, and can be
  asserted on without a camera, without ffmpeg, and without starting anything.
  Given how much of "why is this camera not working" turns out to be a wrong
  flag, that is the part most worth being able to see.

  ## No shell, ever

  The vector is handed to `Port.open/2` with `:spawn_executable`, which calls
  `execve` directly. There is no shell, so no amount of punctuation in a device
  path can turn into a command. The validation here is not defending against
  that; it is defending against arguments that are merely *wrong* — a device
  path beginning with `-` that ffmpeg would read as a flag, a format name that
  is not a format name.

  ## What comes out

  Always raw I420 (ffmpeg's `yuv420p`), full-range, at exactly `:width` x
  `:height`, whatever the camera sends. Raw video doesn't describe itself, and
  ffmpeg's console output is not captured, so nothing downstream could find
  out what ffmpeg actually produced; the output size and pixel format are
  forced by the scale filter instead, and the driver sizes frames from the
  same numbers.

  If the device hands back a different size than it was asked for, ffmpeg
  scales it to the requested one, stretching it if the aspect ratio differs.
  Consistent frames are worth more here than the device's native geometry.

  `:input_format` chooses only what the camera sends. MJPEG, the default, is
  usually the only way to get a high frame rate over USB 2; ffmpeg decodes it
  either way.
  """

  alias BB.Camera.FFmpeg.FrameRate
  alias BB.Camera.Format
  alias BB.Error.Invalid.Camera.UnsupportedFormat

  # `yuv420p` in the argument vector is ffmpeg's name for I420.
  @format {:raw, :I420}

  defstruct [:source, :width, :height, :frame_rate, :input_format, :frame_bytes, :executable]

  @typedoc """
  Where the frames come from.

  `{:device, path}` is a real camera. `{:lavfi, filter}` is one of ffmpeg's own
  synthetic sources, which runs the real scaler and the real pipe without any
  hardware — useful for proving the pipeline works before blaming the camera.
  """
  @type source :: {:device, String.t()} | {:lavfi, String.t()}

  @type t :: %__MODULE__{
          source: source(),
          width: pos_integer(),
          height: pos_integer(),
          frame_rate: FrameRate.t(),
          input_format: String.t(),
          frame_bytes: pos_integer(),
          executable: String.t()
        }

  @type error ::
          {:invalid_device, term()}
          | {:invalid_dimension, term()}
          | {:invalid_frame_rate, term()}
          | {:invalid_input_format, term()}
          | {:invalid_lavfi_source, term()}
          | {:no_source, term()}
          | {:ffmpeg_not_found, term()}
          | UnsupportedFormat.t()

  @format_pattern ~r/\A[a-z0-9_]+\z/

  @doc """
  Build and validate a command.

  ## Options

  - `:device` — path to the V4L2 device node, e.g. `/dev/video0` or a
    `/dev/v4l/by-id/...` symlink. Required, unless `:lavfi` is given.
  - `:lavfi` — the name of an ffmpeg synthetic source such as `"testsrc2"`,
    instead of a device. Only the bare filter name is accepted; the size and
    rate are filled in from `:width`, `:height` and `:frame_rate`, so there is
    one source of truth for them and no filtergraph to get wrong.
  - `:width`, `:height` — positive, even pixel dimensions; I420 halves both
    for its chroma planes, so an odd one is refused with
    `BB.Error.Invalid.Camera.UnsupportedFormat`. There is no list of accepted
    sizes here: what a camera supports is a property of the camera, and this
    driver does not enumerate it. These are also the size of every frame
    written, whatever the camera sends.
  - `:frame_rate` — see `BB.Camera.FFmpeg.FrameRate`.
  - `:input_format` — the V4L2 pixel format to request, as ffmpeg names it.
    Default `"mjpeg"`.
  - `:executable` — path to ffmpeg. Defaults to whatever is on `$PATH`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(opts) do
    with {:ok, source} <- validate_source(opts),
         {:ok, width} <- validate_dimension(Keyword.get(opts, :width)),
         {:ok, height} <- validate_dimension(Keyword.get(opts, :height)),
         {:ok, frame_rate} <- validate_frame_rate(Keyword.get(opts, :frame_rate)),
         {:ok, input_format} <- validate_input_format(Keyword.get(opts, :input_format, "mjpeg")),
         {:ok, frame_bytes} <- Format.frame_size(@format, width, height),
         {:ok, executable} <- validate_executable(Keyword.get(opts, :executable)) do
      {:ok,
       %__MODULE__{
         source: source,
         width: width,
         height: height,
         frame_rate: frame_rate,
         input_format: input_format,
         frame_bytes: frame_bytes,
         executable: executable
       }}
    end
  end

  @doc """
  The format every command writes: full-range I420.
  """
  @spec format() :: Format.t()
  def format, do: @format

  @doc """
  The argument vector, without the executable itself.

      iex> {:ok, command} = BB.Camera.V4L.Command.new(
      ...>   device: "/dev/video0", width: 640, height: 480,
      ...>   frame_rate: 30, executable: "/usr/bin/ffmpeg")
      iex> BB.Camera.V4L.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "v4l2", "-input_format",
       "mjpeg", "-video_size", "640x480", "-framerate", "30", "-i", "/dev/video0", "-an",
       "-vf", "scale=640:480:out_range=full,format=yuv420p", "-fps_mode", "passthrough",
       "-f", "rawvideo", "-flush_packets", "1", "pipe:1"]

      iex> {:ok, command} = BB.Camera.V4L.Command.new(
      ...>   lavfi: "testsrc2", width: 320, height: 240,
      ...>   frame_rate: 10, executable: "/usr/bin/ffmpeg")
      iex> BB.Camera.V4L.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
       "testsrc2=size=320x240:rate=10", "-an", "-vf",
       "scale=320:240:out_range=full,format=yuv420p", "-fps_mode", "passthrough",
       "-f", "rawvideo", "-flush_packets", "1", "pipe:1"]
  """
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{} = command) do
    # `-nostdin` because ffmpeg's stdin is MuonTrap's flow-control channel;
    # see `BB.Camera.FFmpeg.Backend.MuonTrap`.
    ["-nostdin", "-hide_banner", "-loglevel", "error"] ++
      input_argv(command) ++
      ["-an"] ++
      output_argv(command)
  end

  defp input_argv(%__MODULE__{source: {:device, path}} = command) do
    [
      "-f",
      "v4l2",
      "-input_format",
      command.input_format,
      "-video_size",
      "#{command.width}x#{command.height}",
      "-framerate",
      FrameRate.to_string(command.frame_rate),
      "-i",
      path
    ]
  end

  defp input_argv(%__MODULE__{source: {:lavfi, filter}} = command) do
    graph =
      "#{filter}=size=#{command.width}x#{command.height}" <>
        ":rate=#{FrameRate.to_string(command.frame_rate)}"

    # A synthetic source has no hardware pacing it, so without `-re` ffmpeg
    # generates frames as fast as it can encode them - thousands a second, and
    # nothing like the camera it is standing in for.
    ["-re", "-f", "lavfi", "-i", graph]
  end

  # `-flush_packets 1` keeps ffmpeg from holding finished frames in its output
  # buffer waiting for more; without it a low-rate camera's frames arrive in
  # lumps and the measured latency is the buffer, not the camera.
  #
  # `-fps_mode passthrough` because the rawvideo muxer otherwise defaults to a
  # constant rate, duplicating frames to fill any gap the camera leaves. A
  # duplicate would reach the hub as a new frame with a new timestamp, claiming
  # a capture that never happened.
  defp output_argv(%__MODULE__{} = command) do
    [
      "-vf",
      "scale=#{command.width}:#{command.height}:out_range=full,format=yuv420p",
      "-fps_mode",
      "passthrough",
      "-f",
      "rawvideo",
      "-flush_packets",
      "1",
      "pipe:1"
    ]
  end

  defp validate_source(opts) do
    case {Keyword.get(opts, :device), Keyword.get(opts, :lavfi)} do
      {nil, nil} -> {:error, {:no_source, nil}}
      {device, nil} -> with {:ok, path} <- validate_device(device), do: {:ok, {:device, path}}
      {nil, filter} -> with {:ok, name} <- validate_lavfi(filter), do: {:ok, {:lavfi, name}}
      {device, filter} -> {:error, {:no_source, {device, filter}}}
    end
  end

  defp validate_lavfi(filter) when is_binary(filter) do
    if Regex.match?(@format_pattern, filter) do
      {:ok, filter}
    else
      {:error, {:invalid_lavfi_source, filter}}
    end
  end

  defp validate_lavfi(filter), do: {:error, {:invalid_lavfi_source, filter}}

  defp validate_device(device) when is_binary(device) do
    cond do
      device == "" -> {:error, {:invalid_device, device}}
      String.contains?(device, <<0>>) -> {:error, {:invalid_device, device}}
      String.starts_with?(device, "-") -> {:error, {:invalid_device, device}}
      not String.starts_with?(device, "/") -> {:error, {:invalid_device, device}}
      true -> {:ok, device}
    end
  end

  defp validate_device(device), do: {:error, {:invalid_device, device}}

  defp validate_dimension(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_dimension(value), do: {:error, {:invalid_dimension, value}}

  defp validate_frame_rate(value) do
    case FrameRate.new(value) do
      {:ok, frame_rate} -> {:ok, frame_rate}
      {:error, _reason} -> {:error, {:invalid_frame_rate, value}}
    end
  end

  defp validate_input_format(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> validate_input_format()

  defp validate_input_format(value) when is_binary(value) do
    if Regex.match?(@format_pattern, value) do
      {:ok, value}
    else
      {:error, {:invalid_input_format, value}}
    end
  end

  defp validate_input_format(value), do: {:error, {:invalid_input_format, value}}

  defp validate_executable(nil) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, {:ffmpeg_not_found, "ffmpeg"}}
      path -> {:ok, path}
    end
  end

  defp validate_executable(path) when is_binary(path), do: {:ok, path}
  defp validate_executable(path), do: {:error, {:ffmpeg_not_found, path}}
end
