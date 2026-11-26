#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: $0 /path/to/ui-probe /path/to/preview.mp4" >&2
    exit 2
fi
CAPTURE="$(cd "$1" && pwd)"
DESTINATION="$2"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/restabit-preview.XXXXXX")"
EDGES=(left right bottom top topLeft topRight bottomLeft bottomRight)
SEGMENTS=(water rest rest-countdown "${EDGES[@]}" blink blink-rise blink-sway rest-shore rest-grove rest-dark)
cleanup() {
    for name in "${SEGMENTS[@]}"; do rm -f "$WORK/$name.mp4"; done
    rm -f "$WORK/segments.txt"
    rmdir "$WORK"
}
trap cleanup EXIT

for edge in water "${EDGES[@]}"; do
    read -r width height sx sy sw sh cx cy cw ch arrives < "$CAPTURE/layout-$edge.txt"
    duration="$(awk -v arrives="$arrives" 'BEGIN { printf "%.3f", arrives + 0.8 }')"
    ffmpeg -v error -f lavfi -i "color=c=0xe8e3d7:s=${width}x${height}:r=30" \
        -framerate 30 -i "$CAPTURE/$edge-%03d.png" \
        -loop 1 -framerate 30 -i "$CAPTURE/card-$edge.png" \
        -filter_complex "[1:v]scale=$sw:$sh[fox];[2:v]scale=$cw:$ch,format=rgba,fade=t=in:st=$arrives:d=0.16:alpha=1[card];[0:v][fox]overlay=$sx:$sy[stage];[stage][card]overlay=$cx:$cy,scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=0xe8e3d7" \
        -t "$duration" -an -c:v libx264 -pix_fmt yuv420p -crf 18 "$WORK/$edge.mp4"
done

for motion in blink blink-rise blink-sway; do
    ffmpeg -v error -f lavfi -i "color=c=0xe8e3d7:s=1280x800:r=30" \
        -framerate 30 -i "$CAPTURE/$motion-%03d.png" \
        -filter_complex '[0:v][1:v]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2' \
        -t 3.32 -an -c:v libx264 -pix_fmt yuv420p -crf 18 "$WORK/$motion.mp4"
done

for scene in rest rest-countdown rest-shore rest-grove rest-dark; do
    ffmpeg -v error -loop 1 -framerate 30 -i "$CAPTURE/$scene.png" \
        -vf "scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=0xe8e3d7" \
        -t 1.65 -an -c:v libx264 -pix_fmt yuv420p -crf 18 "$WORK/$scene.mp4"
done

for name in "${SEGMENTS[@]}"; do
    echo "file $name.mp4" >> "$WORK/segments.txt"
done
ffmpeg -v error -y -f concat -safe 1 -i "$WORK/segments.txt" -c copy -movflags +faststart "$DESTINATION"
