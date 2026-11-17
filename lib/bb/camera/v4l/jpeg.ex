# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Jpeg do
  @moduledoc """
  Structural scanning of a JPEG byte stream.

  An MJPEG stream is a concatenation of complete JPEG images, so the obvious
  framing strategy is to split on the end-of-image marker `FF D9`. That is
  wrong in two directions and both of them happen in practice:

  - `FF D9` appears inside an EXIF thumbnail, which is a whole JPEG embedded
    in an `APP1` segment. Plenty of UVC cameras emit one, and `-c:v copy`
    passes it through untouched.
  - A truncated frame — the device was unplugged mid-write, the pipe was cut —
    leaves a partial image that never terminates, and a splitter will happily
    glue it to the front of the next one.

  So this module walks the marker structure instead: segments are skipped by
  their declared length, and entropy-coded data is scanned for the next real
  marker, skipping stuffed `FF 00` pairs, fill bytes and `RST` markers the way
  the format requires. A frame ends at the `EOI` that the structure says is the
  end, not at the first byte pair that looks like one.

  Walking the structure also means the frame header is parsed on the way past,
  so `t:info/0` carries the image's *actual* dimensions and coding process,
  read from its `SOF` segment. That matters because a camera is free to hand
  back something other than what it was asked for, and the only way to report
  the truth about a frame is to read it out of the frame.

  ## Resumable scanning

  Capture delivers a JPEG across several reads, so `scan/3` is written to
  resume. It returns a `t:state/0` marking how far it got, and the caller hands
  that back with more bytes appended. A frame is therefore scanned once in
  total rather than once per read, which keeps framing linear in the size of
  the stream rather than quadratic.

  `BB.Camera.V4L.Framer` wraps this with the buffer and the size caps; callers
  reading a stream want that rather than this.
  """

  @soi 0xD8
  @eoi 0xD9
  @sos 0xDA
  @tem 0x01

  # SOF markers: C0..CF except C4 (DHT), C8 (JPG extension) and CC (DAC).
  @sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  @progressive_markers [0xC2, 0xC6, 0xCA, 0xCE]

  defmodule Info do
    @moduledoc """
    What the frame header says about an image.

    Read from the `SOF` segment of the image itself, so these are the actual
    dimensions and coding process of the bytes in hand — not what the device
    was asked to produce.
    """

    defstruct [:width, :height, :precision, :components, :progressive?, :chroma_format]

    @typedoc """
    Chroma subsampling, named the way video code usually names it.

    `nil` when the sampling factors are not one of the arrangements a camera
    actually emits — guessing a name for an unusual one would be worse than
    admitting it is unknown.
    """
    @type chroma_format :: :I420 | :I422 | :I444 | :I440 | :I411 | :gray | nil

    @type t :: %__MODULE__{
            width: pos_integer(),
            height: pos_integer(),
            precision: pos_integer(),
            components: pos_integer(),
            progressive?: boolean(),
            chroma_format: chroma_format()
          }
  end

  @typedoc """
  How far a scan got, to be handed back to `scan/3` once more bytes arrive.

  `{:marker, offset}` means the next thing in the stream is a marker starting
  at `offset`; `{:entropy, offset}` means the scan is inside entropy-coded data
  and should resume looking for a marker at `offset`.
  """
  @type state :: {:marker, non_neg_integer()} | {:entropy, non_neg_integer()}

  @type info :: Info.t()

  @type error ::
          :not_jpeg
          | {:expected_marker, non_neg_integer()}
          | {:unexpected_soi, non_neg_integer()}
          | {:bad_segment_length, non_neg_integer()}
          | {:truncated_frame_header, non_neg_integer()}

  @doc """
  The scan state for a buffer that has not been looked at yet.

  The two bytes of the `SOI` marker are consumed up front, so callers must
  check for it with `soi?/1` first.
  """
  @spec initial_state() :: state()
  def initial_state, do: {:marker, 2}

  @doc """
  Does this buffer begin with a start-of-image marker?

  `false` for a buffer shorter than the marker, which is the "not yet, keep
  reading" answer as much as it is the "this is not a JPEG" one — callers with
  a byte or less in hand should wait for more before concluding anything.

      iex> BB.Camera.V4L.Jpeg.soi?(<<0xFF, 0xD8, 0x00>>)
      true

      iex> BB.Camera.V4L.Jpeg.soi?(<<0x00, 0xFF, 0xD8>>)
      false

      iex> BB.Camera.V4L.Jpeg.soi?(<<0xFF>>)
      false
  """
  @spec soi?(binary()) :: boolean()
  def soi?(<<0xFF, @soi, _::binary>>), do: true
  def soi?(_), do: false

  @doc """
  Find the next start-of-image marker at or after `from`.

  Used to resynchronise after a malformed frame: everything before the returned
  offset is unparseable and should be dropped.

      iex> BB.Camera.V4L.Jpeg.next_soi(<<0x00, 0x00, 0xFF, 0xD8, 0x01>>, 0)
      {:ok, 2}

      iex> BB.Camera.V4L.Jpeg.next_soi(<<0xFF, 0xD8, 0xFF, 0xD8>>, 1)
      {:ok, 2}

      iex> BB.Camera.V4L.Jpeg.next_soi(<<0x00, 0x01, 0x02>>, 0)
      :none
  """
  @spec next_soi(binary(), non_neg_integer()) :: {:ok, non_neg_integer()} | :none
  def next_soi(buffer, from) when from >= 0 do
    size = byte_size(buffer)

    if from >= size do
      :none
    else
      case :binary.match(buffer, <<0xFF, @soi>>, scope: {from, size - from}) do
        {offset, 2} -> {:ok, offset}
        :nomatch -> :none
      end
    end
  end

  @doc """
  Scan `buffer` for the end of the JPEG that starts at its first byte.

  `state` is `initial_state/0` for a fresh buffer, or the state returned by a
  previous `:incomplete`. `info` is likewise threaded through: it is `nil`
  until the scan walks past the frame header, and non-`nil` from then on.

  Returns one of:

  - `{:complete, length, info}` — the first `length` bytes of `buffer` are one
    whole JPEG. Anything after that belongs to the next image.
  - `{:incomplete, state, info}` — the image runs past the end of the buffer.
  - `{:error, reason}` — the bytes are not a well-formed JPEG, and the caller
    should resynchronise rather than trust any of them.
  """
  @spec scan(binary(), state(), info() | nil) ::
          {:complete, pos_integer(), info() | nil}
          | {:incomplete, state(), info() | nil}
          | {:error, error()}
  def scan(buffer, state, info \\ nil)

  def scan(buffer, _state, _info) when byte_size(buffer) < 2, do: {:error, :not_jpeg}

  def scan(buffer, state, info) do
    if soi?(buffer) do
      resume(buffer, state, info)
    else
      {:error, :not_jpeg}
    end
  end

  defp resume(buffer, {:marker, offset}, info), do: at_marker(buffer, offset, info)
  defp resume(buffer, {:entropy, offset}, info), do: in_entropy(buffer, offset, info)

  defp at_marker(buffer, offset, info) do
    size = byte_size(buffer)

    cond do
      offset >= size ->
        {:incomplete, {:marker, offset}, info}

      :binary.at(buffer, offset) != 0xFF ->
        {:error, {:expected_marker, offset}}

      true ->
        # Any number of FF bytes may pad the gap before a marker.
        case skip_fill(buffer, offset + 1, size) do
          :incomplete -> {:incomplete, {:marker, offset}, info}
          {:ok, marker_offset} -> dispatch(buffer, offset, marker_offset, info)
        end
    end
  end

  defp dispatch(buffer, marker_start, marker_offset, info) do
    case :binary.at(buffer, marker_offset) do
      @eoi -> {:complete, marker_offset + 1, info}
      @soi -> {:error, {:unexpected_soi, marker_offset - 1}}
      @tem -> at_marker(buffer, marker_offset + 1, info)
      marker when marker in 0xD0..0xD7 -> at_marker(buffer, marker_offset + 1, info)
      marker -> segment(buffer, marker_start, marker_offset, marker, info)
    end
  end

  defp segment(buffer, marker_start, marker_offset, marker, info) do
    size = byte_size(buffer)
    length_offset = marker_offset + 1

    if length_offset + 2 > size do
      {:incomplete, {:marker, marker_start}, info}
    else
      length = :binary.decode_unsigned(:binary.part(buffer, length_offset, 2))
      segment_end = length_offset + length

      cond do
        length < 2 -> {:error, {:bad_segment_length, marker_offset}}
        segment_end > size -> {:incomplete, {:marker, marker_start}, info}
        true -> past_segment(buffer, marker, length_offset + 2, segment_end, info)
      end
    end
  end

  defp past_segment(buffer, marker, payload_start, segment_end, _info)
       when marker in @sof_markers do
    case frame_header(buffer, marker, payload_start, segment_end) do
      {:ok, info} -> at_marker(buffer, segment_end, info)
      {:error, reason} -> {:error, reason}
    end
  end

  defp past_segment(buffer, @sos, _payload_start, segment_end, info),
    do: in_entropy(buffer, segment_end, info)

  defp past_segment(buffer, _marker, _payload_start, segment_end, info),
    do: at_marker(buffer, segment_end, info)

  defp frame_header(buffer, marker, payload_start, segment_end) do
    available = segment_end - payload_start

    with true <- available >= 6,
         <<precision, height::16, width::16, components>> <-
           :binary.part(buffer, payload_start, 6),
         true <- width > 0 and height > 0 and components > 0,
         true <- available >= 6 + components * 3 do
      {:ok,
       %Info{
         width: width,
         height: height,
         precision: precision,
         components: components,
         progressive?: marker in @progressive_markers,
         chroma_format:
           chroma_format(:binary.part(buffer, payload_start + 6, components * 3), components)
       }}
    else
      _other -> {:error, {:truncated_frame_header, payload_start}}
    end
  end

  # Each component carries an id, a byte of horizontal:vertical sampling
  # factors, and a quantisation table index. The luma component's factors
  # relative to the chroma components' are what the 4:x:x names describe.
  defp chroma_format(_specs, 1), do: :gray

  defp chroma_format(specs, 3) do
    case for <<_id, sampling, _table <- specs>>, do: {div(sampling, 16), rem(sampling, 16)} do
      [{2, 2}, {1, 1}, {1, 1}] -> :I420
      [{2, 1}, {1, 1}, {1, 1}] -> :I422
      [{1, 1}, {1, 1}, {1, 1}] -> :I444
      [{1, 2}, {1, 1}, {1, 1}] -> :I440
      [{4, 1}, {1, 1}, {1, 1}] -> :I411
      _other -> nil
    end
  end

  defp chroma_format(_specs, _components), do: nil

  defp in_entropy(buffer, offset, info),
    do: in_entropy(buffer, offset, byte_size(buffer), info)

  defp in_entropy(_buffer, offset, size, info) when offset >= size,
    do: {:incomplete, {:entropy, size}, info}

  defp in_entropy(buffer, offset, size, info) do
    case :binary.match(buffer, <<0xFF>>, scope: {offset, size - offset}) do
      :nomatch -> {:incomplete, {:entropy, size}, info}
      {found, 1} when found + 1 >= size -> {:incomplete, {:entropy, found}, info}
      {found, 1} -> past_ff(buffer, found, info)
    end
  end

  defp past_ff(buffer, found, info) do
    case :binary.at(buffer, found + 1) do
      # A stuffed byte: the FF is data, not a marker.
      0x00 -> in_entropy(buffer, found + 2, info)
      # Fill before a marker; the marker itself is still to come.
      0xFF -> in_entropy(buffer, found + 1, info)
      # Restart markers are interleaved with the entropy data.
      rst when rst in 0xD0..0xD7 -> in_entropy(buffer, found + 2, info)
      _marker -> at_marker(buffer, found, info)
    end
  end

  defp skip_fill(_buffer, offset, size) when offset >= size, do: :incomplete

  defp skip_fill(buffer, offset, size) do
    if :binary.at(buffer, offset) == 0xFF do
      skip_fill(buffer, offset + 1, size)
    else
      {:ok, offset}
    end
  end
end
