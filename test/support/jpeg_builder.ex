# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Test.JpegBuilder do
  @moduledoc """
  Builds structurally valid JPEG byte streams for testing the scanner.

  The scanner's job is to be right about the awkward cases — stuffed bytes,
  restart markers, fill bytes, an `EOI` buried inside an EXIF thumbnail — and
  real camera output gives no control over which of those show up in a given
  capture. This builder makes each one reproducible on demand.

  The images are structurally valid, not decodable: quantisation and Huffman
  tables are filler. Nothing here decodes a JPEG, so that costs nothing, and it
  keeps the fixtures small enough to assert on byte-exactly.
  """

  @soi <<0xFF, 0xD8>>
  @eoi <<0xFF, 0xD9>>

  @doc """
  Build one JPEG image.

  ## Options

  - `:width`, `:height` — dimensions written into the frame header. Default
    `64` x `48`.
  - `:components` — number of colour components. Default `3`.
  - `:sampling` — the luma component's `{horizontal, vertical}` sampling
    factors, which decide the chroma format. Default `{2, 2}`, which is 4:2:0.
  - `:precision` — sample precision in bits. Default `8`.
  - `:progressive?` — emit an `SOF2` rather than an `SOF0` frame header.
    Default `false`.
  - `:frame_header?` — emit a frame header at all. Default `true`; `false`
    builds the degenerate marker-soup image that has no dimensions.
  - `:entropy` — bytes for the scan. Any `0xFF` is byte-stuffed for you, so
    arbitrary binaries are safe to pass. Default 256 bytes including an
    explicit `0xFF`.
  - `:restarts` — how many `RST` markers to interleave into the scan data.
    Default `0`.
  - `:segments` — `{marker_byte, payload}` pairs emitted before the frame
    header, for `APP`/`COM` segments. Default `[]`.
  - `:fill` — how many `0xFF` fill bytes to put before the `EOI` marker.
    Default `0`.
  - `:scans` — how many scans to emit. More than one is what a progressive
    image looks like. Default `1`.
  """
  @spec build(keyword()) :: binary()
  def build(opts \\ []) do
    width = Keyword.get(opts, :width, 64)
    height = Keyword.get(opts, :height, 48)
    components = Keyword.get(opts, :components, 3)
    sampling = Keyword.get(opts, :sampling, {2, 2})
    precision = Keyword.get(opts, :precision, 8)
    progressive? = Keyword.get(opts, :progressive?, false)
    frame_header? = Keyword.get(opts, :frame_header?, true)
    entropy = Keyword.get(opts, :entropy, default_entropy())
    restarts = Keyword.get(opts, :restarts, 0)
    segments = Keyword.get(opts, :segments, [])
    fill = Keyword.get(opts, :fill, 0)
    scans = Keyword.get(opts, :scans, 1)

    header =
      if frame_header? do
        sof_marker = if progressive?, do: 0xC2, else: 0xC0
        [segment(sof_marker, frame_header(precision, height, width, components, sampling))]
      else
        []
      end

    scan_data = stuff(entropy) |> with_restarts(restarts)

    body =
      for _ <- 1..scans//1 do
        [segment(0xDA, scan_header(components)), scan_data]
      end

    IO.iodata_to_binary([
      @soi,
      jfif_segment(),
      Enum.map(segments, fn {marker, payload} -> segment(marker, payload) end),
      header,
      body,
      :binary.copy(<<0xFF>>, fill),
      @eoi
    ])
  end

  @doc """
  An `APP1` segment carrying a whole JPEG, the way an EXIF thumbnail does.

  Pass it through `:segments` to build an image that contains `FF D9` long
  before its own end — the case that breaks framing by naive marker search.
  """
  @spec thumbnail_segment(keyword()) :: {byte(), binary()}
  def thumbnail_segment(opts \\ []) do
    {0xE1, "Exif\0\0" <> build(Keyword.merge([width: 16, height: 16], opts))}
  end

  @doc """
  Concatenate images into an MJPEG stream.
  """
  @spec stream([binary()]) :: binary()
  def stream(images), do: IO.iodata_to_binary(images)

  @doc """
  Split a binary into chunks of at most `size` bytes.

  Capture hands over whatever the pipe had ready, so every boundary is a
  boundary the framer has to survive.
  """
  @spec chunks(binary(), pos_integer()) :: [binary()]
  def chunks(<<>>, _size), do: []

  def chunks(binary, size) when byte_size(binary) <= size, do: [binary]

  def chunks(binary, size) do
    <<head::binary-size(^size), rest::binary>> = binary
    [head | chunks(rest, size)]
  end

  defp frame_header(precision, height, width, components, {horizontal, vertical}) do
    component_specs =
      for id <- 1..components//1, into: <<>> do
        if id == 1, do: <<id, horizontal * 16 + vertical, 0>>, else: <<id, 0x11, 0>>
      end

    <<precision, height::16, width::16, components>> <> component_specs
  end

  defp scan_header(components) do
    component_specs =
      for id <- 1..components//1, into: <<>>, do: <<id, 0x00>>

    <<components>> <> component_specs <> <<0, 63, 0>>
  end

  defp jfif_segment do
    segment(0xE0, "JFIF\0" <> <<1, 1, 0, 0, 1, 0, 1, 0, 0>>)
  end

  defp segment(marker, payload) do
    <<0xFF, marker, byte_size(payload) + 2::16>> <> payload
  end

  defp default_entropy do
    <<0x12, 0x34, 0xFF, 0x56, 0x78>> <> :binary.copy(<<0xAB>>, 251)
  end

  defp stuff(entropy) do
    for <<byte <- entropy>>, into: <<>> do
      if byte == 0xFF, do: <<0xFF, 0x00>>, else: <<byte>>
    end
  end

  defp with_restarts(scan_data, 0), do: scan_data

  defp with_restarts(scan_data, count) do
    piece = max(div(byte_size(scan_data), count + 1), 1)

    scan_data
    |> chunks(piece)
    |> Enum.with_index()
    |> Enum.map_join(fn
      {piece, index} when index < count -> piece <> <<0xFF, 0xD0 + rem(index, 8)>>
      {piece, _index} -> piece
    end)
  end
end
