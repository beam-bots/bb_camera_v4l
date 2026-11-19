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

  ## Passthrough versus transcode

  When the camera is asked for MJPEG, the stream is already a sequence of JPEG
  images, and ffmpeg copies packets through without touching them: no decode,
  no re-encode, no quality loss, and almost no CPU. That is the intended path
  and the default.

  When it is asked for anything else — `yuyv422` on a camera with no MJPEG
  mode — ffmpeg has to encode, and `:quality` starts to matter. The encoded
  path costs real CPU per frame and is the fallback, not the goal.
  """

  alias BB.Camera.FFmpeg.FrameRate

  defstruct [:source, :width, :height, :frame_rate, :input_format, :quality, :executable]

  @typedoc """
  Where the frames come from.

  `{:device, path}` is a real camera. `{:lavfi, filter}` is one of ffmpeg's own
  synthetic sources, which produces a genuine MJPEG stream through the real
  encoder and the real pipe without any hardware — useful for proving the
  pipeline works before blaming the camera.
  """
  @type source :: {:device, String.t()} | {:lavfi, String.t()}

  @type t :: %__MODULE__{
          source: source(),
          width: pos_integer(),
          height: pos_integer(),
          frame_rate: FrameRate.t(),
          input_format: String.t(),
          quality: pos_integer(),
          executable: String.t()
        }

  @type error ::
          {:invalid_device, term()}
          | {:invalid_dimension, term()}
          | {:invalid_frame_rate, term()}
          | {:invalid_input_format, term()}
          | {:invalid_quality, term()}
          | {:invalid_lavfi_source, term()}
          | {:no_source, term()}
          | {:ffmpeg_not_found, term()}

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
  - `:width`, `:height` — any positive pixel dimensions. There is no list of
    accepted sizes here: what a camera supports is a property of the camera,
    and this driver does not enumerate it. Ask for what you want; the frames
    report what you got.
  - `:frame_rate` — see `BB.Camera.FFmpeg.FrameRate`.
  - `:input_format` — the V4L2 pixel format to request, as ffmpeg names it.
    Default `"mjpeg"`, which is the passthrough path.
  - `:quality` — ffmpeg's `-q:v` for the MJPEG encoder, 1 (best) to 31.
    Ignored on the passthrough path. Default `5`.
  - `:executable` — path to ffmpeg. Defaults to whatever is on `$PATH`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(opts) do
    with {:ok, source} <- validate_source(opts),
         {:ok, width} <- validate_dimension(Keyword.get(opts, :width)),
         {:ok, height} <- validate_dimension(Keyword.get(opts, :height)),
         {:ok, frame_rate} <- validate_frame_rate(Keyword.get(opts, :frame_rate)),
         {:ok, input_format} <- validate_input_format(Keyword.get(opts, :input_format, "mjpeg")),
         {:ok, quality} <- validate_quality(Keyword.get(opts, :quality, 5)),
         {:ok, executable} <- validate_executable(Keyword.get(opts, :executable)) do
      {:ok,
       %__MODULE__{
         source: source,
         width: width,
         height: height,
         frame_rate: frame_rate,
         input_format: input_format,
         quality: quality,
         executable: executable
       }}
    end
  end

  @doc """
  Is this command copying JPEG packets through rather than encoding them?
  """
  @spec passthrough?(t()) :: boolean()
  def passthrough?(%__MODULE__{source: {:lavfi, _filter}}), do: false
  def passthrough?(%__MODULE__{input_format: "mjpeg"}), do: true
  def passthrough?(%__MODULE__{}), do: false

  @doc """
  The argument vector, without the executable itself.

      iex> {:ok, command} = BB.Camera.V4L.Command.new(
      ...>   device: "/dev/video0", width: 640, height: 480,
      ...>   frame_rate: 30, executable: "/usr/bin/ffmpeg")
      iex> BB.Camera.V4L.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "v4l2", "-input_format",
       "mjpeg", "-video_size", "640x480", "-framerate", "30", "-i", "/dev/video0", "-an",
       "-c:v", "copy", "-f", "mjpeg", "-flush_packets", "1", "pipe:1"]

      iex> {:ok, command} = BB.Camera.V4L.Command.new(
      ...>   lavfi: "testsrc2", width: 320, height: 240,
      ...>   frame_rate: 10, executable: "/usr/bin/ffmpeg")
      iex> BB.Camera.V4L.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
       "testsrc2=size=320x240:rate=10", "-an", "-c:v", "mjpeg", "-q:v", "5",
       "-r", "10", "-f", "mjpeg", "-flush_packets", "1", "pipe:1"]
  """
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{} = command) do
    # `-nostdin` because ffmpeg's stdin is MuonTrap's flow-control channel;
    # see `BB.Camera.FFmpeg.Backend.MuonTrap`.
    ["-nostdin", "-hide_banner", "-loglevel", "error"] ++
      input_argv(command) ++
      ["-an"] ++
      codec_argv(command) ++
      ["-f", "mjpeg", "-flush_packets", "1", "pipe:1"]
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
  defp codec_argv(%__MODULE__{} = command) do
    if passthrough?(command) do
      ["-c:v", "copy"]
    else
      # Re-encoding is the only path where ffmpeg controls the output rate, so
      # it is the only path where capping it means anything.
      [
        "-c:v",
        "mjpeg",
        "-q:v",
        Integer.to_string(command.quality),
        "-r",
        FrameRate.to_string(command.frame_rate)
      ]
    end
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

  defp validate_quality(value) when is_integer(value) and value in 1..31, do: {:ok, value}
  defp validate_quality(value), do: {:error, {:invalid_quality, value}}

  defp validate_executable(nil) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, {:ffmpeg_not_found, "ffmpeg"}}
      path -> {:ok, path}
    end
  end

  defp validate_executable(path) when is_binary(path), do: {:ok, path}
  defp validate_executable(path), do: {:error, {:ffmpeg_not_found, path}}
end
