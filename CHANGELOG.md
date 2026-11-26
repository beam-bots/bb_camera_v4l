<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.3.0](https://github.com/beam-bots/bb_camera_v4l/compare/v0.2.0...v0.3.0) (2026-11-26)
### Breaking Changes:

* deliver raw I420 frames (#3) by James Harton



## [v0.2.0](https://github.com/beam-bots/bb_camera_v4l/compare/v0.1.0...v0.2.0) (2026-11-19)
### Breaking Changes:

* run ffmpeg under MuonTrap via `bb_camera_ffmpeg` (#1) by James Harton



## [v0.1.0](https://github.com/beam-bots/bb_camera_v4l/compare/v0.1.0...v0.1.0) (2026-11-18)
### Breaking Changes:

* take `publish_rate` in hertz, matching every other sensor by James Harton



### Improvements:

* declare `bb_camera` through `bb_dep`, not a hard path by James Harton

* let the hub measure the frame rate, and stop doing it here by James Harton

* reconfigure from parameters, replacing the settings channel by James Harton

### Bug Fixes:

* return `{:stop, _}` from `handle_options/2`, and say what it costs by James Harton
