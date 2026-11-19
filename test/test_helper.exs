# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# `:linux` tests need ffmpeg's V4L2 input, which only exists there.
linux_only = if match?({:unix, :linux}, :os.type()), do: [], else: [:linux]

ExUnit.start(exclude: [:ffmpeg] ++ linux_only)
