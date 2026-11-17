# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Test.StubBackend do
  @moduledoc """
  A capture backend the test drives byte by byte.

  Stands in for ffmpeg so that every event capture has to cope with — a frame
  split across reads, a truncated image, an unexpected exit status, a consumer
  falling behind — is a function call in the test rather than something to wait
  for and hope for.

  Every operation is synchronous. `feed/2` returns once the data message is in
  the capture's mailbox, so a test can feed bytes and then assert on what came
  out without a sleep anywhere in between.
  """

  @behaviour BB.Camera.V4L.Backend

  use GenServer

  @doc false
  @impl BB.Camera.V4L.Backend
  def open(command, opts) do
    owner = self()

    case GenServer.start_link(__MODULE__, {command, owner, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @impl BB.Camera.V4L.Backend
  def os_pid(stub), do: GenServer.call(stub, :os_pid)

  @doc false
  @impl BB.Camera.V4L.Backend
  def request_stop(stub) do
    GenServer.call(stub, :request_stop)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @impl BB.Camera.V4L.Backend
  def close(stub) do
    GenServer.call(stub, :close)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Deliver `data` to the capture as one read.
  """
  @spec feed(pid(), binary()) :: :ok
  def feed(stub, data), do: GenServer.call(stub, {:feed, data})

  @doc """
  Deliver each binary in turn as a separate read.
  """
  @spec feed_all(pid(), [binary()]) :: :ok
  def feed_all(stub, chunks), do: Enum.each(chunks, &feed(stub, &1))

  @doc """
  Report that the captured process exited with `status`.
  """
  @spec exited(pid(), integer()) :: :ok
  def exited(stub, status), do: GenServer.call(stub, {:exited, status})

  @impl GenServer
  def init({command, owner, opts}) do
    report(opts[:report_to], {:stub_opened, self(), command})

    {:ok,
     %{
       os_pid: Keyword.get(opts, :os_pid),
       owner: owner,
       report_to: opts[:report_to]
     }}
  end

  @impl GenServer
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  def handle_call({:feed, data}, _from, state) do
    send(state.owner, {self(), {:data, data}})

    {:reply, :ok, state}
  end

  def handle_call({:exited, status}, _from, state) do
    send(state.owner, {self(), {:exit_status, status}})

    {:reply, :ok, state}
  end

  def handle_call(:request_stop, _from, state) do
    report(state.report_to, {:stub_stop_requested, self()})

    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    report(state.report_to, {:stub_closed, self()})

    {:reply, :ok, state}
  end

  defp report(nil, _message), do: :ok

  # A robot's DSL is compiled before the test process exists, so a stub
  # declared in one reports to a registered name rather than a pid.
  defp report(name, message) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp report(pid, message) when is_pid(pid), do: send(pid, message)
end
