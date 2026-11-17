# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Backend.FFmpeg do
  @moduledoc """
  Runs ffmpeg behind an Erlang port.

  The port is opened with `:spawn_executable` and an explicit argument vector,
  so the arguments reach `execve` as they were written. No shell parses a
  device path, which is what makes an option value from a robot's DSL safe to
  pass through even though it came from configuration.

  `stderr` is deliberately *not* merged into `stdout`: ffmpeg's diagnostics
  would land in the middle of a JPEG and corrupt every frame around them. It
  stays attached to the VM's own stderr, so an ffmpeg complaint about a busy
  device or an unsupported pixel format appears on the console, where someone
  setting a camera up will see it. The driver reports the exit status; ffmpeg
  explains itself in its own words next to it.

  ## Stopping

  ffmpeg exits cleanly when it reads `q` on stdin, which releases the V4L2
  device properly. That is the first thing tried. It is not the last: closing
  the port does not kill the process, so `BB.Camera.V4L.Capture` escalates
  through `BB.Camera.V4L.Reaper` when the polite request goes unanswered.
  """

  @behaviour BB.Camera.V4L.Backend

  alias BB.Camera.V4L.Command

  @doc false
  @impl BB.Camera.V4L.Backend
  def open(%Command{} = command, _opts \\ []) do
    port =
      Port.open({:spawn_executable, command.executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: Command.argv(command)
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @doc false
  @impl BB.Camera.V4L.Backend
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @doc false
  @impl BB.Camera.V4L.Backend
  def request_stop(port) do
    Port.command(port, "q")
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @impl BB.Camera.V4L.Backend
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
