#!/usr/bin/env bash
set -euo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
CURL_BIN="${CURL_BIN:-curl}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-"$SCRIPT_DIR/out-real"}"

SOURCE_URL="${SOURCE_URL:-https://media.xiph.org/video/derf/y4m/akiyo_cif.y4m}"
SOURCE_VIDEO="${SOURCE_VIDEO:-}"

WIDTH="${WIDTH:-352}"
HEIGHT="${HEIGHT:-288}"
BITRATE_K="${BITRATE_K:-70}"
DURATION_SECONDS="${DURATION_SECONDS:-}"

# Akiyo 是典型人像视频。这里把人脸/上半身作为 ROI。
ROI_X="${ROI_X:-104}"
ROI_Y="${ROI_Y:-36}"
ROI_W="${ROI_W:-148}"
ROI_H="${ROI_H:-180}"
ROI_QOFFSET="${ROI_QOFFSET:--1/2}"

# 左侧背景区域用于观察被牺牲的非重点区域质量。
BACKGROUND_X="${BACKGROUND_X:-0}"
BACKGROUND_Y="${BACKGROUND_Y:-0}"
BACKGROUND_W="${BACKGROUND_W:-88}"
BACKGROUND_H="${BACKGROUND_H:-288}"
BACKGROUND_QOFFSET="${BACKGROUND_QOFFSET:-+1/3}"

ROI_FILTER="addroi=${ROI_X}:${ROI_Y}:${ROI_W}:${ROI_H}:${ROI_QOFFSET},addroi=0:0:${WIDTH}:${HEIGHT}:${BACKGROUND_QOFFSET}"

BASELINE_MP4="$OUT_DIR/real_baseline_no_roi.mp4"
ROI_MP4="$OUT_DIR/real_roi_face_boost.mp4"
ROI_CROP_COMPARE_MP4="$OUT_DIR/real_roi_crop_side_by_side.mp4"
BACKGROUND_CROP_COMPARE_MP4="$OUT_DIR/real_background_crop_side_by_side.mp4"
FULL_COMPARE_MP4="$OUT_DIR/real_full_side_by_side_with_roi_box.mp4"
SUMMARY_MD="$OUT_DIR/summary_real.md"
SOURCE_Y4M="$OUT_DIR/akiyo_cif.y4m"
SOURCE_LABEL="Xiph/DERF public test video \`akiyo_cif.y4m\`"

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
        -i "$SOURCE_Y4M" \
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
if [ -z "$SOURCE_VIDEO" ]; then
    command -v "$CURL_BIN" >/dev/null 2>&1 || {
        echo "curl not found. Set CURL_BIN=/path/to/curl if needed." >&2
        exit 1
    }
fi

require_ffmpeg_feature "libx264 encoder" encoders "libx264"
require_ffmpeg_feature "addroi filter" filters " addroi "
require_ffmpeg_feature "psnr filter" filters " psnr "
require_ffmpeg_feature "crop filter" filters " crop "
require_ffmpeg_feature "scale filter" filters " scale "
require_ffmpeg_feature "hstack filter" filters " hstack "
require_ffmpeg_feature "drawbox filter" filters " drawbox "

mkdir -p "$OUT_DIR"

if [ -n "$SOURCE_VIDEO" ]; then
    if [ ! -f "$SOURCE_VIDEO" ]; then
        echo "SOURCE_VIDEO does not exist: $SOURCE_VIDEO" >&2
        exit 1
    fi
    SOURCE_Y4M="$OUT_DIR/source_${WIDTH}x${HEIGHT}.y4m"
    SOURCE_LABEL="local video \`$SOURCE_VIDEO\`, normalized to ${WIDTH}x${HEIGHT}"
    echo "Normalizing local real-world sample video..."
    duration_args=()
    if [ -n "$DURATION_SECONDS" ]; then
        duration_args=(-t "$DURATION_SECONDS")
    fi
    "$FFMPEG_BIN" -hide_banner -y \
        -i "$SOURCE_VIDEO" \
        "${duration_args[@]}" \
        -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=increase,crop=${WIDTH}:${HEIGHT},setsar=1,fps=30,format=yuv420p" \
        "$SOURCE_Y4M" \
        > "$OUT_DIR/source_normalize.txt" 2>&1
elif [ ! -s "$SOURCE_Y4M" ]; then
    echo "Downloading public real-world sample video..."
    "$CURL_BIN" -L --fail "$SOURCE_URL" -o "$SOURCE_Y4M"
fi

echo "Encoding real-video baseline without ROI..."
"$FFMPEG_BIN" -hide_banner -y \
    -i "$SOURCE_Y4M" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params aq-mode=1 \
    -b:v "${BITRATE_K}k" \
    -maxrate "${BITRATE_K}k" \
    -bufsize "${BITRATE_K}k" \
    -pix_fmt yuv420p \
    "$BASELINE_MP4" \
    > "$OUT_DIR/real_baseline_encode.txt" 2>&1

echo "Encoding real-video ROI version..."
"$FFMPEG_BIN" -hide_banner -y \
    -i "$SOURCE_Y4M" \
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
    > "$OUT_DIR/real_roi_encode.txt" 2>&1

ROI_CROP="${ROI_W}:${ROI_H}:${ROI_X}:${ROI_Y}"
BACKGROUND_CROP="${BACKGROUND_W}:${BACKGROUND_H}:${BACKGROUND_X}:${BACKGROUND_Y}"

echo "Measuring real-video PSNR in ROI and background crops..."
BASELINE_ROI_PSNR="$(psnr_average real_baseline_roi_psnr "$BASELINE_MP4" "$ROI_CROP")"
ROI_ROI_PSNR="$(psnr_average real_roi_roi_psnr "$ROI_MP4" "$ROI_CROP")"
BASELINE_BACKGROUND_PSNR="$(psnr_average real_baseline_background_psnr "$BASELINE_MP4" "$BACKGROUND_CROP")"
ROI_BACKGROUND_PSNR="$(psnr_average real_roi_background_psnr "$ROI_MP4" "$BACKGROUND_CROP")"

ROI_GAIN="$(awk -v roi="$ROI_ROI_PSNR" -v base="$BASELINE_ROI_PSNR" 'BEGIN { printf "%.3f", roi - base }')"
BACKGROUND_DELTA="$(awk -v roi="$ROI_BACKGROUND_PSNR" -v base="$BASELINE_BACKGROUND_PSNR" 'BEGIN { printf "%.3f", roi - base }')"

BASELINE_SIZE="$(file_size_bytes "$BASELINE_MP4")"
ROI_SIZE="$(file_size_bytes "$ROI_MP4")"

echo "Generating real-video side-by-side comparison videos..."
"$FFMPEG_BIN" -hide_banner -y \
    -i "$BASELINE_MP4" \
    -i "$ROI_MP4" \
    -filter_complex "[0:v]crop=${ROI_CROP},scale=444:540[left];[1:v]crop=${ROI_CROP},scale=444:540[right];[left][right]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 \
    -preset veryfast \
    -crf 18 \
    -pix_fmt yuv420p \
    "$ROI_CROP_COMPARE_MP4" \
    > "$OUT_DIR/real_roi_crop_compare_encode.txt" 2>&1

"$FFMPEG_BIN" -hide_banner -y \
    -i "$BASELINE_MP4" \
    -i "$ROI_MP4" \
    -filter_complex "[0:v]crop=${BACKGROUND_CROP},scale=352:576[left];[1:v]crop=${BACKGROUND_CROP},scale=352:576[right];[left][right]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 \
    -preset veryfast \
    -crf 18 \
    -pix_fmt yuv420p \
    "$BACKGROUND_CROP_COMPARE_MP4" \
    > "$OUT_DIR/real_background_crop_compare_encode.txt" 2>&1

"$FFMPEG_BIN" -hide_banner -y \
    -i "$BASELINE_MP4" \
    -i "$ROI_MP4" \
    -filter_complex "[0:v]drawbox=x=${ROI_X}:y=${ROI_Y}:w=${ROI_W}:h=${ROI_H}:color=red@0.9:t=3[left];[1:v]drawbox=x=${ROI_X}:y=${ROI_Y}:w=${ROI_W}:h=${ROI_H}:color=red@0.9:t=3[right];[left][right]hstack=inputs=2[v]" \
    -map "[v]" \
    -c:v libx264 \
    -preset veryfast \
    -crf 18 \
    -pix_fmt yuv420p \
    "$FULL_COMPARE_MP4" \
    > "$OUT_DIR/real_full_compare_encode.txt" 2>&1

{
    echo "# Real Video ROI Encoding Demo Result"
    echo
    echo "Source: ${SOURCE_LABEL}."
    echo
    echo "This demo encodes the same real-world talking-head sequence twice at about ${BITRATE_K} kbit/s:"
    echo
    echo "- \`real_baseline_no_roi.mp4\`: no ROI side data."
    echo "- \`real_roi_face_boost.mp4\`: face/upper-body ROI uses \`${ROI_QOFFSET}\`; full-frame fallback background uses \`${BACKGROUND_QOFFSET}\`."
    echo "- \`real_roi_crop_side_by_side.mp4\`: face ROI crop, left = baseline, right = ROI encoded."
    echo "- \`real_background_crop_side_by_side.mp4\`: background crop, left = baseline, right = ROI encoded."
    echo "- \`real_full_side_by_side_with_roi_box.mp4\`: full frame with ROI rectangle, left = baseline, right = ROI encoded."
    echo
    echo "The ROI rectangle is \`x=${ROI_X}, y=${ROI_Y}, w=${ROI_W}, h=${ROI_H}\`."
    echo "The background verification crop is \`x=${BACKGROUND_X}, y=${BACKGROUND_Y}, w=${BACKGROUND_W}, h=${BACKGROUND_H}\`."
    echo
    echo "| Metric | Baseline | ROI Encoded | Delta |"
    echo "|---|---:|---:|---:|"
    echo "| ROI crop PSNR average | ${BASELINE_ROI_PSNR} dB | ${ROI_ROI_PSNR} dB | ${ROI_GAIN} dB |"
    echo "| Background crop PSNR average | ${BASELINE_BACKGROUND_PSNR} dB | ${ROI_BACKGROUND_PSNR} dB | ${BACKGROUND_DELTA} dB |"
    echo "| File size | ${BASELINE_SIZE} bytes | ${ROI_SIZE} bytes | $(awk -v roi="$ROI_SIZE" -v base="$BASELINE_SIZE" 'BEGIN { printf "%d bytes", roi - base }') |"
    echo
    if awk -v gain="$ROI_GAIN" -v bg="$BACKGROUND_DELTA" 'BEGIN { exit !(gain > 0 && bg < 0) }'; then
        echo "Conclusion: ROI side data took effect on the real video. Quality moved toward the face/upper-body ROI and away from the background crop."
    else
        echo "Conclusion: the expected ROI/background tradeoff was not observed. Try lowering BITRATE_K or increasing qoffset strength."
    fi
} > "$SUMMARY_MD"

echo
echo "Done."
echo "Outputs: $OUT_DIR"
echo "Summary: $SUMMARY_MD"
echo
cat "$SUMMARY_MD"
