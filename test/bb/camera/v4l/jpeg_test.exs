# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.JpegTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.V4L.Jpeg
  alias BB.Camera.V4L.Test.JpegBuilder

  doctest BB.Camera.V4L.Jpeg

  describe "scan/3" do
    test "reads the dimensions out of the frame header" do
      image = JpegBuilder.build(width: 1920, height: 1080)

      assert {:complete, length, info} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
      assert info.width == 1920
      assert info.height == 1080
      assert info.components == 3
      assert info.precision == 8
      refute info.progressive?
    end

    test "recognises a progressive frame header" do
      image = JpegBuilder.build(progressive?: true, scans: 3)

      assert {:complete, _length, info} = Jpeg.scan(image, Jpeg.initial_state())
      assert info.progressive?
    end

    test "treats a stuffed FF 00 in the scan as data" do
      image = JpegBuilder.build(entropy: <<0xFF, 0xFF, 0xFF, 0xD9, 0xFF, 0xD8>>)

      assert {:complete, length, _info} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
    end

    test "skips restart markers in the scan" do
      image = JpegBuilder.build(restarts: 7)

      assert {:complete, length, _info} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
    end

    test "skips fill bytes before the end marker" do
      image = JpegBuilder.build(fill: 5)

      assert {:complete, length, _info} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
    end

    test "ends at the image's own end marker, not a thumbnail's" do
      image =
        JpegBuilder.build(width: 640, height: 480, segments: [JpegBuilder.thumbnail_segment()])

      assert {:complete, length, info} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
      assert {info.width, info.height} == {640, 480}

      # The naive framing this is guarding against would have stopped here.
      {thumbnail_end, 2} = :binary.match(image, <<0xFF, 0xD9>>)
      assert thumbnail_end + 2 < length
    end

    test "stops at the first image when several are concatenated" do
      first = JpegBuilder.build(width: 64, height: 48)
      second = JpegBuilder.build(width: 32, height: 24)

      assert {:complete, length, info} = Jpeg.scan(first <> second, Jpeg.initial_state())
      assert length == byte_size(first)
      assert {info.width, info.height} == {64, 48}
    end

    test "reports incomplete for a truncated image, and resumes where it left off" do
      image = JpegBuilder.build()
      truncated = :binary.part(image, 0, byte_size(image) - 4)

      assert {:incomplete, state, info} = Jpeg.scan(truncated, Jpeg.initial_state())
      assert info.width == 64

      assert {:complete, length, ^info} = Jpeg.scan(image, state, info)
      assert length == byte_size(image)
    end

    test "resuming never rescans bytes it has already walked" do
      image = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(4096))

      final =
        image
        |> JpegBuilder.chunks(64)
        |> Enum.reduce({<<>>, Jpeg.initial_state(), nil}, fn chunk, {buffer, state, info} ->
          buffer = buffer <> chunk

          case Jpeg.scan(buffer, state, info) do
            {:incomplete, state, info} -> {buffer, state, info}
            {:complete, length, info} -> {buffer, {:complete, length}, info}
          end
        end)

      assert {_buffer, {:complete, length}, info} = final
      assert length == byte_size(image)
      assert info.width == 64
    end

    test "refuses bytes that do not start with a start marker" do
      assert {:error, :not_jpeg} = Jpeg.scan(<<0x00, 0x01, 0x02>>, Jpeg.initial_state())
    end

    test "refuses a nested start marker" do
      image = JpegBuilder.build()
      spliced = :binary.part(image, 0, byte_size(image) - 2) <> <<0xFF, 0xD8>>

      assert {:error, {:unexpected_soi, _offset}} = Jpeg.scan(spliced, Jpeg.initial_state())
    end

    test "has no dimensions for an image with no frame header" do
      image = JpegBuilder.build(frame_header?: false)

      assert {:complete, length, nil} = Jpeg.scan(image, Jpeg.initial_state())
      assert length == byte_size(image)
    end
  end
end
