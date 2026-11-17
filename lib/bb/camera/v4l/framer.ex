# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Framer do
  @moduledoc """
  Turns the byte stream coming out of a capture into whole JPEG frames.

  A pipe hands over whatever happened to be readable, so a frame arrives across
  several reads and a read routinely holds the tail of one frame and the head
  of the next. The framer owns that buffer, hands back the frames that have
  completed, and resumes its scan where it left off rather than re-reading the
  bytes it has already walked — see `BB.Camera.V4L.Jpeg` for the scanner.

  It is a plain struct with no process of its own, so it can be driven straight
  from a test with a list of byte chunks.

  ## Bounds

  Framing is where a hostile or broken stream turns into unbounded memory: a
  frame whose `EOI` never arrives would otherwise grow the buffer until the VM
  dies. `max_frame_bytes` is the hard stop, and it applies to frames that
  complete as much as to frames that do not — a single oversized image
  delivered whole in one read is refused rather than passed on because it
  happened to arrive in one piece.

  An image that completes but carries no frame header is discarded too. It has
  no dimensions to report, and the driver's whole claim to know what a frame
  actually is rests on having read them out of it.

  That makes the retained buffer bounded by `max_frame_bytes` plus whatever one
  read delivered, regardless of what the stream does. The same resynchronisation
  handles a malformed frame and leading garbage, so there is one recovery path
  rather than three.

  Note that this bounds the *framer*. It does not bound the mailbox of the
  process reading the capture — Erlang ports have no ingress flow control — so
  `BB.Camera.V4L.Capture` carries a separate bound for that.

  ## Reporting

  Every discard produces an event in the returned list, rather than a log line,
  because the driver turns them into a message on the robot's pubsub: a camera
  quietly dropping half its frames should be visible to an operator. Events
  never carry frame bytes, only counts and a reason.
  """

  alias BB.Camera.V4L.Jpeg

  @default_max_frame_bytes 4 * 1024 * 1024

  defstruct buffer: <<>>,
            scan: nil,
            info: nil,
            max_frame_bytes: @default_max_frame_bytes

  @type t :: %__MODULE__{
          buffer: binary(),
          scan: Jpeg.state() | nil,
          info: Jpeg.info() | nil,
          max_frame_bytes: pos_integer()
        }

  @typedoc """
  A complete image and what its own frame header says about it.
  """
  @type frame :: {data :: binary(), info :: Jpeg.info()}

  @typedoc """
  Something was thrown away, and why.

  - `:oversized` — no end-of-image marker inside `max_frame_bytes`.
  - `:malformed` — the bytes are not a well-formed JPEG.
  - `:desynchronised` — the stream did not begin at a start-of-image marker.
  """
  @type event ::
          {:discarded, bytes :: pos_integer(),
           reason :: :oversized | :malformed | :desynchronised}

  @doc """
  Build a framer.

  ## Options

  - `:max_frame_bytes` — the largest image to accept, in bytes. Default
    #{@default_max_frame_bytes}. That default is a spike bound, not a measured
    one: MJPEG frame sizes depend on resolution, quality and scene detail, and a
    high-quality 4K frame can exceed it. Raise it if the camera's frames are
    legitimately bigger; lower it on a memory-constrained target, where it also
    caps what a broken stream can make the framer hold.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      scan: Jpeg.initial_state(),
      max_frame_bytes: Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes)
    }
  end

  @doc """
  Append `bytes` to the buffer and extract whatever that completes.

  Returns the frames in arrival order, any discard events, and the framer to
  use for the next read.
  """
  @spec push(t(), binary()) :: {[frame()], [event()], t()}
  def push(framer, bytes) do
    {frames, events, framer} = drain(%{framer | buffer: framer.buffer <> bytes}, [], [])
    {Enum.reverse(frames), Enum.reverse(events), framer}
  end

  @doc """
  How many bytes the framer is holding on to.
  """
  @spec buffered(t()) :: non_neg_integer()
  def buffered(%__MODULE__{buffer: buffer}), do: byte_size(buffer)

  defp drain(framer, frames, events) do
    cond do
      byte_size(framer.buffer) < 2 -> {frames, events, framer}
      not Jpeg.soi?(framer.buffer) -> resync(framer, frames, events, :desynchronised)
      true -> scan(framer, frames, events)
    end
  end

  defp scan(framer, frames, events) do
    case Jpeg.scan(framer.buffer, framer.scan, framer.info) do
      {:complete, length, info} ->
        complete(framer, frames, events, length, info)

      {:incomplete, scan, info} ->
        if byte_size(framer.buffer) > framer.max_frame_bytes do
          resync(framer, frames, events, :oversized)
        else
          {frames, events, %{framer | scan: scan, info: info}}
        end

      {:error, _reason} ->
        resync(framer, frames, events, :malformed)
    end
  end

  defp complete(framer, frames, events, length, info) do
    cond do
      length > framer.max_frame_bytes -> reject(framer, frames, events, length, :oversized)
      is_nil(info) -> reject(framer, frames, events, length, :malformed)
      true -> emit(framer, frames, events, length, info)
    end
  end

  defp emit(framer, frames, events, length, info) do
    # The frame is a sub-binary of the accumulated buffer, which also holds the
    # bytes of every other frame in this read. Downstream keeps the latest frame
    # for as long as a consumer is slow, so copying is what stops one small
    # frame pinning a whole read's worth of bytes.
    frame = :binary.copy(:binary.part(framer.buffer, 0, length))

    drain(advance(framer, length), [{frame, info} | frames], events)
  end

  defp reject(framer, frames, events, length, reason) do
    drain(advance(framer, length), frames, [{:discarded, length, reason} | events])
  end

  defp advance(framer, length) do
    rest = :binary.part(framer.buffer, length, byte_size(framer.buffer) - length)

    %{framer | buffer: :binary.copy(rest), scan: Jpeg.initial_state(), info: nil}
  end

  defp resync(framer, frames, events, reason) do
    buffer = framer.buffer
    from = if Jpeg.soi?(buffer), do: 1, else: 0

    {discarded, buffer} =
      case Jpeg.next_soi(buffer, from) do
        {:ok, offset} ->
          {offset, :binary.part(buffer, offset, byte_size(buffer) - offset)}

        :none ->
          # A trailing FF may be the first half of the next start marker.
          keep = trailing_partial_marker(buffer)
          {byte_size(buffer) - keep, :binary.part(buffer, byte_size(buffer) - keep, keep)}
      end

    framer = %{
      framer
      | buffer: :binary.copy(buffer),
        scan: Jpeg.initial_state(),
        info: nil
    }

    drain(framer, frames, [{:discarded, discarded, reason} | events])
  end

  defp trailing_partial_marker(buffer) do
    if :binary.last(buffer) == 0xFF, do: 1, else: 0
  end
end
