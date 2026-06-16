# FFmpeg ROI 编码 Demo

这个目录提供两套互不依赖的 ROI 编码验证 Demo：

- `run_roi_demo.sh`：使用 FFmpeg 命令行滤镜 `addroi` 验证 ROI 效果。
- `roi_encode_demo.cpp`：使用 FFmpeg C/C++ API，手动给 `AVFrame` 挂载 `AV_FRAME_DATA_REGIONS_OF_INTEREST` side data。

两套 Demo 的目标一致：在接近相同码率下编码两份视频，一份不带 ROI，一份对中心区域提升质量、对背景降低质量，然后分别计算 ROI 区域和背景区域的 PSNR。如果 ROI 生效，应看到 ROI 区域 PSNR 上升，背景区域 PSNR 下降。

## 依赖

需要一个启用了以下能力的 FFmpeg：

- `libx264` 编码器
- `addroi` 滤镜，仅 shell 版需要
- `crop` 和 `psnr` 滤镜，仅 shell 版需要
- FFmpeg 开发头文件和动态库，仅 C++ 版需要，例如 `libavcodec`、`libavutil`

在当前机器上，Homebrew FFmpeg 位于 `/opt/homebrew/bin/ffmpeg`，头文件和库位于 `/opt/homebrew/include`、`/opt/homebrew/lib`。

## Shell 版

运行：

```bash
./articles/roi-encoding-demo/run_roi_demo.sh
```

指定 FFmpeg 路径：

```bash
FFMPEG_BIN=/opt/homebrew/bin/ffmpeg ./articles/roi-encoding-demo/run_roi_demo.sh
```

输出目录：

```text
articles/roi-encoding-demo/out/
```

关键输出：

```text
articles/roi-encoding-demo/out/summary.md
articles/roi-encoding-demo/out/baseline_no_roi.mp4
articles/roi-encoding-demo/out/roi_center_boost.mp4
articles/roi-encoding-demo/out/roi_crop_side_by_side.mp4
articles/roi-encoding-demo/out/background_crop_side_by_side.mp4
```

Shell 版做了这些事：

1. 用高频 `zoneplate` 生成合成测试源，方便肉眼观察块效应和边缘失真。
2. 编码 `baseline_no_roi.mp4`，不加 ROI。
3. 编码 `roi_center_boost.mp4`，中心区域设置负 `qoffset`，全帧背景设置正 `qoffset`。
4. 用 `crop + psnr` 分别测中心 ROI 区域和左侧背景区域的 PSNR。
5. 生成两段放大裁剪对比视频，左侧是无 ROI，右侧是有 ROI：
   - `roi_crop_side_by_side.mp4`：中心 ROI 区域放大对比。
   - `background_crop_side_by_side.mp4`：背景区域放大对比。

## C++ API 版

构建：

```bash
./articles/roi-encoding-demo/build_cpp_demo.sh
```

运行：

```bash
./articles/roi-encoding-demo/roi_encode_demo articles/roi-encoding-demo/out-cpp
```

输出目录：

```text
articles/roi-encoding-demo/out-cpp/
```

关键输出：

```text
articles/roi-encoding-demo/out-cpp/summary_cpp.md
articles/roi-encoding-demo/out-cpp/baseline_no_roi.h264
articles/roi-encoding-demo/out-cpp/roi_center_boost.h264
```

C++ 版做了这些事：

1. 在内存里生成 YUV420P 测试帧。
2. 用 `libx264` 编码 baseline H.264 裸流。
3. 给每个 `AVFrame` 添加 `AV_FRAME_DATA_REGIONS_OF_INTEREST` side data，再编码 ROI H.264 裸流。
4. 解码两份 H.264 裸流。
5. 对中心 ROI 区域和左侧背景区域分别计算 PSNR。

核心代码位置：

- `attach_roi_side_data()`：创建并填写 `AVRegionOfInterest`。
- `create_x264_encoder()`：创建 `libx264` 编码器并开启 `aq-mode`。
- `decode_and_measure()`：解码并计算 ROI/背景区域的 PSNR。

## 结果怎么看

查看 shell 版结果：

```bash
cat articles/roi-encoding-demo/out/summary.md
```

查看 C++ 版结果：

```bash
cat articles/roi-encoding-demo/out-cpp/summary_cpp.md
```

如果结果类似下面这样，就说明 ROI 生效了：

```text
ROI crop PSNR: baseline < roi
Background crop PSNR: baseline > roi
```

这表示在相近码率下，编码器把更多质量资源分配给了中心 ROI 区域，同时牺牲了部分背景质量。

## 清理输出

生成的输出目录和 C++ 可执行文件已被 `.gitignore` 忽略。需要清理时运行：

```bash
rm -rf articles/roi-encoding-demo/out \
       articles/roi-encoding-demo/out-cpp \
       articles/roi-encoding-demo/out-real \
       articles/roi-encoding-demo/roi_encode_demo
```

## 真实视频版

如果希望不用合成测试源，可以运行真实视频版。它会下载公开测试视频 `akiyo_cif.y4m`，对人脸/上半身区域做 ROI，对左侧背景区域做对比验证。

运行：

```bash
./articles/roi-encoding-demo/run_real_video_roi_demo.sh
```

也可以指定本地真实视频，例如使用自己授权或导出的视频文件：

```bash
SOURCE_VIDEO=/path/to/input.mp4 \
DURATION_SECONDS=8 \
ROI_X=104 ROI_Y=36 ROI_W=148 ROI_H=180 \
./articles/roi-encoding-demo/run_real_video_roi_demo.sh
```

脚本会先把本地视频归一化为 `352x288`、`30 fps`、`yuv420p`，再跑同一套 ROI 编码和 PSNR 对比。默认 ROI 坐标适合 `akiyo_cif.y4m`，换视频时需要按主体位置重新设置 `ROI_X`、`ROI_Y`、`ROI_W`、`ROI_H`。

输出目录：

```text
articles/roi-encoding-demo/out-real/
```

关键输出：

```text
articles/roi-encoding-demo/out-real/summary_real.md
articles/roi-encoding-demo/out-real/real_baseline_no_roi.mp4
articles/roi-encoding-demo/out-real/real_roi_face_boost.mp4
articles/roi-encoding-demo/out-real/real_roi_crop_side_by_side.mp4
articles/roi-encoding-demo/out-real/real_background_crop_side_by_side.mp4
articles/roi-encoding-demo/out-real/real_full_side_by_side_with_roi_box.mp4
```
