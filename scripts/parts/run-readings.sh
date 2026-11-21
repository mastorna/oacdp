#!/usr/bin/env bash
# Make the two machine readings for a range of PDF pages:
#   WORK/page-NNN.png          the page's own scan image (pdfimages, unchanged pixels)
#   WORK/raw/pdftext-NNN.tsv   the PDF's built-in text layer (pdftotext -tsv)
#   WORK/raw/tess-NNN.tsv      tesseract 5 at native 300 dpi, psm 4
# Pages already done are skipped, so the script can be stopped and restarted.
# The PDF is only read, never written. WORK must be outside the repository.
#
# usage: scripts/parts/run-readings.sh ORIGINAL.pdf WORK [FIRST] [LAST] [JOBS]
set -euo pipefail

pdf=$1; work=$2; first=${3:-1}; last=${4:-$(pdfinfo "$pdf" | awk '/^Pages:/{print $2}')}; jobs=${5:-2}
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mkdir -p "$work" && cd "$work" && pwd)
case "$work/" in "$repo"/*) echo "WORK must be outside the repository" >&2; exit 1;; esac
mkdir -p "$work/raw" "$work/tmp"
log="$work/timings.log"

one_page() {
  local pdf=$1 work=$2 p=$3 n
  n=$(printf %03d "$p")
  local start=$(date +%s%N)
  if [ ! -s "$work/page-$n.png" ]; then
    local d="$work/tmp/$n"; rm -rf "$d"; mkdir -p "$d"
    pdfimages -png -f "$p" -l "$p" "$pdf" "$d/i"
    # keep the largest image on the page (pages 2-5 also carry small colour samples)
    local big=$(ls -S "$d"/i-*.png 2>/dev/null | head -1)
    if [ -n "$big" ]; then
      mv "$big" "$work/page-$n.png"
    else
      # no scan image on this page (typed page): render it at 300 dpi instead
      pdftoppm -r 300 -mono -png -f "$p" -l "$p" "$pdf" "$d/r"
      mv "$(ls "$d"/r*.png | head -1)" "$work/page-$n.png"; echo "$n rendered (no scan image)" >> "$work/timings.log"
    fi
    rm -rf "$d"
  fi
  [ -s "$work/raw/pdftext-$n.tsv" ] || pdftotext -tsv -f "$p" -l "$p" "$pdf" "$work/raw/pdftext-$n.tsv"
  if [ ! -s "$work/raw/tess-$n.tsv" ]; then
    OMP_THREAD_LIMIT=1 tesseract "$work/page-$n.png" "$work/raw/tess-$n.part" --dpi 300 --psm 4 tsv >/dev/null 2>&1
    mv "$work/raw/tess-$n.part.tsv" "$work/raw/tess-$n.tsv"
    echo "$n $(( ($(date +%s%N) - start) / 1000000 ))ms" >> "$work/timings.log"
  fi
}
export -f one_page

seq "$first" "$last" | xargs -P "$jobs" -I{} bash -c 'one_page "$@"' _ "$pdf" "$work" {}
echo "done pages $first-$last; timings in $log"
