# Repository Guidelines

## Project Structure & Module Organization
FFmpeg is organized by library and tool boundaries. Core libraries live in
`libavcodec`, `libavformat`, `libavfilter`, `libavutil`, `libavdevice`,
`libswscale`, and `libswresample`. Command-line programs such as `ffmpeg`,
`ffprobe`, and `ffplay` are in `fftools`. Build infrastructure is in
`configure`, `Makefile`, and `ffbuild`; documentation is under `doc`; presets
are under `presets`; regression tests, references, and checkasm code are under
`tests`. Put future Markdown technical articles in `articles/`.

## Fork Layout & Sync Workflow
This is a **fork** used for study. `origin` is the personal fork
(`github.com/ltlovezh/FFmpeg`); `upstream` is canonical FFmpeg. Branch model:
`master` mirrors upstream untouched, and **`learning`** (the working branch)
carries all local additions on top of it. Local additions live almost entirely
under `articles/` (technical write-ups + runnable demos); the C source tree
should stay close to `master`. `tools/sync-ffmpeg-branches.sh` automates the
sync (fast-forward `master` from `upstream`, merge into `learning`, push both);
use `--dry-run` to preview and `--no-push` for local-only. Engine patches to
`libav*`/`fftools` follow upstream review (mailing list / Forgejo), not GitHub
PRs.

## Architecture (Cross-File)
The seven libraries form a strict dependency stack; lower layers never call up:
- **`libavutil`** — foundation (math, memory, pixel/sample formats, the
  `AVOptions` system, `av_log`, dictionaries). Everything depends on it.
- **`libswscale`** / **`libswresample`** — pixel scale/convert and audio
  resample/mix; depend on `libavutil`.
- **`libavcodec`** — encoders/decoders/parsers/bitstream filters. Core data
  unit is `AVPacket` (compressed) ↔ `AVFrame` (raw), via
  `avcodec_send_packet`/`avcodec_receive_frame`.
- **`libavformat`** — (de)muxers, protocols, I/O (`AVIOContext`); depends on
  `libavcodec`.
- **`libavfilter`** — graph of A/V filters (`AVFilterGraph`); frames flow
  between linked pads.
- **`libavdevice`** — capture/playback layered on `libavformat`.

**Component registration is static, not dynamic.** Codecs, formats, filters,
protocols, and bitstream filters are entries in lists that `configure` filters
by what is enabled — `libavcodec/allcodecs.c`,
`libavcodec/bitstream_filters.c`, `libavformat/allformats.c`,
`libavformat/protocols.c`, `libavfilter/allfilters.c`. Adding a component means
touching the source file, the registration list, and the per-library
`Makefile`/`configure` entry. Each library has its own `Makefile` (included by
the top-level one) listing `OBJS`; arch SIMD lives in subdirs like
`libavcodec/x86` and `libavcodec/aarch64` with C fallbacks chosen at runtime.

**`fftools/ffmpeg.c` is a multi-threaded engine, not a thin wrapper.** The
pipeline (demux → decode → filter → encode → mux) is modeled as independent
components scheduled by `ffmpeg_sched.c` and connected by thread-safe queues
(`thread_queue.c`, `sync_queue.c` for backpressure and A/V sync). The per-stage
files are `ffmpeg_demux.c`, `ffmpeg_dec.c`, `ffmpeg_filter.c`, `ffmpeg_enc.c`,
`ffmpeg_mux.c`; `ffmpeg_opt.c` + `ffmpeg_mux_init.c` parse CLI options into the
stream/graph setup before the scheduler starts. When changing transcode
behavior, trace data flow across these files rather than expecting all logic in
`ffmpeg.c`. `ffprobe.c`/`ffplay.c` are separate, simpler tools; `cmdutils.c`
holds shared option-parsing helpers.

Note: `configure` is a hand-written script (not autotools/CMake) and builds
**in-tree**, generating `config.h`, `config_components.h`, and
`ffbuild/config.mak` — these gate every optional component and do not exist
until you configure.

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
