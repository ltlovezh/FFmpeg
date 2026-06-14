#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/rational.h>
}

namespace {

constexpr int kWidth = 640;
constexpr int kHeight = 360;
constexpr int kFps = 30;
constexpr int kFrameCount = 180;
constexpr int kBitrate = 220000;

constexpr int kRoiX = 160;
constexpr int kRoiY = 90;
constexpr int kRoiW = 320;
constexpr int kRoiH = 180;

constexpr int kBgX = 0;
constexpr int kBgY = 0;
constexpr int kBgW = 160;
constexpr int kBgH = 360;

struct RawFrame {
    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;
};

struct PacketData {
    std::vector<uint8_t> data;
};

struct EncodeResult {
    std::vector<PacketData> packets;
    size_t total_bytes = 0;
};

struct PsnrStats {
    double roi_psnr = 0.0;
    double bg_psnr = 0.0;
    int decoded_frames = 0;
};

std::string ff_error(int err)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof(buf));
    return std::string(buf);
}

void fail_if_negative(int ret, const std::string &what)
{
    if (ret < 0) {
        std::cerr << what << ": " << ff_error(ret) << "\n";
        std::exit(1);
    }
}

AVFrame *alloc_yuv420p_frame()
{
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        std::cerr << "无法分配 AVFrame\n";
        std::exit(1);
    }

    frame->format = AV_PIX_FMT_YUV420P;
    frame->width = kWidth;
    frame->height = kHeight;

    fail_if_negative(av_frame_get_buffer(frame, 32), "无法分配 AVFrame 图像缓冲区");
    return frame;
}

// 生成一个简单但有运动和细节的 YUV420P 测试帧。
// 真实项目里，这里会替换成相机、解码器或图像处理管线输出的 AVFrame。
RawFrame fill_synthetic_frame(AVFrame *frame, int frame_index)
{
    fail_if_negative(av_frame_make_writable(frame), "AVFrame 不可写");

    RawFrame raw;
    raw.y.resize(kWidth * kHeight);
    raw.u.resize((kWidth / 2) * (kHeight / 2));
    raw.v.resize((kWidth / 2) * (kHeight / 2));

    for (int y = 0; y < kHeight; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            // 背景有棋盘纹理，中心 ROI 有移动细节，低码率下更容易看出码率分配差异。
            int checker = ((x / 16) ^ (y / 16) ^ (frame_index / 4)) & 1;
            int wave = (x + 2 * y + frame_index * 3) & 255;
            int value = checker ? wave : (255 - wave);

            if (x >= kRoiX && x < kRoiX + kRoiW &&
                y >= kRoiY && y < kRoiY + kRoiH) {
                int local = ((x - kRoiX) * 3 + (y - kRoiY) * 5 + frame_index * 7) & 255;
                value = (value / 3 + local * 2 / 3);
            }

            uint8_t sample = static_cast<uint8_t>(std::clamp(value, 0, 255));
            frame->data[0][y * frame->linesize[0] + x] = sample;
            raw.y[y * kWidth + x] = sample;
        }
    }

    for (int y = 0; y < kHeight / 2; ++y) {
        for (int x = 0; x < kWidth / 2; ++x) {
            uint8_t u = static_cast<uint8_t>((128 + x * 2 + frame_index * 3) & 255);
            uint8_t v = static_cast<uint8_t>((64 + y * 3 + frame_index * 5) & 255);
            frame->data[1][y * frame->linesize[1] + x] = u;
            frame->data[2][y * frame->linesize[2] + x] = v;
            raw.u[y * (kWidth / 2) + x] = u;
            raw.v[y * (kWidth / 2) + x] = v;
        }
    }

    frame->pts = frame_index;
    av_frame_remove_side_data(frame, AV_FRAME_DATA_REGIONS_OF_INTEREST);
    return raw;
}

void attach_roi_side_data(AVFrame *frame)
{
    // 这里放两个 ROI：
    // 1. 第一个是中心区域，qoffset = -1/3，表示降低 QP，提高中心区域质量。
    // 2. 第二个是全帧背景，qoffset = +1/5，表示提高 QP，降低非重点区域质量。
    //
    // FFmpeg 对重叠 ROI 的语义是“第一个命中的区域生效”，所以中心 ROI 必须放在前面，
    // 否则全帧背景 ROI 会覆盖中心区域。
    constexpr int kRoiCount = 2;
    AVFrameSideData *sd = av_frame_new_side_data(
        frame,
        AV_FRAME_DATA_REGIONS_OF_INTEREST,
        sizeof(AVRegionOfInterest) * kRoiCount);
    if (!sd) {
        std::cerr << "无法创建 ROI side data\n";
        std::exit(1);
    }

    auto *roi = reinterpret_cast<AVRegionOfInterest *>(sd->data);

    roi[0].self_size = sizeof(AVRegionOfInterest);
    roi[0].left = kRoiX;
    roi[0].top = kRoiY;
    roi[0].right = kRoiX + kRoiW;
    roi[0].bottom = kRoiY + kRoiH;
    roi[0].qoffset = av_make_q(-1, 3);

    roi[1].self_size = sizeof(AVRegionOfInterest);
    roi[1].left = 0;
    roi[1].top = 0;
    roi[1].right = kWidth;
    roi[1].bottom = kHeight;
    roi[1].qoffset = av_make_q(1, 5);
}

AVCodecContext *create_x264_encoder()
{
    const AVCodec *codec = avcodec_find_encoder_by_name("libx264");
    if (!codec) {
        std::cerr << "找不到 libx264 编码器，请确认 FFmpeg 编译时启用了 libx264\n";
        std::exit(1);
    }

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        std::cerr << "无法分配编码器上下文\n";
        std::exit(1);
    }

    ctx->width = kWidth;
    ctx->height = kHeight;
    ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    ctx->time_base = AVRational{1, kFps};
    ctx->framerate = AVRational{kFps, 1};
    ctx->bit_rate = kBitrate;
    ctx->rc_max_rate = kBitrate;
    ctx->rc_buffer_size = kBitrate;
    ctx->gop_size = 60;
    ctx->max_b_frames = 0;

    av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
    av_opt_set(ctx->priv_data, "tune", "zerolatency", 0);

    // libx264.c 中明确检查 AQ：如果 AQ 关闭，ROI 会被跳过。
    av_opt_set(ctx->priv_data, "aq-mode", "variance", 0);

    fail_if_negative(avcodec_open2(ctx, codec, nullptr), "打开 libx264 编码器失败");
    return ctx;
}

void drain_encoder(AVCodecContext *ctx, AVPacket *pkt, EncodeResult &result, FILE *outfile)
{
    while (true) {
        int ret = avcodec_receive_packet(ctx, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return;
        }
        fail_if_negative(ret, "编码失败");

        PacketData stored;
        stored.data.assign(pkt->data, pkt->data + pkt->size);
        result.total_bytes += stored.data.size();
        result.packets.push_back(std::move(stored));

        if (outfile) {
            fwrite(pkt->data, 1, pkt->size, outfile);
        }

        av_packet_unref(pkt);
    }
}

EncodeResult encode_sequence(const std::vector<RawFrame> &originals,
                             bool enable_roi,
                             const std::string &output_path)
{
    AVCodecContext *ctx = create_x264_encoder();
    AVFrame *frame = alloc_yuv420p_frame();
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        std::cerr << "无法分配 AVPacket\n";
        std::exit(1);
    }

    FILE *outfile = fopen(output_path.c_str(), "wb");
    if (!outfile) {
        std::cerr << "无法打开输出文件: " << output_path << "\n";
        std::exit(1);
    }

    EncodeResult result;
    for (int i = 0; i < kFrameCount; ++i) {
        fail_if_negative(av_frame_make_writable(frame), "AVFrame 不可写");

        for (int y = 0; y < kHeight; ++y) {
            memcpy(frame->data[0] + y * frame->linesize[0],
                   originals[i].y.data() + y * kWidth,
                   kWidth);
        }
        for (int y = 0; y < kHeight / 2; ++y) {
            memcpy(frame->data[1] + y * frame->linesize[1],
                   originals[i].u.data() + y * (kWidth / 2),
                   kWidth / 2);
            memcpy(frame->data[2] + y * frame->linesize[2],
                   originals[i].v.data() + y * (kWidth / 2),
                   kWidth / 2);
        }

        frame->pts = i;
        av_frame_remove_side_data(frame, AV_FRAME_DATA_REGIONS_OF_INTEREST);
        if (enable_roi) {
            attach_roi_side_data(frame);
        }

        fail_if_negative(avcodec_send_frame(ctx, frame), "送帧到编码器失败");
        drain_encoder(ctx, pkt, result, outfile);
    }

    fail_if_negative(avcodec_send_frame(ctx, nullptr), "刷新编码器失败");
    drain_encoder(ctx, pkt, result, outfile);

    fclose(outfile);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    return result;
}

double add_plane_mse(const uint8_t *decoded,
                     int decoded_linesize,
                     const std::vector<uint8_t> &original,
                     int plane_width,
                     int x,
                     int y,
                     int w,
                     int h)
{
    double sse = 0.0;
    for (int row = 0; row < h; ++row) {
        const uint8_t *dec_row = decoded + (y + row) * decoded_linesize + x;
        const uint8_t *org_row = original.data() + (y + row) * plane_width + x;
        for (int col = 0; col < w; ++col) {
            double diff = static_cast<double>(org_row[col]) - static_cast<double>(dec_row[col]);
            sse += diff * diff;
        }
    }
    return sse;
}

double crop_mse_yuv420p(const RawFrame &original,
                        const AVFrame *decoded,
                        int x,
                        int y,
                        int w,
                        int h)
{
    // 这里按 YUV420P 的采样数量计算整体 MSE：Y 全分辨率，U/V 宽高各减半。
    double sse = 0.0;
    sse += add_plane_mse(decoded->data[0], decoded->linesize[0], original.y,
                         kWidth, x, y, w, h);
    sse += add_plane_mse(decoded->data[1], decoded->linesize[1], original.u,
                         kWidth / 2, x / 2, y / 2, w / 2, h / 2);
    sse += add_plane_mse(decoded->data[2], decoded->linesize[2], original.v,
                         kWidth / 2, x / 2, y / 2, w / 2, h / 2);

    double samples = static_cast<double>(w * h + 2 * (w / 2) * (h / 2));
    return sse / samples;
}

double psnr_from_mse(double mse)
{
    if (mse <= 0.0) {
        return 99.0;
    }
    return 10.0 * std::log10((255.0 * 255.0) / mse);
}

AVCodecContext *create_h264_decoder()
{
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) {
        std::cerr << "找不到 H.264 解码器\n";
        std::exit(1);
    }

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        std::cerr << "无法分配解码器上下文\n";
        std::exit(1);
    }

    fail_if_negative(avcodec_open2(ctx, codec, nullptr), "打开 H.264 解码器失败");
    return ctx;
}

void receive_decoded_frames(AVCodecContext *ctx,
                            AVFrame *frame,
                            const std::vector<RawFrame> &originals,
                            PsnrStats &stats)
{
    while (true) {
        int ret = avcodec_receive_frame(ctx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return;
        }
        fail_if_negative(ret, "解码失败");

        if (frame->format != AV_PIX_FMT_YUV420P) {
            std::cerr << "本 Demo 只处理 YUV420P，实际解码格式为 " << frame->format << "\n";
            std::exit(1);
        }
        if (stats.decoded_frames >= static_cast<int>(originals.size())) {
            std::cerr << "解码帧数超过原始帧数\n";
            std::exit(1);
        }

        const RawFrame &original = originals[stats.decoded_frames];
        double roi_mse = crop_mse_yuv420p(original, frame, kRoiX, kRoiY, kRoiW, kRoiH);
        double bg_mse = crop_mse_yuv420p(original, frame, kBgX, kBgY, kBgW, kBgH);

        // 先累计 MSE，最后统一换算成 PSNR。这样比逐帧 PSNR 再平均更稳定。
        stats.roi_psnr += roi_mse;
        stats.bg_psnr += bg_mse;
        stats.decoded_frames++;
        av_frame_unref(frame);
    }
}

PsnrStats decode_and_measure(const std::vector<PacketData> &packets,
                             const std::vector<RawFrame> &originals)
{
    AVCodecContext *ctx = create_h264_decoder();
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    if (!frame || !pkt) {
        std::cerr << "无法分配解码用 AVFrame/AVPacket\n";
        std::exit(1);
    }

    PsnrStats stats;
    for (const PacketData &packet : packets) {
        av_packet_unref(pkt);
        fail_if_negative(av_new_packet(pkt, static_cast<int>(packet.data.size())), "分配解码 AVPacket 失败");
        memcpy(pkt->data, packet.data.data(), packet.data.size());
        fail_if_negative(avcodec_send_packet(ctx, pkt), "送包到解码器失败");
        receive_decoded_frames(ctx, frame, originals, stats);
    }

    fail_if_negative(avcodec_send_packet(ctx, nullptr), "刷新解码器失败");
    receive_decoded_frames(ctx, frame, originals, stats);

    if (stats.decoded_frames == 0) {
        std::cerr << "没有解码出任何帧\n";
        std::exit(1);
    }

    stats.roi_psnr = psnr_from_mse(stats.roi_psnr / stats.decoded_frames);
    stats.bg_psnr = psnr_from_mse(stats.bg_psnr / stats.decoded_frames);

    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    return stats;
}

void write_summary(const std::string &path,
                   const EncodeResult &baseline,
                   const EncodeResult &roi,
                   const PsnrStats &baseline_stats,
                   const PsnrStats &roi_stats)
{
    std::ofstream out(path);
    if (!out) {
        std::cerr << "无法写入 summary: " << path << "\n";
        std::exit(1);
    }

    double roi_gain = roi_stats.roi_psnr - baseline_stats.roi_psnr;
    double bg_delta = roi_stats.bg_psnr - baseline_stats.bg_psnr;

    out << "# FFmpeg ROI C++ Demo Result\n\n";
    out << "This result is produced by `roi_encode_demo.cpp` with libavcodec/libx264.\n\n";
    out << "| Metric | Baseline | ROI Encoded | Delta |\n";
    out << "|---|---:|---:|---:|\n";
    out << std::fixed << std::setprecision(3);
    out << "| ROI crop PSNR average | " << baseline_stats.roi_psnr << " dB | "
        << roi_stats.roi_psnr << " dB | " << roi_gain << " dB |\n";
    out << "| Background crop PSNR average | " << baseline_stats.bg_psnr << " dB | "
        << roi_stats.bg_psnr << " dB | " << bg_delta << " dB |\n";
    out << "| H.264 elementary stream size | " << baseline.total_bytes << " bytes | "
        << roi.total_bytes << " bytes | "
        << static_cast<long long>(roi.total_bytes) - static_cast<long long>(baseline.total_bytes)
        << " bytes |\n\n";

    if (roi_gain > 0.0 && bg_delta < 0.0) {
        out << "Conclusion: ROI side data took effect. Quality moved toward the center ROI "
            << "and away from the background crop at similar bitrate.\n";
    } else {
        out << "Conclusion: the expected ROI/background tradeoff was not observed. "
            << "Try lowering bitrate or increasing qoffset strength.\n";
    }
}

} // namespace

int main(int argc, char **argv)
{
    const std::string out_dir = argc >= 2 ? argv[1] : "articles/roi-encoding-demo/out-cpp";
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec) {
        std::cerr << "无法创建输出目录: " << out_dir << ": " << ec.message() << "\n";
        return 1;
    }

    std::cout << "生成 " << kFrameCount << " 帧 YUV420P 测试画面...\n";
    std::vector<RawFrame> originals;
    originals.reserve(kFrameCount);
    AVFrame *source = alloc_yuv420p_frame();
    for (int i = 0; i < kFrameCount; ++i) {
        originals.push_back(fill_synthetic_frame(source, i));
    }
    av_frame_free(&source);

    std::cout << "编码 baseline（不带 ROI side data）...\n";
    EncodeResult baseline = encode_sequence(
        originals,
        false,
        out_dir + "/baseline_no_roi.h264");

    std::cout << "编码 ROI 版本（中心提质，背景降质）...\n";
    EncodeResult roi = encode_sequence(
        originals,
        true,
        out_dir + "/roi_center_boost.h264");

    std::cout << "解码并计算 ROI/背景区域 PSNR...\n";
    PsnrStats baseline_stats = decode_and_measure(baseline.packets, originals);
    PsnrStats roi_stats = decode_and_measure(roi.packets, originals);

    const std::string summary = out_dir + "/summary_cpp.md";
    write_summary(summary, baseline, roi, baseline_stats, roi_stats);

    std::cout << std::fixed << std::setprecision(3);
    std::cout << "\nROI crop PSNR: baseline=" << baseline_stats.roi_psnr
              << " dB, roi=" << roi_stats.roi_psnr
              << " dB, delta=" << (roi_stats.roi_psnr - baseline_stats.roi_psnr)
              << " dB\n";
    std::cout << "Background crop PSNR: baseline=" << baseline_stats.bg_psnr
              << " dB, roi=" << roi_stats.bg_psnr
              << " dB, delta=" << (roi_stats.bg_psnr - baseline_stats.bg_psnr)
              << " dB\n";
    std::cout << "Summary: " << summary << "\n";
    return 0;
}
