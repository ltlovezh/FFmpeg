#!/usr/bin/env bash
set -euo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-"$SCRIPT_DIR/out"}"

WIDTH=640
HEIGHT=360
FPS=30
DURATION=6
BITRATE_K=160

ROI_X=160
ROI_Y=90
ROI_W=320
ROI_H=180
ROI_QOFFSET="-1/2"
BACKGROUND_QOFFSET="+1/3"

BACKGROUND_X=0
BACKGROUND_Y=0
BACKGROUND_W=160
BACKGROUND_H=360

# zoneplate 是高频测试源，比普通色块更容易肉眼观察编码失真。
SOURCE_FILTER="zoneplate=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}:kx2=64:ky2=64:kt=8,format=yuv420p"
ROI_FILTER="addroi=${ROI_X}:${ROI_Y}:${ROI_W}:${ROI_H}:${ROI_QOFFSET},addroi=0:0:${WIDTH}:${HEIGHT}:${BACKGROUND_QOFFSET}"

BASELINE_MP4="$OUT_DIR/baseline_no_roi.mp4"
ROI_MP4="$OUT_DIR/roi_center_boost.mp4"
ROI_CROP_COMPARE_MP4="$OUT_DIR/roi_crop_side_by_side.mp4"
BACKGROUND_CROP_COMPARE_MP4="$OUT_DIR/background_crop_side_by_side.mp4"
SUMMARY_MD="$OUT_DIR/summary.md"

require_ffmpeg_feature() {
    local description="$1"
    local list_kind="$2"
    local pattern="$3"
    local output

    case "$list_kind" in
        encoders)
            output="$("$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null)"
            ;;
        filters)
            output="$("$FFMPEG_BIN" -hide_banner -filters 2>/dev/null)"
            ;;
        *)
            echo "Unknown FFmpeg list kind: $list_kind" >&2
            exit 1
            ;;
    esac

    if ! printf '%s\n' "$output" | grep -F "$pattern" >/dev/null; then
        echo "Missing FFmpeg feature: $description" >&2
        exit 1
    fi
}

psnr_average() {
    local label="$1"
    local encoded="$2"
    local crop_spec="$3"
    local log_file="$OUT_DIR/${label}.txt"
    local stats_file="$OUT_DIR/${label}.log"

    "$FFMPEG_BIN" -hide_banner \
        -f lavfi -i "$SOURCE_FILTER" \
        -i "$encoded" \
        -lavfi "[0:v]crop=${crop_spec}[ref];[1:v]crop=${crop_spec}[dist];[ref][dist]psnr=stats_file=${stats_file}" \
        -f null - 2> "$log_file"

    grep "PSNR" "$log_file" | tail -1 | sed -E 's/.*average:([^ ]+).*/\1/'
}

file_size_bytes() {
    wc -c < "$1" | tr -d ' '
}

command -v "$FFMPEG_BIN" >/dev/null 2>&1 || {
    echo "ffmpeg not found. Set FFMPEG_BIN=/path/to/ffmpeg if needed." >&2
    exit 1
}

require_ffmpeg_feature "libx264 encoder" encoders "libx264"
require_ffmpeg_feature "addroi filter" filters " addroi "
require_ffmpeg_feature "psnr filter" filters " psnr "
require_ffmpeg_feature "crop filter" filters " crop "
require_ffmpeg_feature "scale filter" filters " scale "
require_ffmpeg_feature "hstack filter" filters " hstack "

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Encoding baseline without ROI..."
"$FFMPEG_BIN" -hide_banner -y \
    -f lavfi -i "$SOURCE_FILTER" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params aq-mode=1 \
    -b:v "${BITRATE_K}k" \
    -maxrate "${BITRATE_K}k" \
    -bufsize "${BITRATE_K}k" \
    -pix_fmt yuv420p \
    "$BASELINE_MP4" \
    > "$OUT_DIR/baseline_encode.txt" 2>&1

echo "Encoding ROI version..."
"$FFMPEG_BIN" -hide_banner -y \
    -f lavfi -i "$SOURCE_FILTER" \
    -vf "$ROI_FILTER" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params aq-mode=1 \
    -b:v "${BITRATE_K}k" \
    -maxrate "${BITRATE_K}k" \
    -bufsize "${BITRATE_K}k" \
    -pix_fmt yuv420p \
    "$ROI_MP4" \
    > "$OUT_DIR/roi_encode.txt" 2>&1

echo "Measuring PSNR in ROI and background crops..."
ROI_CROP="${ROI_W}:${ROI_H}:${ROI_X}:${ROI_Y}"
BACKGROUND_CROP="${BACKGROUND_W}:${BACKGROUND_H}:${BACKGROUND_X}:${BACKGROUND_Y}"

BASELINE_ROI_PSNR="$(psnr_average baseline_roi_psnr "$BASELINE_MP4" "$ROI_CROP")"
ROI_ROI_PSNR="$(psnr_average roi_roi_psnr "$ROI_MP4" "$ROI_CROP")"
BASELINE_BACKGROUND_PSNR="$(psnr_average baseline_background_psnr "$BASELINE_MP4" "$BACKGROUND_CROP")"
ROI_BACKGROUND_PSNR="$(psnr_average roi_background_psnr "$ROI_MP4" "$BACKGROUND_CROP")"

ROI_GAIN="$(awk -v roi="$ROI_ROI_PSNR" -v base="$BASELINE_ROI_PSNR" 'BEGIN { printf "%.3f", roi - base }')"
BACKGROUND_DELTA="$(awk -v roi="$ROI_BACKGROUND_PSNR" -v base="$BASELINE_BACKGROUND_PSNR" 'BEGIN { printf "%.3f", roi - base }')"

BASELINE_SIZE="$(file_size_bytes "$BASELINE_MP4")"
ROI_SIZE="$(file_size_bytes "$ROI_MP4")"

echo "Generating zoomed side-by-side comparison videos..."
"$FFMPEG_BIN" -hide_banner -y \
    -i "$BASELINE_MP4" \
    -i "$ROI_MP4" \
    -filter_complex "[0:v]crop=${ROI_CROP},scale=640:360[left];[1:v]crop=${ROI_CROP},scale=640:360[right];[left][right]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 \
    -preset veryfast \
    -crf 18 \
    -pix_fmt yuv420p \
    "$ROI_CROP_COMPARE_MP4" \
    > "$OUT_DIR/roi_crop_compare_encode.txt" 2>&1

"$FFMPEG_BIN" -hide_banner -y \
    -i "$BASELINE_MP4" \
    -i "$ROI_MP4" \
    -filter_complex "[0:v]crop=${BACKGROUND_CROP},scale=640:360[left];[1:v]crop=${BACKGROUND_CROP},scale=640:360[right];[left][right]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 \
    -preset veryfast \
    -crf 18 \
    -pix_fmt yuv420p \
    "$BACKGROUND_CROP_COMPARE_MP4" \
    > "$OUT_DIR/background_crop_compare_encode.txt" 2>&1

{
    echo "# FFmpeg ROI Encoding Demo Result"
    echo
    echo "This demo encodes the same synthetic source twice at about ${BITRATE_K} kbit/s:"
    echo
    echo "- \`baseline_no_roi.mp4\`: no ROI side data."
    echo "- \`roi_center_boost.mp4\`: center ROI uses \`${ROI_QOFFSET}\`; full-frame fallback background uses \`${BACKGROUND_QOFFSET}\`."
    echo "- \`roi_crop_side_by_side.mp4\`: center ROI crop, left = baseline, right = ROI encoded."
    echo "- \`background_crop_side_by_side.mp4\`: background crop, left = baseline, right = ROI encoded."
    echo
    echo "The center ROI rectangle is \`x=${ROI_X}, y=${ROI_Y}, w=${ROI_W}, h=${ROI_H}\`."
    echo "The background verification crop is the left stripe \`x=${BACKGROUND_X}, y=${BACKGROUND_Y}, w=${BACKGROUND_W}, h=${BACKGROUND_H}\`."
    echo
    echo "| Metric | Baseline | ROI Encoded | Delta |"
    echo "|---|---:|---:|---:|"
    echo "| ROI crop PSNR average | ${BASELINE_ROI_PSNR} dB | ${ROI_ROI_PSNR} dB | ${ROI_GAIN} dB |"
    echo "| Background crop PSNR average | ${BASELINE_BACKGROUND_PSNR} dB | ${ROI_BACKGROUND_PSNR} dB | ${BACKGROUND_DELTA} dB |"
    echo "| File size | ${BASELINE_SIZE} bytes | ${ROI_SIZE} bytes | $(awk -v roi="$ROI_SIZE" -v base="$BASELINE_SIZE" 'BEGIN { printf "%d bytes", roi - base }') |"
    echo
    if awk -v gain="$ROI_GAIN" -v bg="$BACKGROUND_DELTA" 'BEGIN { exit !(gain > 0 && bg < 0) }'; then
        echo "Conclusion: ROI side data took effect. At similar bitrate, quality moved toward the center ROI and away from the background crop."
    else
        echo "Conclusion: the expected ROI/background tradeoff was not observed. Try lowering BITRATE_K or increasing ROI_QOFFSET/BACKGROUND_QOFFSET in the script."
    fi
} > "$SUMMARY_MD"

echo
echo "Done."
echo "Outputs: $OUT_DIR"
echo "Summary: $SUMMARY_MD"
echo
cat "$SUMMARY_MD"
