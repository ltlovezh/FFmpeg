# HLS + TS Playback Teaching Video Design

## Style Prompt

Engineering-console teaching video for FFmpeg internals. Use a dark packet-inspection canvas, crisp technical typography, luminous protocol paths, and restrained motion that makes data flow easy to follow. The visual language should feel like a debugger, a network trace, and a playback pipeline diagram combined.

## Colors

- Background: `#071312`
- Panel: `#10201d`
- Panel elevated: `#152b27`
- FFmpeg green accent: `#7bd88f`
- Transport cyan: `#62d6e8`
- Warning amber: `#f2c94c`
- Text primary: `#f4fbf7`
- Text secondary: `#a9c6bd`

## Typography

- Primary UI font: `PingFang SC`, `Noto Sans CJK SC`, `Microsoft YaHei`, `Arial`, sans-serif
- Code font: `SFMono-Regular`, `Menlo`, `Consolas`, monospace

## Motion

- Data packets move left-to-right along explicit paths.
- Scene transitions use fades and short vertical easing.
- Highlight only the currently discussed field, tag, PID, or packet.
- Use timeline progress as orientation; do not use decorative motion unrelated to playback flow.

## What NOT to Do

- Do not use generic gradient hero treatment.
- Do not hide protocol details behind abstract icons.
- Do not overuse one color; green is accent, not the whole palette.
- Do not use dense paragraphs in-frame; keep video copy short and let the document carry detail.
