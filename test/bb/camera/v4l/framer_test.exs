# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.FramerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.V4L.Framer
  alias BB.Camera.V4L.Test.JpegBuilder

  defp push_all(framer, chunks) do
    Enum.reduce(chunks, {[], [], framer}, fn chunk, {frames, events, framer} ->
      {new_frames, new_events, framer} = Framer.push(framer, chunk)

      {frames ++ new_frames, events ++ new_events, framer}
    end)
  end

  describe "push/2" do
    test "extracts a whole image from one read" do
      image = JpegBuilder.build(width: 320, height: 240)

      assert {[{data, info}], [], framer} = Framer.push(Framer.new(), image)
      assert data == image
      assert {info.width, info.height} == {320, 240}
      assert Framer.buffered(framer) == 0
    end

    test "reassembles an image delivered one byte at a time" do
      image = JpegBuilder.build()

      assert {[{data, _info}], [], _framer} =
               push_all(Framer.new(), JpegBuilder.chunks(image, 1))

      assert data == image
    end

    test "extracts every image in a read that holds several" do
      images = for size <- [16, 32, 64], do: JpegBuilder.build(width: size, height: size)

      assert {frames, [], _framer} = Framer.push(Framer.new(), JpegBuilder.stream(images))
      assert Enum.map(frames, fn {data, _info} -> data end) == images
      assert Enum.map(frames, fn {_data, info} -> info.width end) == [16, 32, 64]
    end

    test "survives reads that straddle image boundaries" do
      images = for index <- 1..5, do: JpegBuilder.build(width: index * 16, height: 48)

      assert {frames, [], _framer} =
               push_all(Framer.new(), JpegBuilder.chunks(JpegBuilder.stream(images), 37))

      assert Enum.map(frames, fn {data, _info} -> data end) == images
    end

    test "is not fooled by an end marker inside an EXIF thumbnail" do
      image =
        JpegBuilder.build(width: 800, height: 600, segments: [JpegBuilder.thumbnail_segment()])

      assert {[{data, info}], [], _framer} = Framer.push(Framer.new(), image)
      assert data == image
      assert {info.width, info.height} == {800, 600}
    end

    test "discards leading garbage and keeps the image after it" do
      image = JpegBuilder.build()
      garbage = :binary.copy(<<0x5A>>, 17)

      assert {[{data, _info}], events, _framer} = Framer.push(Framer.new(), garbage <> image)
      assert data == image
      assert events == [{:discarded, 17, :desynchronised}]
    end

    test "recovers from a truncated image by resynchronising on the next one" do
      good = JpegBuilder.build(width: 100, height: 100)
      truncated = :binary.part(good, 0, div(byte_size(good), 2))

      assert {[{data, info}], events, _framer} = Framer.push(Framer.new(), truncated <> good)
      assert data == good
      assert {info.width, info.height} == {100, 100}
      assert [{:discarded, bytes, :malformed}] = events
      assert bytes == byte_size(truncated)
    end

    test "gives up on an image whose end marker never arrives" do
      image = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(4096))
      framer = Framer.new(max_frame_bytes: 1024)

      fed = :binary.part(image, 0, 3000)
      {frames, events, framer} = push_all(framer, JpegBuilder.chunks(fed, 512))

      assert frames == []
      assert [{:discarded, _bytes, :oversized} | _rest] = events

      # Everything fed was either thrown away or is still buffered, and what is
      # still buffered is inside the cap.
      discarded =
        Enum.reduce(events, 0, fn {:discarded, bytes, _reason}, total -> total + bytes end)

      assert discarded + Framer.buffered(framer) == byte_size(fed)
      assert Framer.buffered(framer) <= 1024 + 512
    end

    test "refuses a complete image that is over the cap" do
      image = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(4096))
      framer = Framer.new(max_frame_bytes: 1024)

      assert {[], events, _framer} = Framer.push(framer, image)
      assert [{:discarded, bytes, :oversized}] = events
      assert bytes == byte_size(image)
    end

    test "keeps framing after refusing an oversized image" do
      big = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(4096))
      small = JpegBuilder.build(width: 24, height: 24, entropy: <<1, 2, 3>>)
      framer = Framer.new(max_frame_bytes: 1024)

      assert {[{data, info}], events, _framer} = Framer.push(framer, big <> small)
      assert data == small
      assert info.width == 24
      assert [{:discarded, _bytes, :oversized}] = events
    end

    test "refuses a complete image with no frame header" do
      headerless = JpegBuilder.build(frame_header?: false)
      good = JpegBuilder.build(width: 48, height: 36)

      assert {[{data, info}], events, _framer} =
               Framer.push(Framer.new(), headerless <> good)

      assert data == good
      assert info.width == 48
      assert [{:discarded, bytes, :malformed}] = events
      assert bytes == byte_size(headerless)
    end

    test "hands out frames that do not retain the read they arrived in" do
      small = JpegBuilder.build(width: 16, height: 16, entropy: <<1, 2, 3>>)
      filler = JpegBuilder.build(entropy: :crypto.strong_rand_bytes(8192))

      assert {[{data, _info} | _rest], [], _framer} =
               Framer.push(Framer.new(), small <> filler)

      assert byte_size(data) == byte_size(small)
      assert :binary.referenced_byte_size(data) == byte_size(data)
    end

    test "holds a partial image rather than emitting it" do
      image = JpegBuilder.build()
      partial = :binary.part(image, 0, byte_size(image) - 1)

      assert {[], [], framer} = Framer.push(Framer.new(), partial)
      assert Framer.buffered(framer) == byte_size(partial)

      assert {[{data, _info}], [], _framer} =
               Framer.push(framer, :binary.part(image, byte_size(image) - 1, 1))

      assert data == image
    end
  end
end
