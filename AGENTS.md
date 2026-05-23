# Repository Guidelines

## Project Structure & Module Organization
FFmpeg is organized by library and tool boundaries. Core libraries live in
`libavcodec`, `libavformat`, `libavfilter`, `libavutil`, `libavdevice`,
`libswscale`, and `libswresample`. Command-line programs such as `ffmpeg`,
`ffprobe`, and `ffplay` are in `fftools`. Build infrastructure is in
`configure`, `Makefile`, and `ffbuild`; documentation is under `doc`; presets
are under `presets`; regression tests, references, and checkasm code are under
`tests`. Put future Markdown technical articles in `articles/`.

## Build, Test, and Development Commands
- `./configure`: generate the local build configuration. Use
  `./configure --help` to inspect optional codecs, formats, and external
  dependencies.
- `make`: build all enabled libraries and tools.
- `make -j$(nproc)`: parallel build on Linux; use an appropriate job count on
  other platforms.
- `make check`: build tools/examples/test programs and run the configured test
  targets.
- `make fate-rsync SAMPLES=/path/to/fate-suite`: fetch or update FATE samples.
- `make fate SAMPLES=/path/to/fate-suite`: run the FATE regression suite.
- `make fate-list`: list available FATE targets; run focused tests with names
  such as `make fate-ffprobe_compact`.

## Coding Style & Naming Conventions
Follow `doc/developer.texi`. C code uses K&R style, 4-space indentation, no tabs
outside Makefiles, and no trailing whitespace. Keep lines near 80 columns when
that improves readability. Use existing module prefixes and naming patterns
(`avformat/...`, `avcodec/...`, `ff_` for internal helpers where appropriate).
Library code must not print directly to stdout/stderr; use `av_log()`.

## Testing Guidelines
Run focused tests for the touched subsystem, then broader FATE coverage when
behavior changes. New assembly should include `tests/checkasm` coverage. Update
test references only when output changes are intentional and understood. For
Python helper work, run Python inside a virtual environment.

## Commit & Pull Request Guidelines
Commit messages use FFmpeg’s `area: short description` format, for example
`avformat/hlsenc: fix segment duration with mixed stream time bases`. Keep
functional, cosmetic, and preparatory changes in separate commits. Mention bug
IDs, CVEs, or mailing-list threads when relevant. Submit patches through
Forgejo or `ffmpeg-devel` using `git format-patch` or `git send-email`; GitHub
pull requests are not part of the project review process.

## Security & Configuration Tips
Do not enable or add external dependencies casually; non-system dependencies are
disabled by default. Preserve license compatibility, and add a proper license
header to every new source file using a nearby file as the template.
