#!/bin/bash

# エラーが発生したら即座にスクリプトを終了する
set -e

# スクリプトの保存場所（リポジトリのルート）を絶対パスで取得
REPO_DIR=$(cd "$(dirname "$0")"; pwd)

echo "=================================================="
echo "  Raspberry Pi 5 RTSP Streamer Auto Setup (Robust)"
echo "  Resolution: 1600x1200 / Transport: TCP"
echo "=================================================="

# 1. パッケージの更新と必要なツールのインストール
echo "[1/4] Updating packages and installing FFmpeg / tools..."
sudo apt update
sudo apt install -y ffmpeg v4l-utils wget tar curl jq

# ユーザーをvideoグループに追加（カメラアクセスのため）
echo "Adding $USER to video group..."
sudo usermod -aG video $USER

# 2. MediaMTXのディレクトリ作成と最新版ダウンロード
echo "[2/4] Downloading and extracting MediaMTX..."
TARGET_DIR="$HOME/mediamtx"
mkdir -p "$TARGET_DIR"

# 実行中のプロセスがあれば停止
sudo pkill -f mediamtx > /dev/null 2>&1 || true
sudo pkill -f ffmpeg > /dev/null 2>&1 || true

# GitHubから最新のarm64版アーキテクチャ（ラズパイ5用）を取得
echo "Fetching latest MediaMTX release..."
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | jq -r '.assets[] | select(.name | test("linux_arm64\\.tar\\.gz$")) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "【エラー】MediaMTXのダウンロードURLの取得に失敗しました。"
    exit 1
fi

wget -q --show-progress -O /tmp/mediamtx_linux_arm64.tar.gz "$DOWNLOAD_URL"
tar -xf /tmp/mediamtx_linux_arm64.tar.gz -C "$TARGET_DIR"
rm -f /tmp/mediamtx_linux_arm64.tar.gz

# リポジトリ内の設定ファイルを配置
if [ -f "$REPO_DIR/mediamtx.yml" ]; then
    echo "Copying mediamtx.yml to $TARGET_DIR"
    cp "$REPO_DIR/mediamtx.yml" "$TARGET_DIR/mediamtx.yml"
else
    echo "【警告】リポジトリ内に mediamtx.yml が見つかりません。"
fi

# 実行権限の付与
chmod +x "$TARGET_DIR/mediamtx"

# 3. systemd サービスファイルの生成
echo "[3/4] Creating systemd service files..."

# MediaMTX サービス
sudo bash -c "cat << EOF > /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$TARGET_DIR
ExecStart=$TARGET_DIR/mediamtx
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

# FFmpeg ストリーマーサービス
sudo bash -c "cat << EOF > /etc/systemd/system/ffmpeg-rtsp.service
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

# サービスの再起動
sudo systemctl restart mediamtx.service
sudo systemctl restart ffmpeg-rtsp.service

echo "=================================================="
echo "  セットアップが完了しました！"
echo "  以下のコマンドで稼働状態を確認できます："
echo "  sudo systemctl status mediamtx ffmpeg-rtsp"
echo ""
echo "  カメラデバイスの確認:"
ls -l /dev/video0 || echo "【警告】/dev/video0 が見つかりません。カメラを接続してください。"
echo "=================================================="
