# AAC 元数据：ADTS 与 ASC 的区别、转换和常见坑

在音视频工程里说“AAC 元数据”，通常不是指 ID3、title、artist 这类媒体标签，而是指
**解码 AAC 所必须知道的音频配置**：AAC profile、采样率、声道配置、SBR/PS 扩展等。

这些信息可以放在不同位置。最常见的两种形式是：

- **ADTS**：每个 AAC frame 前面都有一个 7 或 9 字节的头。
- **ASC / AudioSpecificConfig**：把 AAC 配置放在容器的 extradata 里，音频 packet
  里通常只保留 raw AAC frame。

理解这两种形式非常重要。很多“MP4 里的 AAC 提取出来不能直接播放”“TS 里的 AAC
放进 MP4 失败”“播放器提示 AAC extradata missing”的问题，本质都是 ADTS 和 ASC
没有正确转换。

本文聚焦 FFmpeg 常见链路：

- ADTS AAC：常见于 `.aac`、MPEG-TS、部分直播流。
- ASC AAC：常见于 MP4/M4A/FLV/Matroska 等容器的 codec extradata。

> 说明：AAC 还有 LATM/LOAS 等传输方式，本文不展开。

---

## 1. AAC 元数据到底描述什么？

一个 AAC decoder 在解码 raw AAC frame 前，需要先知道这些核心配置：

| 配置 | 含义 |
| --- | --- |
| `audioObjectType` / `object_type` | AAC 类型，例如 AAC Main、AAC LC、HE-AAC |
| `samplingFrequencyIndex` | 采样率索引，例如 44.1 kHz 对应索引 4 |
| `samplingFrequency` | 当索引为显式采样率时使用，常规场景较少 |
| `channelConfiguration` | 声道布局编号，例如 1 是 mono，2 是 stereo |
| `SBR / PS` | HE-AAC / HE-AACv2 相关扩展信息 |
| `frameLengthFlag` | 每帧 1024 或 960 samples，常规 AAC-LC 多为 1024 |

其中最核心、最常见的三个字段是：

```text
object_type
sampling_index
channel_config
```

如果只有 raw AAC frame，而没有这些信息，decoder 很难知道应该按什么采样率、什么声道数
和什么 profile 去解释数据。

---

## 2. ADTS：每帧自带头的 AAC

ADTS 全称是 Audio Data Transport Stream。它的特点是：

```text
[ADTS header][AAC raw data]
[ADTS header][AAC raw data]
[ADTS header][AAC raw data]
...
```

每个 AAC frame 前面都有 ADTS header。没有 CRC 时 header 是 7 字节；有 CRC 时是
9 字节。

### 2.1 ADTS 头里的关键字段

ADTS fixed header 和 variable header 里有这些常用字段：

| 字段 | 位数 | 作用 |
| --- | ---: | --- |
| `syncword` | 12 | 固定为 `0xfff`，用于同步帧边界 |
| `ID` | 1 | MPEG-2 / MPEG-4 标识 |
| `layer` | 2 | 固定为 0 |
| `protection_absent` | 1 | 是否没有 CRC，1 表示无 CRC |
| `profile_objecttype` | 2 | AAC profile，注意它比 ASC 的 object type 小 1 |
| `sample_frequency_index` | 4 | 采样率索引 |
| `channel_configuration` | 3 | 声道配置 |
| `aac_frame_length` | 13 | 当前 ADTS header + AAC payload + CRC 的总长度 |
| `adts_buffer_fullness` | 11 | 码率控制相关，常见写 `0x7ff` 表示 VBR |
| `number_of_raw_data_blocks_in_frame` | 2 | 当前 ADTS frame 中 raw data block 数减 1 |

FFmpeg 解析 ADTS 头的位置：

```text
libavcodec/adts_header.c
```

核心逻辑可以概括为：

```c
object_type    = profile_objecttype + 1;
sampling_index = sample_frequency_index;
chan_config    = channel_configuration;
samples        = (number_of_raw_data_blocks_in_frame + 1) * 1024;
frame_length   = aac_frame_length;
```

这里最容易记错的是：

```text
ADTS profile_objecttype = ASC audioObjectType - 1
```

例如 AAC LC 的 `audioObjectType` 是 2，在 ADTS 里写的是 1。

---

## 3. ASC：容器级 AAC 配置

ASC 全称是 AudioSpecificConfig，是 MPEG-4 Audio 的配置结构。

它通常不出现在每个音频 packet 前面，而是作为容器的 codec extradata 存在。例如：

```text
MP4/M4A:
  stsd -> mp4a -> esds -> DecoderSpecificInfo(AudioSpecificConfig)

FLV:
  AAC sequence header 里保存 AudioSpecificConfig

Matroska:
  CodecPrivate 里保存 AudioSpecificConfig
```

packet 本身通常是：

```text
[AAC raw data]
[AAC raw data]
[AAC raw data]
...
```

解码器先从容器拿到 ASC，再用 ASC 解析后续 raw AAC frame。

### 3.1 最常见的 2 字节 ASC

对普通 AAC-LC、固定采样率、常规声道配置来说，ASC 经常只有 2 字节：

```text
5 bits: audioObjectType
4 bits: samplingFrequencyIndex
4 bits: channelConfiguration
```

按位排布可以写成：

```text
byte0: audioObjectType[4:0] + samplingFrequencyIndex[3:1]
byte1: samplingFrequencyIndex[0] + channelConfiguration[3:0] + padding
```

构造代码：

```c
asc[0] = (object_type << 3) | (sampling_index >> 1);
asc[1] = ((sampling_index & 1) << 7) | (channel_config << 3);
```

例如：

```text
AAC-LC, 44.1 kHz, stereo
object_type    = 2
sampling_index = 4
channel_config = 2

ASC = 0x12 0x10
```

FFmpeg 解析 MPEG-4 Audio 配置的位置：

```text
libavcodec/mpeg4audio.c
libavcodec/mpeg4audio.h
```

结构体里对应这些字段：

```c
typedef struct MPEG4AudioConfig {
    int object_type;
    int sampling_index;
    int sample_rate;
    int chan_config;
    int sbr;
    int ext_object_type;
    int ext_sampling_index;
    int ext_sample_rate;
    int ext_chan_config;
    int channels;
    int ps;
    int frame_length_short;
} MPEG4AudioConfig;
```

---

## 4. ADTS 到 ASC：从每帧头提取成 extradata

ADTS 转 ASC 的核心思路是：

1. 读取第一个 ADTS header。
2. 从 header 中取出 `profile_objecttype`、`sample_frequency_index`、
   `channel_configuration`。
3. 换算出 ASC 里的 `audioObjectType`。
4. 生成 ASC extradata。
5. 对每个 packet 删除 ADTS header，只保留 AAC raw data。

流程图：

```text
ADTS AAC input
  [ADTS header][AAC raw data]
  [ADTS header][AAC raw data]

转换后：

container extradata:
  [AudioSpecificConfig]

packets:
  [AAC raw data]
  [AAC raw data]
```

伪代码：

```c
parse_adts_header(buf, &hdr);

object_type    = hdr.profile_objecttype + 1;
sampling_index = hdr.sample_frequency_index;
channel_config = hdr.channel_configuration;

asc[0] = (object_type << 3) | (sampling_index >> 1);
asc[1] = ((sampling_index & 1) << 7) | (channel_config << 3);

payload_offset = hdr.protection_absent ? 7 : 9;
packet.data   += payload_offset;
packet.size   -= payload_offset;
```

FFmpeg 里对应的 bitstream filter：

```text
libavcodec/bsf/aac_adtstoasc.c
```

命令行示例：

```bash
ffmpeg -i input.aac -c:a copy -bsf:a aac_adtstoasc output.m4a
```

在很多 MP4/M4A 输出场景，FFmpeg 会自动插入 `aac_adtstoasc`。但在排查问题或写
SDK/播放器链路时，显式理解这一步很重要。

---

## 5. ASC 到 ADTS：给每个 raw AAC frame 补头

ASC 转 ADTS 的核心思路是：

1. 解析容器 extradata 中的 ASC。
2. 得到 `object_type`、`sampling_index`、`channel_config`。
3. 对每个 AAC raw frame，根据 payload size 生成 ADTS header。
4. 输出 `[ADTS header][AAC raw data]`。

流程图：

```text
container extradata:
  [AudioSpecificConfig]

packets:
  [AAC raw data]
  [AAC raw data]

转换后：

ADTS AAC output
  [ADTS header][AAC raw data]
  [ADTS header][AAC raw data]
```

常见无 CRC ADTS 头生成代码：

```c
int header_size  = 7;
int frame_length = header_size + aac_payload_size;
int profile      = object_type - 1;

adts[0] = 0xFF;
adts[1] = 0xF1; /* MPEG-4, layer 0, no CRC */
adts[2] = (profile << 6) | (sampling_index << 2) | (channel_config >> 2);
adts[3] = ((channel_config & 3) << 6) | (frame_length >> 11);
adts[4] = (frame_length >> 3) & 0xFF;
adts[5] = ((frame_length & 7) << 5) | 0x1F;
adts[6] = 0xFC;
```

注意：

```text
aac_frame_length = ADTS header size + AAC payload size + optional CRC size
```

也就是说，ADTS 的长度字段不是 payload 长度，而是整帧长度。

FFmpeg 写 ADTS 的 muxer 位置：

```text
libavformat/adtsenc.c
```

它会先解析 extradata 中的 ASC，再为每个 packet 写 ADTS header。

命令行示例：

```bash
ffmpeg -i input.m4a -c:a copy -f adts output.aac
```

---

## 6. 两种形式不是完全对称的

ADTS 和 ASC 可以互转，但不是所有信息都能无损来回。

### 6.1 ADTS 能表达的信息更偏传输层

ADTS 每帧都有这些传输层信息：

- 当前帧长度。
- 是否有 CRC。
- buffer fullness。
- 当前 ADTS frame 里有几个 raw data block。

这些字段通常不会进入 ASC。ASC 更像“解码配置”，不是“每帧传输头”。

### 6.2 ASC 能表达的信息比普通 ADTS 头更丰富

ASC 可以表达：

- escape object type。
- 显式采样率。
- SBR / PS 扩展。
- GASpecificConfig。
- PCE 等更复杂配置。

而普通 ADTS fixed header 中 `profile_objecttype` 只有 2 bits，不能完整表达所有
MPEG-4 Audio object type。

所以：

```text
普通 AAC-LC stereo:
  ADTS <-> ASC 基本直接转换

HE-AAC / HE-AACv2 / PCE / 非常规 object type:
  需要更谨慎，不能只按 2 字节 ASC 和 7 字节 ADTS 头硬套
```

---

## 7. 常见踩坑点

### 7.1 忘记 `object_type = profile + 1`

ADTS 里的 `profile_objecttype` 和 ASC 里的 `audioObjectType` 差 1。

常见映射：

| AAC 类型 | ASC `audioObjectType` | ADTS `profile_objecttype` |
| --- | ---: | ---: |
| AAC Main | 1 | 0 |
| AAC LC | 2 | 1 |
| AAC SSR | 3 | 2 |
| AAC LTP | 4 | 3 |

如果这里写错，decoder 可能按错误 profile 解码，轻则无声，重则直接报 invalid data。

### 7.2 把 ADTS 长度字段当成 payload 长度

`aac_frame_length` 包含：

```text
ADTS header + AAC raw data + optional CRC
```

不是单纯的 AAC payload size。

如果自己切帧时用错长度，后面所有帧边界都会错位。

### 7.3 没处理 7 字节和 9 字节 header 的区别

ADTS 里：

```text
protection_absent = 1 -> 无 CRC，header 7 字节
protection_absent = 0 -> 有 CRC，header 9 字节
```

删除 ADTS header 时必须按这个字段判断。固定跳过 7 字节会在有 CRC 的流里把 CRC
误当作 AAC payload。

### 7.4 以为 ASC 永远只有 2 字节

普通 AAC-LC 经常是 2 字节 ASC，但这只是最常见情况，不是协议上限。

遇到这些情况时 ASC 会更长：

- HE-AAC / HE-AACv2。
- `samplingFrequencyIndex == 0x0f`，后面跟 24-bit 显式采样率。
- `audioObjectType == 31`，使用 escape object type。
- `channelConfiguration == 0`，需要 PCE 描述声道布局。

工程实现里不能把 extradata 长度硬编码成 2。

### 7.5 `channel_configuration == 0` 不能只靠三位声道号

当 `channel_configuration` 为 0 时，声道布局不在这个字段里，而是在 PCE
（Program Config Element）里。

这时从 ADTS 头只能得到：

```text
channel_configuration = 0
```

但不能知道完整声道布局。FFmpeg 的 `aac_adtstoasc` 对这种情况会尝试从第一个 raw
AAC frame 里复制 PCE 数据放进新的 extradata。如果第一个语法元素不是 PCE，就不能
简单转换。

### 7.6 HE-AAC 的真实采样率容易误解

HE-AAC 使用 SBR 时，可能存在核心 AAC 采样率和扩展采样率两个概念。

例如容器或解码器看到的播放采样率可能是 44.1 kHz，但 AAC core 可能按 22.05 kHz
编码，再通过 SBR 扩展到 44.1 kHz。

如果只看 ADTS 头里的 `sample_frequency_index`，可能不足以表达完整 HE-AAC 配置。

### 7.7 raw AAC frame 边界必须已知

ASC 转 ADTS 时，需要给每个 AAC raw frame 单独写 header。ADTS header 里有当前帧的
`aac_frame_length`，所以必须先知道每个 packet/frame 的边界和大小。

如果手里是一段裸字节流，没有容器 packet 边界，也没有 ADTS 头，就不能凭空可靠地切出
每个 AAC frame。

### 7.8 不要把 LATM/LOAS 当成 ADTS

有些直播或传输链路使用 AAC LATM/LOAS。它不是 ADTS，帧头结构也不一样。

如果同步字不是 `0xfff`，或者解析 ADTS header 一直失败，不要强行按 ADTS 跳 7 字节。

### 7.9 MP4 里通常不应该保留 ADTS header

MP4/M4A 的 AAC packet 通常应该是 raw AAC frame，配置放在 ASC/extradata 里。

如果把带 ADTS header 的 AAC frame 直接塞进 MP4 packet，很容易导致：

```text
decoder 看到的 payload 前面多了 7/9 字节垃圾
```

这也是 `aac_adtstoasc` 存在的主要原因。

---

## 8. FFmpeg 里的对应关系

| 方向 | FFmpeg 组件 | 位置 |
| --- | --- | --- |
| 解析 ADTS header | ADTS parser | `libavcodec/adts_header.c` |
| 解析 ASC | MPEG-4 Audio config parser | `libavcodec/mpeg4audio.c` |
| ADTS -> ASC | bitstream filter | `libavcodec/bsf/aac_adtstoasc.c` |
| ASC -> ADTS | ADTS muxer | `libavformat/adtsenc.c` |

常用命令：

```bash
# ADTS AAC -> MP4/M4A，需要生成 ASC 并移除 ADTS header
ffmpeg -i input.aac -c:a copy -bsf:a aac_adtstoasc output.m4a

# MP4/M4A -> ADTS AAC，需要读取 ASC 并为每帧补 ADTS header
ffmpeg -i input.m4a -c:a copy -f adts output.aac

# 查看 extradata / codec 配置
ffprobe -show_streams -show_format input.m4a
```

---

## 9. 一句话总结

ADTS 和 ASC 描述的是同一类 AAC 解码配置，但服务的封装场景不同：

```text
ADTS = 每帧自描述，适合裸 AAC 流或 TS 传输
ASC  = 容器级配置，适合 MP4/M4A/FLV 等容器
```

ADTS 转 ASC 时，要从 ADTS header 提取 profile、采样率索引、声道配置，生成
AudioSpecificConfig，并从 packet 中删除 ADTS header。

ASC 转 ADTS 时，要先解析 AudioSpecificConfig，再根据每个 AAC frame 的 payload
大小逐帧生成 ADTS header。

普通 AAC-LC stereo 的转换很直接；一旦遇到 HE-AAC、PCE、CRC、多 raw data block、
显式采样率或 LATM/LOAS，就不能再用“2 字节 ASC + 7 字节 ADTS”的简化模型硬套。
