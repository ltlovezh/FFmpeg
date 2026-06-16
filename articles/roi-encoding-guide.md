# ROI 编码学习指南：Android 与 FFmpeg 的真实实现边界

ROI，Region of Interest，感兴趣区域编码，本质是告诉编码器：一帧里不同区域的重要性不同。人脸、商品、字幕、屏幕共享文字通常比背景墙、天空、桌面更重要。编码器如果能把更多码率分配给重要区域，把更少码率分配给非重要区域，就可以在相同码率下提升主观质量，或在相近主观质量下降低码率。

从控制手段看，ROI 通常不是“把某块画面单独编码”，而是影响块级 QP。QP 越低，量化越轻，质量越好，码率更高；QP 越高，量化越重，质量更差，码率更低。ROI 编码就是对目标区域施加负 QP offset，对不重要区域施加 0 或正 QP offset。

但必须先讲清楚一个边界：ROI 是码率分配策略，不是画质魔法。如果 ROI 选错，比如把运动背景标成高优先级，编码器可能牺牲后续帧质量。Android 官方 `FEATURE_Roi` 文档也明确说，ROI 选择不当可能提升局部质量但损害后续帧质量。

## 依据来源

本文结论基于以下官方文档和源码：

- Android `MediaCodec.PARAMETER_KEY_QP_OFFSET_MAP` / `PARAMETER_KEY_QP_OFFSET_RECTS` 官方文档：<https://developer.android.com/reference/android/media/MediaCodec#PARAMETER_KEY_QP_OFFSET_MAP>
- Android `MediaCodecInfo.CodecCapabilities.FEATURE_Roi` 官方文档：<https://developer.android.com/reference/android/media/MediaCodecInfo.CodecCapabilities#FEATURE_Roi>
- Android AOSP 增加 ROI 常量的提交：<https://android.googlesource.com/platform/frameworks/base.git/+/89cf6a2b8030a8757298c2e6cd87456b7cf0ea3a%5E%21/>
- FFmpeg `AV_FRAME_DATA_REGIONS_OF_INTEREST` 与 `AVRegionOfInterest` 源码：`libavutil/frame.h`
- FFmpeg libx264 ROI 传递路径源码：`libavcodec/libx264.c`
- FFmpeg `addroi` 滤镜文档与源码：`doc/filters.texi`、`libavfilter/vf_addroi.c`

## 一、为什么需要 ROI 编码

移动端视频常见约束有三个。

第一，上行带宽有限。直播、RTC、远程会议里，上行码率经常比本地编码能力更先成为瓶颈。用户真正关注的是人脸、手势、商品、屏幕文字，而不是背景纹理。

第二，弱网下要保住核心区域。普通码控在码率不足时会全图一起劣化。ROI 可以让编码器优先保护核心区域：背景可以更糊，但人脸、文字、商品细节尽量清楚。

第三，码率波动更可控。镜头晃动、背景纹理复杂、主播大幅动作时，背景会抢码率。ROI 可以降低非关键区域优先级，让码率更多服务于主观质量。

一个实际原则是：ROI 更适合“主观重要区域稳定明确”的场景，比如人脸视频、商品直播、在线教育板书、屏幕共享文字区域。不适合盲目全局启用。

## 二、Android 硬编 ROI：MediaCodec 的标准实现

Android 的标准 ROI 硬编 API 来自 `MediaCodec`，但关键点是：不是 Android 12，而是 API 35 / Android 15 才新增标准 ROI 参数。

官方事实：

- `MediaCodec.PARAMETER_KEY_QP_OFFSET_MAP`：API 35 新增，用 byte array 表示全帧 16x16 粒度的 QP offset map。
- `MediaCodec.PARAMETER_KEY_QP_OFFSET_RECTS`：API 35 新增，用字符串表示若干 ROI 矩形及 offset。
- `MediaCodecInfo.CodecCapabilities.FEATURE_Roi`：API 35 新增，用来判断编码器是否支持 ROI。
- QP 计算逻辑是 `frameQP + offsetQP`；负 offset 表示更低 QP，即更高质量；正 offset 表示更高 QP，即更低质量。
- map 的大小必须是 `((width + 15) / 16) * ((height + 15) / 16)`。
- 参数作用域会持续到运行中重新配置，所以 ROI 消失时要主动清空或更新 map。

### Android 核心控制代码：QP Offset Map

```java
import android.graphics.Rect;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;

import java.util.Arrays;
import java.util.List;

public final class AndroidRoiControl {
    private static final int ROI_BLOCK = 16;

    public static boolean supportsStandardRoi(String mime) {
        if (Build.VERSION.SDK_INT < 35) {
            return false;
        }

        MediaCodecList list = new MediaCodecList(MediaCodecList.REGULAR_CODECS);
        for (MediaCodecInfo info : list.getCodecInfos()) {
            if (!info.isEncoder()) {
                continue;
            }
            for (String type : info.getSupportedTypes()) {
                if (!type.equalsIgnoreCase(mime)) {
                    continue;
                }
                MediaCodecInfo.CodecCapabilities caps =
                        info.getCapabilitiesForType(type);
                if (caps.isFeatureSupported(
                        MediaCodecInfo.CodecCapabilities.FEATURE_Roi)) {
                    return true;
                }
            }
        }
        return false;
    }

    public static void setRoiMap(
            MediaCodec encoder,
            int width,
            int height,
            List<Rect> roiRects,
            int roiQpOffset
    ) {
        if (Build.VERSION.SDK_INT < 35) {
            return;
        }

        int mapWidth = (width + ROI_BLOCK - 1) / ROI_BLOCK;
        int mapHeight = (height + ROI_BLOCK - 1) / ROI_BLOCK;
        byte[] qpOffsetMap = new byte[mapWidth * mapHeight];

        // 0 表示非 ROI 区域不主动偏移。
        Arrays.fill(qpOffsetMap, (byte) 0);

        // 负值提升质量。先从 -3 到 -8 做 A/B 测试，不建议一开始就给极端值。
        byte offset = (byte) Math.max(-128, Math.min(127, roiQpOffset));

        for (Rect rect : roiRects) {
            Rect r = new Rect(
                    Math.max(0, rect.left),
                    Math.max(0, rect.top),
                    Math.min(width, rect.right),
                    Math.min(height, rect.bottom)
            );

            if (r.left >= r.right || r.top >= r.bottom) {
                continue;
            }

            int blockLeft = r.left / ROI_BLOCK;
            int blockTop = r.top / ROI_BLOCK;
            int blockRight = (r.right + ROI_BLOCK - 1) / ROI_BLOCK;
            int blockBottom = (r.bottom + ROI_BLOCK - 1) / ROI_BLOCK;

            blockRight = Math.min(blockRight, mapWidth);
            blockBottom = Math.min(blockBottom, mapHeight);

            for (int y = blockTop; y < blockBottom; y++) {
                for (int x = blockLeft; x < blockRight; x++) {
                    qpOffsetMap[y * mapWidth + x] = offset;
                }
            }
        }

        Bundle params = new Bundle();
        params.putByteArray(MediaCodec.PARAMETER_KEY_QP_OFFSET_MAP, qpOffsetMap);

        // 对 Surface 输入：在提交下一帧渲染前调用。
        // 对 ByteBuffer 输入：在 queueInputBuffer 前调用。
        encoder.setParameters(params);
    }

    public static void clearRoi(MediaCodec encoder, int width, int height) {
        if (Build.VERSION.SDK_INT < 35) {
            return;
        }

        int mapWidth = (width + ROI_BLOCK - 1) / ROI_BLOCK;
        int mapHeight = (height + ROI_BLOCK - 1) / ROI_BLOCK;
        byte[] qpOffsetMap = new byte[mapWidth * mapHeight];

        Bundle params = new Bundle();
        params.putByteArray(MediaCodec.PARAMETER_KEY_QP_OFFSET_MAP, qpOffsetMap);
        encoder.setParameters(params);
    }
}
```

也可以使用 `PARAMETER_KEY_QP_OFFSET_RECTS`，格式是：

```java
Bundle params = new Bundle();
params.putString(
        MediaCodec.PARAMETER_KEY_QP_OFFSET_RECTS,
        "100,200-380,520=-6;400,100-520,280=-3"
);
encoder.setParameters(params);
```

矩形格式是：

```text
Top,Left-Bottom,Right=Offset
```

但 `RECTS` 的最大矩形数量是设备相关的，重叠时前面的矩形优先。所以生产环境里，`QP_OFFSET_MAP` 更适合精细控制，`RECTS` 更适合少量目标区域的简单控制。

## 三、FFmpeg 软编 ROI：AVFrame Side Data 到 libx264

FFmpeg 的 ROI 机制是真正的编码器侧 ROI 控制。官方结构是 `AV_FRAME_DATA_REGIONS_OF_INTEREST`，数据是一个或多个 `AVRegionOfInterest`。

FFmpeg 源码事实：

- `AV_FRAME_DATA_REGIONS_OF_INTEREST` 定义在 `libavutil/frame.h`。
- `AVRegionOfInterest` 包含 `top`、`bottom`、`left`、`right`、`qoffset`。
- `qoffset` 范围是 `-1..+1`，负值更好质量，正值更差质量。
- libx264 会读取该 side data，并转换为 x264 的 `pic->prop.quant_offsets`。
- x264 路径按 16x16 macroblock 映射。
- 如果 x264 adaptive quantization 被关闭，FFmpeg 会跳过 ROI。

FFmpeg 也有现成滤镜 `addroi`，它不改像素，只给 frame 附加 ROI metadata，后续编码器决定是否使用。

命令行示例：

```bash
ffmpeg -i input.mp4 \
  -vf "addroi=iw/4:ih/4:iw/2:ih/2:-1/10" \
  -c:v libx264 \
  output.mp4
```

### FFmpeg C/C++ 核心控制代码

```cpp
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/rational.h>
}

static int attach_roi(
    AVFrame *frame,
    int left,
    int top,
    int right,
    int bottom,
    AVRational qoffset
) {
    if (!frame || left >= right || top >= bottom) {
        return AVERROR(EINVAL);
    }

    AVFrameSideData *sd = av_frame_new_side_data(
        frame,
        AV_FRAME_DATA_REGIONS_OF_INTEREST,
        sizeof(AVRegionOfInterest)
    );
    if (!sd) {
        return AVERROR(ENOMEM);
    }

    auto *roi = reinterpret_cast<AVRegionOfInterest *>(sd->data);
    roi->self_size = sizeof(*roi);
    roi->left = left;
    roi->top = top;
    roi->right = right;
    roi->bottom = bottom;

    // qoffset 必须在 -1 到 +1。
    // -1/10 是温和提升；对 10-bit H.264 约等价于 -6.3 QP。
    roi->qoffset = qoffset;

    return 0;
}

static AVCodecContext *create_x264_encoder(int width, int height, int bitrate) {
    const AVCodec *codec = avcodec_find_encoder_by_name("libx264");
    if (!codec) {
        return nullptr;
    }

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        return nullptr;
    }

    ctx->width = width;
    ctx->height = height;
    ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    ctx->time_base = AVRational{1, 30};
    ctx->framerate = AVRational{30, 1};
    ctx->bit_rate = bitrate;
    ctx->gop_size = 60;
    ctx->max_b_frames = 0;

    av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
    av_opt_set(ctx->priv_data, "tune", "zerolatency", 0);

    // libx264.c 里明确检查 AQ；关闭 AQ 时 ROI 会被跳过。
    av_opt_set(ctx->priv_data, "aq-mode", "variance", 0);

    if (avcodec_open2(ctx, codec, nullptr) < 0) {
        avcodec_free_context(&ctx);
        return nullptr;
    }

    return ctx;
}

static int encode_one_frame_with_roi(
    AVCodecContext *ctx,
    AVFrame *frame,
    int roiLeft,
    int roiTop,
    int roiRight,
    int roiBottom
) {
    int ret = attach_roi(
        frame,
        roiLeft,
        roiTop,
        roiRight,
        roiBottom,
        av_make_q(-1, 10)
    );
    if (ret < 0) {
        return ret;
    }

    ret = avcodec_send_frame(ctx, frame);
    if (ret < 0) {
        return ret;
    }

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        return AVERROR(ENOMEM);
    }

    while ((ret = avcodec_receive_packet(ctx, pkt)) == 0) {
        // 这里写文件、封装 muxer 或推流。
        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);

    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    }
    return ret;
}
```

多个 ROI 区域时，side data 分配 `sizeof(AVRegionOfInterest) * n`，然后逐个填充即可。注意 FFmpeg 结构说明里写了：重叠区域以第一个命中的 ROI 为准；libx264 代码里反向遍历数组，就是为了保证这个语义。

## 四、方案对比

| 平台 | 是否有公开原生 ROI 控制 | 控制粒度 | 推荐结论 |
|---|---:|---:|---|
| Android MediaCodec | 有，API 35+ | 16x16 map 或矩形 | Android 15+ 可用标准 ROI；低版本只能走厂商扩展或预处理降级 |
| FFmpeg + libx264 | 有 | 16x16 macroblock | 软编可控性最好，但 CPU/功耗成本高 |
| FFmpeg + MediaCodec | 不能默认等同于 ROI | 取决于 FFmpeg wrapper 是否转接 Android ROI | 当前本地 FFmpeg `mediacodecenc.c` 未看到 ROI side data 转 Android ROI 参数的路径 |

Android MediaCodec 和 FFmpeg 软编控制 ROI 的核心差异如下：

| 对比项 | Android MediaCodec 标准 ROI | FFmpeg 软编 ROI |
|---|---|---|
| API 层级 | 平台硬编 API，`MediaCodec.setParameters(Bundle)` | FFmpeg frame side data，随 `AVFrame` 进入编码器 |
| 标准入口 | `PARAMETER_KEY_QP_OFFSET_MAP` 或 `PARAMETER_KEY_QP_OFFSET_RECTS` | `AV_FRAME_DATA_REGIONS_OF_INTEREST` + `AVRegionOfInterest` |
| 可用版本 | Android API 35+，且 codec 必须支持 `FEATURE_Roi` | 取决于 FFmpeg 版本和具体编码器；libx264/libx265/libvpx 等路径支持 |
| 输入形式 | 全帧 16x16 QP offset map，或像素矩形字符串 | 一个或多个 ROI 矩形结构体，挂在每个 `AVFrame` 上 |
| 控制粒度 | 应用层 map 固定 16x16；rect 会对齐到编码器 LCU 边界 | libx264 路径按 16x16 macroblock 转成 `quant_offsets` |
| QP 表达方式 | 整数 offset，范围为 byte/rect offset 的 `[-128, 127]` | `AVRational qoffset`，语义范围 `[-1, +1]` |
| QP 计算语义 | `targetQP = frameQP + offsetQP`，负值提升质量，正值降低质量 | FFmpeg 将 `qoffset * qp_range` 转成编码器内部 offset；负值提升质量，正值降低质量 |
| 生效时机 | 通过 `setParameters()` 配到编码器，作用于后续输入帧；参数会持续到重新配置 | ROI side data 跟随当前 `AVFrame`，天然是逐帧控制 |
| 能力判断 | 需要查询 `CodecCapabilities.FEATURE_Roi`，不同设备/codec 结果可能不同 | 需要确认所选编码器实现了 ROI side data 处理；例如 libx264 会检查 AQ 是否开启 |
| 与码控关系 | 由硬件编码器结合自身码控解释 offset，具体细节设备相关 | 软编路径更可预期，可从源码追到 libx264 的 `pic->prop.quant_offsets` |
| 工程优势 | 低功耗、低延迟，适合移动端实时硬编 | 跨平台、可控性强，适合离线处理、服务端转码或低分辨率软编 |
| 工程代价 | Android 15+ 才有标准 API；设备碎片化明显 | CPU、功耗和发热成本高；移动端实时高分辨率压力大 |

## 五、测试视频对比

下面的视频由 `articles/roi-encoding-demo/run_real_video_roi_demo.sh` 生成，使用 Xiph/DERF 公开测试序列 `akiyo_cif.y4m`。这是一个真实人像视频，比纯合成图更接近直播/RTC 场景。

脚本把人脸/上半身区域设为 ROI，把左侧背景作为非重点区域，在约 `70 kbit/s` 下分别编码无 ROI 和有 ROI 两版：

全画面对比，左侧是无 ROI，右侧是有 ROI，红框为 ROI 区域：

<video controls width="960" src="roi-encoding-demo/out-real/real_full_side_by_side_with_roi_box.mp4"></video>

本地实测结果如下：

| 区域 | 无 ROI | 有 ROI | 变化 |
|---|---:|---:|---:|
| ROI 裁剪区域 PSNR 平均值 | 34.093291 dB | 36.845103 dB | +2.752 dB |
| 背景裁剪区域 PSNR 平均值 | 39.304363 dB | 20.501368 dB | -18.803 dB |
| 文件大小 | 84359 bytes | 94120 bytes | +9761 bytes |

这组真实视频测试中，ROI 版本对人脸/上半身使用负 `qoffset`，对背景使用正 `qoffset`。PSNR 结果符合预期：ROI 区域质量上升，背景区域质量下降，说明 `addroi` 写入的 `AV_FRAME_DATA_REGIONS_OF_INTEREST` side data 已经被 `libx264` 消费。

## 六、工程落地建议

1. Android 先判断 API 和 `FEATURE_Roi`。不要只判断系统版本。API 35 只是有标准入口，具体 codec 仍可能不支持。
2. ROI offset 从小值开始调。Android 可以从 `-3`、`-6` 开始；FFmpeg `qoffset` 可以从 `-1/10`、`-1/5` 开始。过大的 QP 差会带来边界割裂和码率波动。
3. ROI 需要跟 PTS 对齐。人脸检测、OCR、分割模型通常异步运行。ROI 结果要绑定帧时间戳，否则会出现“人脸已经移动，但 ROI 还打在旧位置”的问题。
4. ROI 消失时要清空配置。Android 的 ROI 参数会持续到重新配置。目标丢失后发全 0 map，不要假设只影响一帧。

## 结论

ROI 编码的核心是区域化码率分配：让编码器把更多 bits 花在真正影响主观体验的区域。Android 15+ 已经提供标准 MediaCodec ROI API，可以直接下发 QP offset map 或 rects。FFmpeg 软编路径也很清晰，通过 `AV_FRAME_DATA_REGIONS_OF_INTEREST` side data 传给 libx264/libx265/libvpx 等支持者。
