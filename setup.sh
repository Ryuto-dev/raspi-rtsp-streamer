#!/bin/bash

# エラーが発生したら即座にスクリプトを終了する
set -e

echo "=================================================="
echo "  Raspberry Pi 5 RTSP Streamer Auto Setup"
echo "  Resolution: 1600x1200 / Transport: TCP"
echo "=================================================="

# 1. パッケージの更新とFFmpeg, v4l-utilsのインストール
echo "[1/4] Updating packages and installing FFmpeg / tools..."
sudo apt update
sudo apt install -y ffmpeg v4l-utils wget tar

# 2. MediaMTXのディレクトリ作成と最新版ダウンロード
echo "[2/4] Downloading and extracting MediaMTX..."
TARGET_DIR="$HOME/mediamtx"
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# 二重起動防止のため、古いプロセスがあれば終了
sudo killall mediamtx || true
sudo killall ffmpeg || true

# GitHubから最新のarm64版アーキテクチャ（ラズパイ5用）を自動取得
wget -q --show-progress https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_arm64.tar.gz
tar -xf mediamtx_linux_arm64.tar.gz
rm mediamtx_linux_arm64.tar.gz

# 3. systemd サービスファイルの生成 (MediaMTX)
echo "[3/4] Creating systemd service files..."

sudo bash -c "cat << 'EOF' > /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$HOME/mediamtx/mediamtx
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

# 3. systemd サービスファイルの生成 (FFmpeg)
sudo bash -c "cat << 'EOF' > /etc/systemd/system/ffmpeg-rtsp.service
[Unit]
Description=FFmpeg UVC to RTSP Streamer
After=network.target mediamtx.service
Requires=mediamtx.service

[Service]
Type=simple
User=$USER
ExecStart=/usr/bin/ffmpeg -f v4l2 -fflags nobuffer -flags low_delay -input_format mjpeg -video_size 1600x1200 -framerate 15 -i /dev/video0 -c:v libx264 -preset ultrafast -tune zerolatency -g 15 -bf 0 -rtsp_transport tcp -f rtsp rtsp://localhost:8554/live
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

# 4. サービスの有効化と起動
echo "[4/4] Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service
sudo systemctl enable ffmpeg-rtsp.service

# 一度綺麗に再起動をかける
sudo systemctl restart mediamtx.service
sudo systemctl restart ffmpeg-rtsp.service

echo "=================================================="
echo "  セットアップが完了しました！"
echo "  以下のコマンドで稼働状態を確認できます："
echo "  sudo systemctl status mediamtx ffmpeg-rtsp"
echo "=================================================="