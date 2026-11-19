# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.Test.StubBot do
  @moduledoc """
  A robot whose camera is driven by `BB.Camera.FFmpeg.Test.StubBackend`.

  Everything but the bytes is real: the real driver, the real hub, the real
  framer and the real capture bounds. Only the thing that would have been
  ffmpeg is replaced, so a test can decide exactly what the camera produces
  and when.

  The stub reports to whatever process is registered as
  `:bb_camera_v4l_stub_observer`, because the DSL is compiled long before any
  test process exists.

  The width comes from a parameter, so a test can reconfigure the camera the
  way a robot actually does. Its default is the width every other test expects.
  """

  use BB

  settings do
    name(:bb_camera_v4l_stub_bot)
  end

  parameters do
    group :camera do
      param(:width, type: :integer, default: 640)
    end
  end

  topology do
    link :head do
      sensor(
        :eye,
        {BB.Camera.V4L,
         device: "/dev/video0",
         width: param([:camera, :width]),
         height: 480,
         frame_rate: 30,
         ffmpeg: "/nonexistent/ffmpeg",
         backend: BB.Camera.FFmpeg.Test.StubBackend,
         backend_opts: [report_to: :bb_camera_v4l_stub_observer]}
      )
    end
  end
end
