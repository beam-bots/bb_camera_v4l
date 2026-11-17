# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Backend do
  @moduledoc """
  How `BB.Camera.V4L.Capture` talks to the thing producing bytes.

  There is one real implementation — `BB.Camera.V4L.Backend.FFmpeg`, an
  `Port` around ffmpeg — and the behaviour exists so capture can also be driven
  by `BB.Camera.V4L.Backend.Stub`, which produces exactly the bytes a test
  asks for, exactly when the test asks for them.

  That matters more than it might look. Everything interesting about capture is
  a sequence of events: a frame split across three reads, a device that stops
  sending halfway through one, an ffmpeg that exits with a status nobody
  expected, a consumer falling behind. Against a real camera those are
  arrangeable only by luck. Against the stub each one is a function call, and
  the test asserts on the result rather than on how long it waited.

  ## Message protocol

  A backend delivers to the process that called `open/3`, shaped exactly like
  the port messages it stands in for:

      {handle, {:data, binary}}
      {handle, {:exit_status, integer}}

  and, for a backend that links, an exit signal from `handle` when it goes
  away. The handle is opaque: a `t:port/0` for the real backend.
  """

  @typedoc """
  Opaque reference to a running capture.
  """
  @type handle :: port() | reference() | pid()

  @doc """
  Start the capture. Must be called from the process that will receive its
  messages.
  """
  @callback open(command :: BB.Camera.V4L.Command.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc """
  The OS process id behind this handle, or `nil` when there isn't one.
  """
  @callback os_pid(handle()) :: pos_integer() | nil

  @doc """
  Ask the capture to shut down cleanly, if it has a way to.
  """
  @callback request_stop(handle()) :: :ok

  @doc """
  Drop the handle without waiting. Does not guarantee the OS process is gone —
  see `BB.Camera.V4L.Reaper` for the part that does.
  """
  @callback close(handle()) :: :ok
end
