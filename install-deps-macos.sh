#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "未检测到 Homebrew。请先安装 Homebrew：https://brew.sh/"
  exit 1
fi

echo "安装 mkvmerge 所属的 MKVToolNix，以及 ffmpeg/ffprobe。"
brew install mkvtoolnix ffmpeg

echo "依赖安装完成。"
echo "mkvmerge: $(command -v mkvmerge || true)"
echo "ffmpeg: $(command -v ffmpeg || true)"
echo "ffprobe: $(command -v ffprobe || true)"
