# FFmpeg extradata：定义、容器格式、流转路径与 BSF

在 FFmpeg 里，`extradata` 不是 title、artist、creation_time 这类媒体标签，而是
**解码器初始化和解释压缩码流所需的 codec-specific 全局配置数据**。它的内容完全
取决于 codec 和封装格式：同样是 H.264，在 MP4 里通常是 `avcC` 配置记录，在
MPEG-TS / raw Annex B 语境里通常是带 start code 的 SPS/PPS。

一句话概括：

```text
extradata = 容器或码流提供给 codec 的 out-of-band global header / decoder config
```

它解决的问题是：某些 packet/frame 本身不携带完整的解码初始化信息，解码器必须先拿到
profile、level、参数集、采样率、声道配置、bit depth、codec 私有头等信息，才能正确
解释后续压缩数据。

所有源码定位均基于当前仓库代码。

---

## 1. extradata 存在哪些数据结构里？

FFmpeg 里最核心的几个位置是：

| 数据结构 | 字段 | 职责 |
| --- | --- | --- |
| `AVCodecParameters` | `extradata` / `extradata_size` | 流参数层，通常挂在 `AVStream.codecpar` 上，供 demuxer/muxer 描述一路 stream |
| `AVCodecContext` | `extradata` / `extradata_size` | codec 实例层，decoder 打开前消费，encoder 打开后可能生成 |
| `AVPacket` side data | `AV_PKT_DATA_NEW_EXTRADATA` | packet 级动态通知：当前 packet 携带了新的 extradata |
| `AVBSFContext` | `par_in` / `par_out` | bitstream filter 输入/输出参数，可能读取、生成或转换 extradata |

`AVCodecParameters` 的注释直接说明它是初始化 decoder 所需的 codec-dependent 二进制
数据，定义在 `libavcodec/codec_par.h:68`。`AVCodecContext` 则明确区分了解码和编码：

- 解码：调用者应在打开 decoder 前设置，通常来自 demuxer。
- 编码：encoder 可能在 `avcodec_open2()` 中设置，可能依赖
  `AV_CODEC_FLAG_GLOBAL_HEADER`。

对应定义在 `libavcodec/avcodec.h:518`。

`AV_PKT_DATA_NEW_EXTRADATA` 是动态补充机制。它表示 extradata buffer 发生变化，接收侧
应立即用新数据处理当前 frame/packet，定义在 `libavcodec/packet.h:50`。

注意：`AVStream` 自身没有直接的 `extradata` 字段。工程里常说“某路 stream 的
extradata”，实际通常指：

```text
AVStream.codecpar->extradata
```

---

## 2. extradata 的作用是什么？

不同 codec 的 extradata 内容不同，但作用可以归到几类：

| 类别 | 典型 codec | extradata 内容 |
| --- | --- | --- |
| 视频参数集 | H.264 / HEVC / VVC | SPS/PPS，或 VPS/SPS/PPS，或 `avcC`/`hvcC`/`vvcC` 配置记录 |
| 音频配置 | AAC | AudioSpecificConfig，描述 object type、采样率、声道配置、SBR/PS 等 |
| Codec 私有头 | Opus / Vorbis / FLAC | `OpusHead`、Vorbis headers、FLAC STREAMINFO 等 |
| 老式或专用格式初始化状态 | ADPCM / Real / game codecs | block align、预测器系数、版本号、状态表等 |

它不是“可选装饰”。对某些封装和 codec 组合，缺失 extradata 会导致：

- decoder 无法打开；
- muxer 写 header 失败；
- stream copy 后输出文件不可播；
- seek 后首个关键帧花屏，因为参数集没有随关键帧出现；
- AAC 从 TS/ADTS 直接塞进 MP4 时，MP4 没有 AudioSpecificConfig。

但没有 extradata 也不一定是错。比如 ADTS AAC 每帧自带 ADTS header，AC3/EAC3/MP3
也常常不依赖 `codecpar->extradata`。

---

## 3. 解封装和解码链路中 extradata 怎么流转？

典型解码链路：

```text
container header / descriptors / first packets
  -> demuxer 填 AVStream.codecpar->extradata
  -> avformat_find_stream_info() 可能补充探测
  -> avcodec_parameters_to_context()
  -> AVCodecContext.extradata
  -> avcodec_open2()
  -> decoder 消费
```

### 3.1 demuxer 直接从容器头读取

如果容器本身有集中式 codec config，demuxer 会在 `read_header` 或解析 stream 描述时
直接填 `AVStream.codecpar->extradata`。

MP4/MOV 就是典型例子：

- `avcC`、`hvcC`、`vvcC`、`av1C` 等 box 由 `mov_read_glbl()` 读取。
- `mov_read_glbl()` 的注释说明：读取 atom 内容放入 extradata，不包含 atom tag 和 size。
- 入口映射可见 `libavformat/mov.c:9611`、`libavformat/mov.c:9640`、
  `libavformat/mov.c:9680`、`libavformat/mov.c:9681`。
- `esds` 里的 `DecoderSpecificInfo` 由 `ff_mp4_read_dec_config_descr()` 读取，
  其中 AAC 的内容就是 AudioSpecificConfig，逻辑在 `libavformat/isom.c:329`。

### 3.2 avformat_find_stream_info() 用 extract_extradata 补齐

有些容器没有全局配置，或者头部信息不完整。`avformat_find_stream_info()` 会读取前面
若干 packet 来补齐 stream 参数。如果某路 stream 还没有 extradata，并且 codec 被
`extract_extradata` 支持，FFmpeg 会临时创建该 BSF，从 packet 中提取全局头。

相关逻辑：

- 检查 `extract_extradata` 是否支持当前 codec：`libavformat/demux.c:2461`。
- 初始化 BSF 并复制 `codecpar` 到 `bsf->par_in`：`libavformat/demux.c:2477`。
- 将 packet 送入 BSF，读取 `AV_PKT_DATA_NEW_EXTRADATA` side data：`libavformat/demux.c:2517`。
- 最终把内部 codec context 的参数同步回 `AVStream.codecpar`：`libavformat/demux.c:3133`。

这就是为什么 TS、裸 H.264、部分不完整封装中，`avformat_open_input()` 后
`codecpar->extradata` 可能还是空的，而调用 `avformat_find_stream_info()` 后才出现
SPS/PPS。

### 3.3 用户代码把 codecpar 复制给 decoder

应用层打开 decoder 前通常会做：

```c
AVStream *st = fmt_ctx->streams[i];
AVCodecContext *dec_ctx = avcodec_alloc_context3(decoder);

avcodec_parameters_to_context(dec_ctx, st->codecpar);
avcodec_open2(dec_ctx, decoder, NULL);
```

`avcodec_parameters_to_context()` 会复制 extradata 到 `AVCodecContext`，逻辑在
`libavcodec/codec_par.c:205`。

FFmpeg CLI 的 decode 初始化也走这条路径，见 `fftools/ffmpeg_dec.c:1565`。

---

## 4. 编码和封装链路中 extradata 怎么流转？

典型编码链路：

```text
encoder init
  -> encoder 在 AVCodecContext.extradata 中生成全局头
  -> avcodec_parameters_from_context()
  -> AVStream.codecpar->extradata
  -> avformat_write_header()
  -> muxer 写入容器 header / codec private box / sequence header
```

### 4.1 encoder 生成 extradata

encoder 是否生成 extradata、生成什么格式，由具体 encoder 和输出需求决定。常见规律是：

- 如果输出容器要求 global header，应用层会设置 `AV_CODEC_FLAG_GLOBAL_HEADER`。
- encoder 在 `avcodec_open2()` 期间或之后生成 `AVCodecContext.extradata`。
- muxer 写 header 前，应用层把 `AVCodecContext` 参数复制到 `AVStream.codecpar`。

例子：

- FFmpeg native AAC encoder 写 AudioSpecificConfig，见 `libavcodec/aacenc.c:348`。
- libx264 在设置 `AV_CODEC_FLAG_GLOBAL_HEADER` 时调用 `set_extradata()`，见
  `libavcodec/libx264.c:1409`。
- libx264 如果不是 Annex B 输出，会生成 AVCC / `AVCDecoderConfigurationRecord`，
  见 `libavcodec/libx264.c:859`。

### 4.2 复制到 AVStream.codecpar

`avcodec_parameters_from_context()` 会把 encoder context 的 extradata 拷贝到
`AVCodecParameters`，实现位置在 `libavcodec/codec_par.c:138`。

FFmpeg CLI mux 初始化也会做这件事：

- encoding packet 附带参数：`fftools/ffmpeg_enc.c:696`。
- 输出 stream 参数初始化：`fftools/ffmpeg_mux.c:626`。

应用层常见写法：

```c
AVStream *st = avformat_new_stream(oc, NULL);
AVCodecContext *enc_ctx = avcodec_alloc_context3(encoder);

if (oc->oformat->flags & AVFMT_GLOBALHEADER)
    enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

avcodec_open2(enc_ctx, encoder, NULL);
avcodec_parameters_from_context(st->codecpar, enc_ctx);
avformat_write_header(oc, NULL);
```

### 4.3 muxer 负责写成容器自己的格式

muxer 不只是“原样写 bytes”。它会按照输出容器规范，把 `codecpar->extradata` 写到
正确位置：

- MP4/MOV：写入 `avcC`、`hvcC`、`vvcC`、`esds`、`dOps` 等 box。
- FLV：写入 AVC/HEVC/AAC sequence header。
- Matroska/WebM：写入 `CodecPrivate`。
- Ogg：写入 codec header packets。

如果 packet 格式和 muxer 期望不一致，muxer 还可能自动插入 BSF。比如 MPEG-TS muxer
发现 H.264/HEVC/VVC 是 MP4 风格的 length-prefixed packet 时，会插入
`h264_mp4toannexb` / `hevc_mp4toannexb` / `vvc_mp4toannexb`，见
`libavformat/mpegtsenc.c:2308`。

---

## 5. 不同封装容器下 extradata 的常见内容格式

不能只根据 codec 判断 extradata 的格式，必须同时看容器和 bitstream 形态。

### 5.1 MP4 / MOV

MP4/MOV 是集中式 global config 的代表。

| Codec | `AVStream.codecpar->extradata` 常见内容 | 说明 |
| --- | --- | --- |
| H.264 | `avcC` payload，即 `AVCDecoderConfigurationRecord` | 不包含 box size/type；packet 内 NAL 通常是 length-prefixed，不是 Annex B |
| HEVC | `hvcC` payload，即 `HEVCDecoderConfigurationRecord` | 保存 VPS/SPS/PPS 数组和 NAL length size |
| VVC | `vvcC` 配置记录 payload | 类似 HEVC 的配置记录语义 |
| AV1 | `av1C` payload | AV1 codec configuration record |
| AAC | AudioSpecificConfig | 来自 `esds` 的 `DecoderSpecificInfo` |
| Opus | Ogg 风格 `OpusHead` | FFmpeg 从 MP4 `dOps` 转成 `OpusHead`，见 `libavformat/mov.c:8645` |

MP4 里 H.264 的关键区别：

```text
MP4 extradata: avcC
MP4 packet:    [NAL length][NAL][NAL length][NAL]...

Annex B:       00 00 00 01 [NAL] 00 00 00 01 [NAL]...
```

所以 MP4 demux 出来的 H.264 extradata 不是：

```text
00 00 00 01 SPS ... 00 00 00 01 PPS ...
```

而是 `avcC` 配置记录。

### 5.2 MPEG-TS

MPEG-TS 和 MP4 很不一样。TS 的 PMT 通常只告诉 FFmpeg stream type / codec id，
例如 H.264、HEVC、AAC、AC3 等。真正的 codec header 大多在 PES payload 的码流内。

TS 下常见情况：

| Codec | `AVStream.codecpar->extradata` 常见内容 | 来源 |
| --- | --- | --- |
| H.264 | Annex B start-code 风格 SPS/PPS | `extract_extradata` 从 in-band NAL 提取 |
| HEVC | Annex B start-code 风格 VPS/SPS/PPS | `extract_extradata` 从 in-band NAL 提取 |
| VVC | Annex B start-code 风格 VPS/SPS/PPS | `extract_extradata` 从 in-band NAL 提取 |
| AAC ADTS | 通常为空 | 每帧 ADTS header 自带 object type、采样率、声道配置 |
| AAC with MPEG-4 descriptors | AudioSpecificConfig | PMT/SL/FMC descriptor 中的 MPEG-4 descriptor |
| MPEG-2 Video | sequence header 等 start-code 风格头 | `extract_extradata` 从码流提取 |
| Opus | `OpusHead` 风格 extradata | DVB extension descriptor 构造 |

TS demuxer 的 stream type 识别主要在 `libavformat/mpegts.c:916` 和
`libavformat/mpegts.c:934`。MPEG-4 descriptor 路径会调用
`ff_mp4_read_dec_config_descr()`，见 `libavformat/mpegts.c:2065` 和
`libavformat/mpegts.c:2088`。Opus 的 `OpusHead` 构造见
`libavformat/mpegts.c:2250`。

H.264/HEVC/VVC 从 TS 中提取出来的 extradata 是 Annex B 参数集。`extract_extradata`
会为每个参数集写入 4 字节 start code：

```text
00 00 00 01 SPS ...
00 00 00 01 PPS ...
```

HEVC/VVC 则通常是：

```text
00 00 00 01 VPS ...
00 00 00 01 SPS ...
00 00 00 01 PPS ...
```

对应实现见 `libavcodec/bsf/extract_extradata.c:166` 和
`libavcodec/bsf/extract_extradata.c:222`。

### 5.3 FLV

FLV 也有 sequence header 的概念：

- H.264 通常使用 AVC sequence header，内容是 AVCC / `avcC` 风格配置。
- AAC sequence header 通常保存 AudioSpecificConfig。

FFmpeg 的 FLV muxer 如果发现 AAC packet 仍是 ADTS，会自动加 `aac_adtstoasc`；
如果 H.264/HEVC/VVC/AV1/MPEG4 没有 extradata，则可能加 `extract_extradata`，见
`libavformat/flvenc.c:1488`。

### 5.4 Matroska / WebM

Matroska 把 codec 私有初始化数据放在 `CodecPrivate`。FFmpeg 通常把它映射到
`AVStream.codecpar->extradata`。

常见例子：

- H.264：通常是 AVCDecoderConfigurationRecord。
- HEVC：通常是 HEVCDecoderConfigurationRecord。
- AAC：通常是 AudioSpecificConfig。
- Opus：通常是 `OpusHead`。
- Vorbis：通常是打包后的三个 Vorbis header。

因此 Matroska/WebM 也更接近“容器头里有集中配置”的模型。

### 5.5 Ogg

Ogg 的 codec 初始化信息通常来自开头的 header packets。FFmpeg demux 后会把这些
header 整理成对应 codec 的 extradata，例如：

- Opus：`OpusHead`。
- Vorbis：Vorbis identification/comment/setup headers 的打包形式。
- FLAC：STREAMINFO。

### 5.6 裸流 / elementary stream

裸 H.264/H.265 elementary stream 通常是 Annex B 码流，没有容器头。FFmpeg 需要通过
parser / `avformat_find_stream_info()` / `extract_extradata` 从前面的 packet 中拿到
SPS/PPS/VPS。

裸 ADTS AAC 则通常没有独立 extradata，因为每帧 ADTS header 携带必要配置。

---

## 6. 与 extradata 相关的核心 BSF

BSF 全称 bitstream filter，它工作在 encoded packet 层，不解码像素或 PCM，但可以转换
packet 格式、增删 codec header、生成 side data。

API 入口在 `libavcodec/bsf.h`：

```text
av_bsf_get_by_name()
av_bsf_alloc()
av_bsf_init()
av_bsf_send_packet()
av_bsf_receive_packet()
av_bsf_free()
```

### 6.1 extract_extradata

作用：从 packet 内的 in-band headers 中提取全局头，并以
`AV_PKT_DATA_NEW_EXTRADATA` side data 的形式挂到 packet 上。

支持的 codec 见 `libavcodec/bsf/extract_extradata.c:589`，包括：

- AV1
- H.264
- HEVC
- VVC
- MPEG-1/2 Video
- MPEG-4 Video
- VC-1
- AVS2/AVS3/CAVS
- LCEVC

对 H.264/HEVC/VVC，它会识别参数集 NAL：

| Codec | 提取内容 |
| --- | --- |
| H.264 | SPS / PPS |
| HEVC | VPS / SPS / PPS |
| VVC | VPS / SPS / PPS |

输出格式是 Annex B start-code 风格。

`extract_extradata` 有一个 `remove` 选项。默认只提取，不移除原 packet 中的 header；
设置 `remove=1` 时，会把已提取的 header 从 packet 数据中移除。

典型场景：

- `avformat_find_stream_info()` 为缺失 extradata 的视频流补齐参数集。
- 某些 muxer 需要 sequence header，但输入 packet 只有 in-band 参数集。
- 手工命令：`-bsf:v extract_extradata` 或 `-bsf:v extract_extradata=remove=1`。

### 6.2 aac_adtstoasc

作用：把 ADTS AAC 转成 MP4/FLV/Matroska 等容器期望的 ASC + raw AAC 形式。

它做两件事：

1. 解析第一个 ADTS header，构造 AudioSpecificConfig。
2. 移除每个 packet 前面的 ADTS header。

实现入口见 `libavcodec/bsf/aac_adtstoasc.c:39`。注释也直接说明：

```text
creates an MPEG-4 AudioSpecificConfig from an MPEG-2/4 ADTS header
and removes the ADTS header
```

生成的 ASC 会通过 `AV_PKT_DATA_NEW_EXTRADATA` side data 放到第一个 packet 上。

典型场景：

```text
TS/ADTS AAC -> MP4/M4A/FLV/Matroska
```

MOV muxer、FLV muxer、Matroska muxer、LATM muxer 都可能在发现 ADTS AAC 时自动插入
该 BSF。MOV muxer 的自动插入见 `libavformat/movenc.c:9095`。

### 6.3 h264_mp4toannexb / hevc_mp4toannexb / vvc_mp4toannexb

作用：把 MP4 风格的 length-prefixed NAL packet 转成 Annex B start-code packet。

输入通常是：

```text
extradata: avcC / hvcC / vvcC
packet:    [NAL length][NAL][NAL length][NAL]...
```

输出变成：

```text
packet: 00 00 00 01 [NAL] 00 00 00 01 [NAL]...
```

并且会利用 extradata 里的参数集，在关键帧 / IRAP 前补充 SPS/PPS 或 VPS/SPS/PPS。

典型场景：

```text
MP4 H.264/HEVC/VVC -> MPEG-TS
MP4 H.264/HEVC/VVC -> raw Annex B
部分硬解码器要求 Annex B 输入
```

MPEG-TS muxer 自动插入这些 BSF 的逻辑在 `libavformat/mpegtsenc.c:2308`。

H.264 实现会检查输入 extradata 是否已经是 Annex B；如果不是，就从 AVCC 中取出
SPS/PPS，见 `libavcodec/bsf/h264_mp4toannexb.c:260`。HEVC/VVC 类似，分别见
`libavcodec/bsf/hevc_mp4toannexb.c:101` 和
`libavcodec/bsf/vvc_mp4toannexb.c:193`。

### 6.4 dump_extra

作用：把 `par_in->extradata` 重新 prepend 到 packet 前面。

默认只对关键帧生效，也可以配置为所有 packet。实现见
`libavcodec/bsf/dump_extradata.c:40`。

典型场景：

- 输出格式或下游链路希望关键帧前带上全局头。
- 调试“参数集只在 extradata 里，packet 里没有”的问题。

### 6.5 remove_extra

作用：从 packet 内移除 in-band global headers。实现见
`libavcodec/bsf/remove_extradata.c:182`。

它按 codec 调用不同 split 函数，识别并跳过 H.264、HEVC、MPEG-1/2、MPEG-4、VC-1、
AV1 等码流开头的 header。

典型场景：

- 输出容器已经把 global header 放进 extradata，不希望 packet 内重复带一份。
- 规范化 stream copy 输出。

---

## 7. 几个典型转换 Case

### 7.1 MP4 H.264 转 TS

输入 MP4：

```text
codecpar->extradata = avcC
packet              = length-prefixed NAL
```

TS 期望：

```text
packet = Annex B start-code NAL
关键帧附近最好有 SPS/PPS
```

FFmpeg 通常会自动插入：

```text
h264_mp4toannexb
```

BSF 从 `avcC` 中读取 SPS/PPS 和 NAL length size，把 packet 改成 Annex B，并在需要时补
SPS/PPS。

### 7.2 TS H.264 转 MP4

输入 TS：

```text
packet 内通常已经是 Annex B
SPS/PPS 可能出现在码流内
codecpar->extradata 初始可能为空
```

FFmpeg 读取流信息时：

```text
extract_extradata 从 packet 里提取 SPS/PPS
-> AV_PKT_DATA_NEW_EXTRADATA
-> 内部 AVCodecContext.extradata
-> AVStream.codecpar->extradata
```

写 MP4 时，muxer 需要把 Annex B 参数集转换成 MP4 的 `avcC` 配置记录，同时 packet
也要满足 MP4 的存储要求。这个过程由 muxer 和相关 bitstream 处理共同完成。

### 7.3 TS/ADTS AAC 转 MP4

输入：

```text
packet = ADTS header + AAC raw data
codecpar->extradata 通常为空
```

MP4 期望：

```text
extradata = AudioSpecificConfig
packet    = AAC raw data，不带 ADTS header
```

FFmpeg 会使用：

```text
aac_adtstoasc
```

它从第一个 ADTS header 生成 ASC，并移除所有 ADTS header。

### 7.4 MP4 AAC 转 ADTS/TS

输入 MP4：

```text
extradata = AudioSpecificConfig
packet    = AAC raw data
```

输出 ADTS/TS：

```text
packet = ADTS header + AAC raw data
```

这时不是 `aac_adtstoasc`，而是 muxer 根据 ASC 和 stream 参数写出 ADTS header。
`aac_adtstoasc` 只负责 ADTS -> ASC 方向。

---

## 8. 常见判断规则

### 8.1 extradata 是解码某路 stream 的元数据吗？

可以这么理解，但要加限定：

```text
extradata 是 codec-specific 的解码初始化数据，不是通用媒体元数据。
```

它通常描述“如何解码这一路 stream”，例如 H.264 SPS/PPS、AAC ASC、OpusHead。

### 8.2 解码时是谁生成 extradata？

通常是 demuxer：

- 从容器 header / box / descriptor 读取；
- 或在 `avformat_find_stream_info()` 中借助 `extract_extradata` 从 packet 中提取。

有些动态场景会通过 packet side data `AV_PKT_DATA_NEW_EXTRADATA` 更新。

### 8.3 编码时是谁生成 extradata？

通常是 encoder：

- encoder 初始化后把全局头写入 `AVCodecContext.extradata`；
- 应用层调用 `avcodec_parameters_from_context()` 复制到 `AVStream.codecpar`；
- muxer 再写到容器 header / codec private 区域。

stream copy 时没有重新编码，extradata 通常来自输入 demuxer，必要时由 BSF 转换。

### 8.4 extradata 格式能不能只看 codec_id？

不能。必须同时看：

- codec；
- 输入容器；
- packet 当前是 Annex B 还是 length-prefixed；
- 是否经过 BSF；
- muxer 期望的输出格式。

最典型的反例：

```text
H.264 in MP4: extradata = avcC
H.264 in TS:  extradata = Annex B SPS/PPS
```

### 8.5 没有 extradata 一定是错误吗？

不一定。

常见不依赖 extradata 的情况：

- ADTS AAC：每帧 ADTS header 自带配置。
- MP3：帧头自描述。
- AC3/EAC3：帧头自描述，容器可能还有额外 descriptor，但 decoder 不一定依赖
  `codecpar->extradata`。
- PCM：通常靠 codecpar 的 sample format、sample rate、channel layout 等字段。

---

## 9. 调试建议

### 9.1 用 ffprobe 看 extradata

可以查看大小和 hash：

```bash
ffprobe -show_streams -show_data_hash crc32 input.mp4
```

如果需要看原始内容：

```bash
ffprobe -show_streams -show_data input.mp4
```

观察重点：

- `extradata_size` 是否存在；
- H.264 MP4 的 extradata 是否以 `01` 开头，通常表示 AVCC；
- H.264 Annex B extradata 是否能看到 `00 00 00 01`；
- AAC MP4 的 extradata 是否通常是 2 字节或更长 ASC；
- TS 输入是否在调用 `avformat_find_stream_info()` 后才出现 extradata。

### 9.2 看 packet 格式

H.264/H.265 的问题常常不是“有没有 extradata”，而是：

```text
extradata 格式和 packet 格式是否匹配？
```

例如：

- `avcC` + length-prefixed packet：适合 MP4。
- Annex B SPS/PPS + Annex B packet：适合 TS/raw/hardware decoder 场景。
- `avcC` + Annex B packet 或 Annex B extradata + length-prefixed packet：很容易出问题。

### 9.3 关注自动插入 BSF 的日志

命令行加日志级别：

```bash
ffmpeg -loglevel verbose -i input.mp4 -c copy out.ts
```

可以看到 muxer 是否自动插入 `h264_mp4toannexb`、`aac_adtstoasc` 等过滤器。

---

## 10. 总结

`extradata` 是 FFmpeg 在 demuxer/muxer 和 codec 之间传递 codec 初始化信息的核心机制。
它不是通用元数据，而是 codec 私有的二进制全局头。

解码链路中，extradata 通常由 demuxer 从容器头读取；如果容器没有集中配置，则可能由
`avformat_find_stream_info()` 借助 `extract_extradata` 从 packet 中提取。随后应用层
通过 `avcodec_parameters_to_context()` 复制给 decoder。

编码链路中，extradata 通常由 encoder 生成到 `AVCodecContext`，再通过
`avcodec_parameters_from_context()` 复制到输出 `AVStream.codecpar`，最终由 muxer 写成
目标容器自己的配置结构。

理解 extradata 时要始终同时看三件事：

```text
codec 是什么？
容器是什么？
packet 当前是什么 bitstream 格式？
```

只看 `codec_id` 不够。H.264 在 MP4 中的 `avcC` 和在 TS 中的 Annex B SPS/PPS，就是
最典型的区别。
