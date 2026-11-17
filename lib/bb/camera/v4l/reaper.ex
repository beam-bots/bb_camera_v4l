# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Reaper do
  @moduledoc """
  Kills the ffmpeg process when the Elixir process that owned it goes away.

  Closing a port does not kill the program behind it, and neither does killing
  the port's owner. Measured on OTP 29: a `sleep` spawned with
  `Port.open/2` survives both `Port.close/1` and `Process.exit(owner, :kill)`,
  reparented to init and running happily.

  Most of the time this does not show up, because a capture is writing to a
  pipe nobody is reading any more and dies of `SIGPIPE` on its next write. But
  "its next write" is precisely the thing that does not happen when a camera
  has wedged — which is one of the main reasons the owning process died in the
  first place. The result is an ffmpeg holding `/dev/video0` open forever, and
  a camera that cannot be reopened until someone finds it by hand.

  So the reaper runs outside every robot, outside every camera, and outside the
  supervision tree that might be restarting around it. A capture registers its
  OS pid with `watch/2` before it does anything else and `release/2`s it once
  the process is confirmed dead. If the owner dies in between — crash, brutal
  kill, supervisor shutdown — the reaper notices and terminates the process.

  ## Not killing the wrong process

  A pid alone is not an identity: the OS reuses them, and the window between an
  owner dying and the reaper acting is exactly when ffmpeg is likely to be
  exiting on its own. Killing a recycled pid would be far worse than leaking
  the original.

  The reaper therefore records `/proc/<pid>`'s start time when it starts
  watching, and re-checks it immediately before every signal. A pid whose start
  time has changed is a different process and is left alone; so is one that has
  already become a zombie. This is Linux-specific, which is fine in a driver
  whose entire reason to exist is Linux's video API.

  It will only signal a process it has an identity for — one registered through
  `watch/2` while it was still alive. `reap/2` on anything else does nothing,
  rather than reading an identity out of `/proc` at the moment it is asked to
  kill something, which would be reading the identity of whatever holds the pid
  *now*. That is the question being asked, not evidence toward answering it.

  ## The residual race

  Checking `/proc` and then sending a signal are two operations, and the
  process can exit between them. If the kernel then hands the pid to something
  else inside that window, the signal lands on the wrong process. The window is
  a few microseconds and crossing it needs a pid to be recycled within it,
  which on Linux's sequential pid allocation means wrapping the whole pid space
  first — but it is not zero, and nothing here can close it.

  Closing it properly needs `pidfd_open(2)`, which holds a reference to the
  process itself rather than to its number. The BEAM has no interface to it,
  and a NIF to get one is a larger change than this spike justifies.
  """

  use GenServer

  require Logger

  @default_grace_ms 2_000

  @doc """
  Start a reaper. The package's application starts one named `#{inspect(__MODULE__)}`.

  ## Options

  - `:name` — registered name. Default `#{inspect(__MODULE__)}`.
  - `:grace_ms` — how long a process gets to exit on `SIGTERM` before it is
    sent `SIGKILL`. Default #{@default_grace_ms}.
  - `:signaller` — a 2-arity function taking the OS pid and `:sigterm` or
    `:sigkill`. Default sends the real signal. Tests replace it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Terminate `os_pid` if the calling process dies before calling `release/2`.
  """
  @spec watch(GenServer.server(), pos_integer()) :: :ok
  def watch(reaper \\ __MODULE__, os_pid) when is_integer(os_pid) and os_pid > 0,
    do: GenServer.call(reaper, {:watch, os_pid, self()})

  @doc """
  Stop watching `os_pid`, because it is confirmed gone.
  """
  @spec release(GenServer.server(), pos_integer()) :: :ok
  def release(reaper \\ __MODULE__, os_pid) when is_integer(os_pid) and os_pid > 0,
    do: GenServer.call(reaper, {:release, os_pid})

  @doc """
  Terminate `os_pid` now: `SIGTERM`, then `SIGKILL` after the grace period.

  Does nothing unless `os_pid` is being watched, because only then is there a
  recorded identity to check the pid against. Returns once the `SIGTERM` has
  been sent, not once the process is gone — nothing here can tell you that; the
  owner of the port sees the exit status.
  """
  @spec reap(GenServer.server(), pos_integer()) :: :ok
  def reap(reaper \\ __MODULE__, os_pid) when is_integer(os_pid) and os_pid > 0,
    do: GenServer.call(reaper, {:reap, os_pid})

  @doc """
  Is this OS pid a live process that started when we think it did?

  `nil` for `started_at` asks only whether *something* holds that pid, which is
  a question about the number rather than about the process. Never signal on
  the strength of it.
  """
  @spec running?(pos_integer(), integer() | nil) :: boolean()
  def running?(os_pid, started_at \\ nil) do
    case process_stat(os_pid) do
      {:ok, state, _starttime} when state in ["Z", "X", "x"] -> false
      {:ok, _state, starttime} -> is_nil(started_at) or starttime == started_at
      :error -> false
    end
  end

  @doc false
  @spec posix_signal(pos_integer(), :sigterm | :sigkill) :: :ok
  def posix_signal(os_pid, signal) do
    case System.find_executable("kill") do
      nil ->
        Logger.warning(
          "no `kill` executable: cannot #{signal} ffmpeg process #{os_pid}, which may leak"
        )

      executable ->
        System.cmd(executable, ["-#{flag(signal)}", Integer.to_string(os_pid)],
          stderr_to_stdout: true
        )
    end

    :ok
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       watched: %{},
       monitors: %{},
       grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
       signaller: Keyword.get(opts, :signaller, &__MODULE__.posix_signal/2)
     }}
  end

  @impl GenServer
  def handle_call({:watch, os_pid, owner}, _from, state) do
    monitor = Process.monitor(owner)
    started_at = started_at(os_pid)

    state = %{
      state
      | watched: Map.put(state.watched, os_pid, %{monitor: monitor, started_at: started_at}),
        monitors: Map.put(state.monitors, monitor, os_pid)
    }

    {:reply, :ok, state}
  end

  def handle_call({:release, os_pid}, _from, state), do: {:reply, :ok, forget(state, os_pid)}

  def handle_call({:reap, os_pid}, _from, state) do
    started_at = get_in(state.watched, [os_pid, :started_at])

    {:reply, :ok, signal_and_escalate(forget(state, os_pid), os_pid, started_at)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, os_pid} ->
        started_at = get_in(state.watched, [os_pid, :started_at])

        {:noreply, signal_and_escalate(forget(state, os_pid), os_pid, started_at)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:escalate, os_pid, started_at}, state) do
    if identified?(os_pid, started_at), do: state.signaller.(os_pid, :sigkill)

    {:noreply, state}
  end

  defp signal_and_escalate(state, os_pid, started_at) do
    if identified?(os_pid, started_at) do
      state.signaller.(os_pid, :sigterm)
      Process.send_after(self(), {:escalate, os_pid, started_at}, state.grace_ms)
    end

    state
  end

  # No recorded identity means no way to tell the process we meant from
  # whatever holds its number now, and the safe answer to that is silence.
  defp identified?(_os_pid, nil), do: false
  defp identified?(os_pid, started_at), do: running?(os_pid, started_at)

  defp forget(state, os_pid) do
    case Map.pop(state.watched, os_pid) do
      {nil, _watched} ->
        state

      {%{monitor: monitor}, watched} ->
        Process.demonitor(monitor, [:flush])

        %{state | watched: watched, monitors: Map.delete(state.monitors, monitor)}
    end
  end

  defp started_at(os_pid) do
    case process_stat(os_pid) do
      {:ok, _state, starttime} -> starttime
      :error -> nil
    end
  end

  # The `comm` field is the process name in parentheses, and may itself contain
  # spaces and parentheses, so everything before the final `)` has to go before
  # the remaining fields can be counted. `state` is then field 3 and
  # `starttime` field 22 of proc(5).
  defp process_stat(os_pid) do
    with {:ok, contents} <- File.read("/proc/#{os_pid}/stat"),
         [_comm, rest] <- String.split(contents, ") ", parts: 2, trim: false) |> pair(),
         fields <- String.split(rest, " "),
         {:ok, process_state} <- Enum.fetch(fields, 0),
         {:ok, starttime} <- Enum.fetch(fields, 19) do
      {:ok, process_state, starttime}
    else
      _other -> :error
    end
  end

  defp pair(parts) when length(parts) == 2, do: parts
  defp pair(_parts), do: :error

  defp flag(:sigterm), do: "TERM"
  defp flag(:sigkill), do: "KILL"
end
