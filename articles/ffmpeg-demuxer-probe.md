# FFmpeg 是怎么“猜”出文件格式的？源码级拆解 Demuxer 自动识别机制

> 一句 `ffmpeg -i input.xxx`，或者一行 `avformat_open_input(&ctx, url, NULL, NULL)`，FFmpeg 就能从几百种封装格式里选出一个 demuxer。它不是靠玄学，也不是只看文件后缀，而是靠一套 **format probe：渐进读取 + 多 demuxer 打分 + 阈值重试 + 唯一最高分胜出** 的机制。

这篇文章从源码视角拆一下：FFmpeg 到底是怎么“猜”出输入文件格式的。

---

## 1. Probe 到底在解决什么问题？

在 FFmpeg 里，demuxer 负责把容器格式拆开，比如 MP4、FLV、Matroska、MPEG-TS、HLS、WAV 等。

但问题是：用户传进来的可能只是一个文件名、一个 URL，甚至是一个没有扩展名的字节流。FFmpeg 需要先回答一个问题：

```text
这段输入数据，最像哪一种封装格式？
```

这个问题就是 probe 阶段要解决的。

可以先粗暴理解成：

```text
probe = 选择 AVInputFormat，也就是选择 demuxer
demux = 由选中的 demuxer 执行 read_header / read_packet
```

所以 probe 通常发生在正式读取容器头之前。典型调用链大致是：

```text
ffmpeg -i input.xxx
  -> avformat_open_input()
     -> init_input()
        -> av_probe_input_buffer2()
           -> av_probe_input_format2()
              -> av_probe_input_format3()
                 -> 遍历所有 demuxer
                 -> 调用 read_probe()
                 -> 选出最佳 AVInputFormat
     -> demuxer->read_header()
```

注意：如果用户已经显式指定了输入格式，比如命令行 `-f flv`，或者 C API 里传了 `av_find_input_format("flv")` 的结果，FFmpeg 就会信任用户指定的 demuxer，不再走完整的自动识别流程。

---

## 2. 三个核心函数：外层读数据，内层打分

format probe 的主线可以拆成三层：

```text
av_probe_input_buffer2()
  -> av_probe_input_format2()
     -> av_probe_input_format3()
```

它们的分工很清楚：

| 函数 | 作用 |
|---|---|
| `av_probe_input_buffer2()` | 外层驱动：逐步读取更多输入数据，控制 probe buffer 增长 |
| `av_probe_input_format2()` | 中间层：只有当新一轮得分超过当前阈值时才返回格式 |
| `av_probe_input_format3()` | 内层评分：遍历所有 demuxer，计算每个 demuxer 的匹配分数 |

真正“哪个 demuxer 更像”的判断，主要在 `av_probe_input_format3()`；而“要不要继续多读一点数据”，主要在 `av_probe_input_buffer2()`。

---

## 3. Probe buffer：不是一次读很多，而是逐步翻倍

入口函数位于：

```text
libavformat/format.c
```

核心签名是：

```c
int av_probe_input_buffer2(AVIOContext *pb,
                           const AVInputFormat **fmt,
                           const char *filename,
                           void *logctx,
                           unsigned int offset,
                           unsigned int max_probe_size);
```

如果调用者没有传 `max_probe_size`，FFmpeg 会使用默认最大值：

```c
#define PROBE_BUF_MIN 2048
#define PROBE_BUF_MAX (1 << 20)
```

也就是：

```text
最小 probe size：2 KB
默认最大 probe size：1 MB
```

源码里的循环结构可以简化成：

```c
for (probe_size = PROBE_BUF_MIN;
     probe_size <= max_probe_size && !*fmt && !eof;
     probe_size = FFMIN(probe_size << 1,
                        FFMAX(max_probe_size, probe_size + 1))) {
    ...
}
```

直观理解就是：

```text
2048 -> 4096 -> 8192 -> 16384 -> ...
```

每一轮并不是从头重新读，而是继续补齐到当前目标大小：

```c
avio_read(pb, buf + buf_offset, probe_size - buf_offset);
```

其中：

```text
buf_offset：已经累计读取的字节数
probe_size：这一轮希望凑够的探测字节数
```

所以 probe buffer 是逐步累加的。这一点对网络流尤其重要：一开始数据少，就先用少量数据尝试；识别不出来，再继续读更多。

---

## 4. 每一轮都有“接受门槛”

FFmpeg 不会只要某个 demuxer 有一点点分数就立刻接受。每轮调用 `av_probe_input_format2()` 前，会先设置一个门槛：

```c
score = probe_size < max_probe_size ? AVPROBE_SCORE_RETRY : 0;
```

相关宏：

```c
#define AVPROBE_SCORE_MAX   100
#define AVPROBE_SCORE_RETRY (AVPROBE_SCORE_MAX / 4)
```

也就是：

```text
AVPROBE_SCORE_MAX   = 100
AVPROBE_SCORE_RETRY = 25
```

含义是：

```text
还没读到最大 probe size 时：
  只有 best_score > 25，才接受结果

已经读到最大 probe size，或者遇到 EOF 时：
  门槛降为 0，只要 best_score > 0，就可能接受
```

这套机制的目的很现实：前几 KB 可能只有 padding、ID3 标签、HTTP 前置数据，或者格式特征还没出现。低分候选先别急着信，继续读一点再判断。

如果最终只能低分识别，FFmpeg 还会打印类似这样的警告：

```text
Format xxx detected only with low score of yy, misdetection possible!
```

这就是你在排查奇怪输入时偶尔会看到的 “low score” 提示。

---

## 5. 单个 demuxer 怎么打分？

`av_probe_input_format3()` 会遍历所有已注册的 demuxer：

```c
while ((fmt1 = av_demuxer_iterate(&i))) {
    ...
}
```

每个 demuxer 都有一次“自我证明”的机会。分数主要来自三类信号。

### 5.1 内容特征：`read_probe()`

最重要的是 demuxer 自己实现的 `read_probe()`：

```c
score = ffifmt(fmt1)->read_probe(&lpd);
```

`read_probe()` 会看输入 buffer 的内容特征，比如：

```text
MP4/MOV：检查 box / atom 结构，例如 ftyp、moov、mdat
MPEG-TS：检查 0x47 sync byte 是否按固定间隔出现
HLS：检查 #EXTM3U、#EXT-X-xxx 标签
WAV：检查 RIFF/WAVE 结构
Matroska/WebM：检查 EBML 头
```

这是最可靠的信号，因为它看的是文件内容，而不是文件名。

### 5.2 扩展名：辅助，而不是绝对依据

如果 demuxer 有 `extensions`，FFmpeg 也会用文件名后缀辅助判断。

这里有一个容易写错的细节：

```c
if (fmt1->read_probe) {
    score = read_probe(...);

    if (fmt1->extensions && av_match_ext(filename, fmt1->extensions))
        score = FFMAX(score, 1);
} else if (fmt1->extensions) {
    if (av_match_ext(filename, fmt1->extensions))
        score = AVPROBE_SCORE_EXTENSION;
}
```

也就是说：

- 如果 demuxer 有 `read_probe()`，扩展名匹配通常只是把分数至少抬到 `1`；
- 如果 demuxer 没有 `read_probe()`，扩展名匹配才会给 `AVPROBE_SCORE_EXTENSION`；
- 遇到 ID3v2 标签特别长的情况，源码里还有额外保护逻辑，会调整扩展名相关分数，避免前面全是 ID3 导致内容探测失败。

所以不要简单写成“扩展名匹配一律给 50 分”。更准确的说法是：

> 内容探测优先；扩展名是辅助信号；只有没有 `read_probe()`，或者遇到特定 ID3 场景时，扩展名才会发挥更强的兜底作用。

### 5.3 MIME type：加分项

对于网络输入，如果 AVIO 层能拿到 MIME type，比如 HTTP `Content-Type`，FFmpeg 还会做 MIME 匹配：

```c
if (av_match_name(lpd.mime_type, fmt1->mime_type)) {
    score += AVPROBE_SCORE_MIME_BONUS;
    score = FFMIN(score, AVPROBE_SCORE_MAX);
}
```

相关宏：

```c
#define AVPROBE_SCORE_MIME_BONUS 30
#define AVPROBE_SCORE_MAX        100
```

所以 MIME type 是加分项，最多把分数封顶到 100。

---

## 6. 所有 demuxer 怎么决出冠军？

单个 demuxer 打完分后，FFmpeg 会维护当前最高分：

```c
if (score > score_max) {
    score_max = score;
    fmt       = fmt1;
} else if (score == score_max) {
    fmt = NULL;
}
```

这段逻辑非常关键：

```text
分数更高：更新当前最佳 demuxer
分数打平：fmt = NULL
```

也就是说，FFmpeg 不会在最高分打平时随便挑一个。它要求“唯一最高分”。

为什么这么设计？

因为错选 demuxer 的代价很高。容器格式一旦选错，后面的 `read_header()`、`read_packet()` 都可能走偏，轻则报错，重则误解析。与其瞎猜，不如让外层继续多读一点数据，再跑一轮评分。

可以把内层选择过程写成伪代码：

```c
best_fmt = NULL;
best_score = 0;

for_each_demuxer(fmt) {
    score = probe_one_demuxer(fmt, data, filename, mime_type);

    if (score > best_score) {
        best_score = score;
        best_fmt = fmt;
    } else if (score == best_score) {
        best_fmt = NULL;
    }
}

return best_fmt, best_score;
```

最终只有满足：

```text
best_fmt != NULL
best_score > 当前门槛
```

外层才会接受这个 demuxer。

---

## 7. 探测读过的数据会丢吗？

不会。

`av_probe_input_buffer2()` 读了一段数据用于判断格式，但结束前会调用：

```c
ffio_rewind_with_probe_data(pb, &buf, buf_offset);
```

它的作用是把 probe 阶段读出来的数据“塞回去”，让后续 demuxer 仍然可以从输入开头开始读。

这对不可 seek 的输入很重要。比如网络流不能像本地文件那样随便 `seek(0)`，FFmpeg 就通过复用 probe buffer 的方式实现“逻辑上的 rewind”。

所以流程是：

```text
probe 阶段读了一些字节
  -> 根据这些字节选出 demuxer
  -> 把已读字节放回 AVIOContext
  -> demuxer->read_header() 仍然能读到开头数据
```

---

## 8. `formatprobesize` 和 `probesize` 别搞混

FFmpeg 里有两个名字很像的参数，很容易混：

| 参数 | 主要作用 |
|---|---|
| `formatprobesize` | 控制“识别容器格式”最多读多少字节，也就是本文讲的 format probe |
| `probesize` | 控制后续分析流信息时最多读多少数据，主要影响 codec 参数、stream info 等 |

命令行里可以这样设置 format probe 的上限：

```bash
ffmpeg -formatprobesize 65536 -i input.xxx
```

C API 里也可以通过 AVOption 设置：

```c
AVDictionary *opts = NULL;
av_dict_set(&opts, "formatprobesize", "65536", 0);
avformat_open_input(&ctx, url, NULL, &opts);
```

调优时要明确目标：

```text
想更快选出 demuxer、降低起播等待：
  可以尝试调小 formatprobesize

输入头部很长、前面有大段 ID3 / padding / 私有数据：
  可以尝试调大 formatprobesize

已经显式指定 iformat：
  format probe 基本不会按自动识别流程执行，调 formatprobesize 意义不大
```

但别无脑调小。启动快一点和误判风险之间，总是有取舍。

---

## 9. Probe 不负责什么？

format probe 的职责边界要讲清楚：它主要负责选择 demuxer，不负责完整解析媒体信息。

它通常不负责最终确定：

```text
duration
stream 数量
codec 参数
分辨率
采样率
time_base
extradata
```

这些信息更多发生在后续阶段：

```text
demuxer->read_header()
avformat_find_stream_info()
read_packet()
parser / codec probing
```

举几个例子：

```text
MP4 的 duration 通常来自 read_header() 解析 moov box
TS 的节目和流信息通常来自 PAT / PMT 解析
更细的 codec 参数可能要靠 avformat_find_stream_info() 继续读包分析
```

所以不要把 “format probe” 和 “stream info probe” 混为一谈。前者回答“这是什么容器”，后者回答“容器里有哪些流、每路流是什么参数”。

---

## 10. 完整流程伪代码

把上面所有逻辑压缩成一段伪代码，大概是：

```c
int av_probe_input_buffer2(pb, &fmt, filename, logctx, offset, max_probe_size) {
    if (max_probe_size == 0)
        max_probe_size = PROBE_BUF_MAX;

    if (max_probe_size < PROBE_BUF_MIN)
        return AVERROR(EINVAL);

    buf = NULL;
    buf_offset = 0;
    score = 0;

    for (probe_size = PROBE_BUF_MIN;
         probe_size <= max_probe_size && !fmt && !eof;
         probe_size *= 2) {

        // 1. 继续读取，补齐到当前 probe_size
        read_more(pb, buf + buf_offset, probe_size - buf_offset);
        buf_offset += bytes_read;

        // 2. 还没到最大值时，门槛是 25；到最大值或 EOF 后，门槛降为 0
        score = probe_size < max_probe_size ? AVPROBE_SCORE_RETRY : 0;

        // 3. 遍历所有 demuxer 打分
        fmt = av_probe_input_format2(&probe_data, 1, &score);

        // 4. 只有唯一最高分且超过门槛，fmt 才会被返回
        if (fmt)
            break;
    }

    // 5. 把 probe 阶段读过的数据放回去
    ffio_rewind_with_probe_data(pb, &buf, buf_offset);

    return fmt ? score : AVERROR_INVALIDDATA;
}
```

再把 `av_probe_input_format3()` 展开：

```c
for_each_demuxer(fmt1) {
    score = 0;

    if (fmt1->read_probe) {
        score = fmt1->read_probe(&probe_data);

        if (extension_match)
            score = max(score, 1); // 简化，实际还有 ID3 特殊处理
    } else if (extension_match) {
        score = AVPROBE_SCORE_EXTENSION;
    }

    if (mime_type_match)
        score = min(score + AVPROBE_SCORE_MIME_BONUS, AVPROBE_SCORE_MAX);

    if (score > score_max) {
        score_max = score;
        fmt = fmt1;
    } else if (score == score_max) {
        fmt = NULL;
    }
}
```

---

## 11. 一个工程视角的总结

FFmpeg 的 demuxer 自动识别机制，本质上不是“看后缀猜格式”，而是：

```text
外层：逐步扩大输入样本
内层：让所有 demuxer 基于内容、扩展名、MIME 打分
选择：只接受唯一最高分
守门：低于阈值就继续读
收尾：把已读数据 rewind 回去，交给真正的 demuxer
```

一句话总结：

> FFmpeg 的 format probe，是一个“渐进采样 + 多信号评分 + 唯一最高分胜出 + 低分重试”的 demuxer 选择机制。

这套机制看起来不复杂，但它解决的是非常工程化的问题：输入可能来自本地文件、HTTP、直播流、自定义 IO；数据可能不完整；扩展名可能是错的；不同格式还可能有相似头部。FFmpeg 没有赌单一信号，而是用多轮打分把误判概率压低。

这也是它能“看起来很聪明”的原因。

---

## 源码索引

建议阅读这些文件和函数：

```text
libavformat/format.c
  - av_probe_input_buffer2()
  - av_probe_input_format2()
  - av_probe_input_format3()

libavformat/demux.c
  - avformat_open_input()
  - init_input()

libavformat/internal.h
  - PROBE_BUF_MIN
  - PROBE_BUF_MAX

libavformat/avformat.h
  - AVProbeData
  - AVPROBE_SCORE_*
  - AVInputFormat / read_probe

libavformat/options_table.h
  - formatprobesize
  - probesize
```

如果你想继续往下拆，下一篇最适合接着写：

```text
avformat_find_stream_info() 是怎么识别音视频流参数的？
```

因为 format probe 只是选 demuxer，真正让播放器知道“有几路流、编码是什么、分辨率多少、采样率多少”的，是后面的 stream info 分析阶段。
