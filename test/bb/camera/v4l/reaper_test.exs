# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.ReaperTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.V4L.Reaper

  defp start_reaper(context, opts \\ []) do
    test = self()

    signaller = fn os_pid, signal -> send(test, {:signalled, os_pid, signal}) end

    start_supervised!(
      {Reaper,
       Keyword.merge([name: :"reaper_#{inspect(context.test)}", signaller: signaller], opts)},
      id: :reaper
    )
  end

  defp beam_os_pid, do: String.to_integer(System.pid())

  describe "watch/2" do
    test "signals the OS process when its owner dies", context do
      reaper = start_reaper(context)
      os_pid = beam_os_pid()

      test = self()

      owner =
        spawn(fn ->
          Reaper.watch(reaper, os_pid)
          send(test, {:watching, self()})
          receive do: (:never -> :ok)
        end)

      ref = Process.monitor(owner)
      assert_receive {:watching, ^owner}

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      assert_receive {:signalled, ^os_pid, :sigterm}
    end

    test "escalates to SIGKILL when the process outlives the grace period", context do
      reaper = start_reaper(context, grace_ms: 0)
      os_pid = beam_os_pid()

      :ok = Reaper.watch(reaper, os_pid)
      :ok = Reaper.reap(reaper, os_pid)

      assert_receive {:signalled, ^os_pid, :sigterm}
      assert_receive {:signalled, ^os_pid, :sigkill}
    end

    test "does not signal after the capture released the process", context do
      reaper = start_reaper(context)
      os_pid = beam_os_pid()

      test = self()

      owner =
        spawn(fn ->
          Reaper.watch(reaper, os_pid)
          Reaper.release(reaper, os_pid)
          send(test, {:released, self()})
          receive do: (:never -> :ok)
        end)

      ref = Process.monitor(owner)
      assert_receive {:released, ^owner}

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      # Pushing a call through the reaper proves it has processed the DOWN
      # already, so an empty mailbox here means it decided not to signal.
      :sys.get_state(reaper)
      refute_received {:signalled, _os_pid, _signal}
    end

    test "does not signal a pid it has no recorded identity for", context do
      reaper = start_reaper(context)

      # A pid is not an identity. Without one recorded while the process was
      # alive, there is nothing to tell the process we meant from whatever
      # holds its number now.
      :ok = Reaper.reap(reaper, String.to_integer(System.pid()))

      refute_received {:signalled, _os_pid, _signal}
    end

    test "does not signal a pid that is no longer a live process", context do
      reaper = start_reaper(context)

      :ok = Reaper.reap(reaper, unused_os_pid())

      refute_received {:signalled, _os_pid, _signal}
    end
  end

  describe "running?/2" do
    test "is true for a live process with a matching start time" do
      os_pid = beam_os_pid()

      assert Reaper.running?(os_pid)
    end

    test "is false when the start time does not match, because the pid was reused" do
      refute Reaper.running?(beam_os_pid(), "not-the-start-time")
    end

    test "is false for a pid that is not running" do
      refute Reaper.running?(unused_os_pid())
    end
  end

  describe "terminating a real process" do
    test "kills a spawned program that would otherwise outlive its port", context do
      reaper =
        start_supervised!({Reaper, name: :"real_reaper_#{inspect(context.test)}", grace_ms: 50},
          id: :real_reaper
        )

      port =
        Port.open(
          {:spawn_executable, System.find_executable("sleep")},
          [:binary, :exit_status, :use_stdio, :hide, args: ["300"]]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert Reaper.running?(os_pid)

      :ok = Reaper.watch(reaper, os_pid)
      :ok = Reaper.reap(reaper, os_pid)

      # The port tells us when the process is actually gone; nothing here waits
      # on a guessed interval.
      assert_receive {^port, {:exit_status, _status}}, 5_000
      refute Reaper.running?(os_pid)
    end
  end

  # The kernel will not have allocated anything near the top of the pid space.
  defp unused_os_pid do
    max = "/proc/sys/kernel/pid_max" |> File.read!() |> String.trim() |> String.to_integer()

    Enum.find((max - 1)..(max - 500)//-1, &(not File.exists?("/proc/#{&1}")))
  end
end
