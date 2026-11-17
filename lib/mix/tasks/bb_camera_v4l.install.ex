# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbCameraV4l.Install do
    @shortdoc "Installs BB.Camera.V4L into a robot"
    @moduledoc """
    #{@shortdoc}

    Adds a `:config.:camera` param group holding the device path and geometry,
    writes the device default to the robot's parameters, and imports
    `bb_camera_v4l` into your formatter.

    The camera itself belongs on a specific link — whichever one it is bolted
    to — and the installer cannot guess which, so it prints a snippet to paste
    into the topology.

    ## Example

    ```bash
    mix igniter.install bb_camera_v4l
    mix igniter.install bb_camera_v4l --device /dev/video2
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    * `--device` - The V4L2 device node (default `/dev/video0`).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Formatter

    @param_group :camera
    @default_device "/dev/video0"

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string, device: :string],
        aliases: [r: :robot, d: :device]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)
      device = Keyword.get(igniter.args.options, :device, @default_device)

      igniter
      |> Formatter.import_dep(:bb_camera_v4l)
      |> BB.Igniter.add_param_group(robot_module, [:config, @param_group], param_group_body())
      |> BB.Igniter.set_robot_param_default(
        robot_module,
        [:config, @param_group, :device],
        device
      )
      |> Igniter.add_notice(topology_snippet())
    end

    defp param_group_body do
      """
      param :device, type: :string, doc: "V4L2 device node, e.g. \\"/dev/video0\\""

      param :width, type: :integer, default: 640, doc: "Width in pixels to ask the device for"

      param :height, type: :integer, default: 480, doc: "Height in pixels to ask the device for"
      """
    end

    defp topology_snippet do
      """
      bb_camera_v4l: add a camera to whichever link it is mounted on. Example:

          link :head do
            sensor :eye, {BB.Camera.V4L,
              device: param([:config, :camera, :device]),
              width: param([:config, :camera, :width]),
              height: param([:config, :camera, :height]),
              frame_rate: 30
            }
          end

      Find the device node and what it supports with `v4l2-ctl --list-devices`
      and `v4l2-ctl -d /dev/video0 --list-formats-ext`. A webcam usually claims
      two /dev/video* nodes and only the first one captures.

      Reading frames needs membership of the `video` group on Debian:

          sudo usermod -aG video "$USER"   # then log out and back in
      """
    end
  end
else
  defmodule Mix.Tasks.BbCameraV4l.Install do
    @shortdoc "Installs BB.Camera.V4L into a robot"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The bb_camera_v4l.install task requires igniter.

          mix igniter.install bb_camera_v4l
      """)

      exit({:shutdown, 1})
    end
  end
end
