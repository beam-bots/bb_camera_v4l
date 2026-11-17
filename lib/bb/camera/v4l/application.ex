# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Application do
  @moduledoc """
  Starts the one process this driver needs outside any robot.

  `BB.Camera.V4L.Reaper` has to outlive the robots whose cameras it cleans up
  after — a reaper supervised by the robot would die in the same crash that
  orphaned the ffmpeg it was meant to kill.
  """

  use Application

  @doc false
  @impl Application
  def start(_type, _args) do
    children = [BB.Camera.V4L.Reaper]

    Supervisor.start_link(children, strategy: :one_for_one, name: BB.Camera.V4L.Supervisor)
  end
end
