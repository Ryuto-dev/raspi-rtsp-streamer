#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi 5 RTSP Streamer Auto Setup
#  - MediaMTX (auto download or bundled binary) + FFmpeg + systemd
#  - Resolution: 1600x1200 / 15fps / RTSP TCP
# =============================================================================

set -euo pipefail

# ---- 設定 -------------------------------------------------------------------
# MediaMTX のフォールバック用 固定バージョン（GitHub API が使えない時に使用）
MEDIAMTX_FALLBACK_VERSION="v1.18.2"
# MediaMTX をインストールするディレクトリ
TARGET_DIR="$HOME/mediamtx"
# RTSP のパス（rtsp://<host>:8554/<RTSP_PATH>）
RTSP_PATH="live"
# カメラデバイス
VIDEO_DEVICE="/dev/video0"
# 解像度・FPS
VIDEO_SIZE="1600x1200"
FRAMERATE="15"

# スクリプトの保存場所（リポジトリのルート）を絶対パスで取得
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# リポジトリ内に同梱したバイナリを置く場所（任意）
VENDOR_DIR="$REPO_DIR/vendor"

echo "=================================================="
echo "  Raspberry Pi 5 RTSP Streamer Auto Setup"
echo "  Resolution: ${VIDEO_SIZE} @ ${FRAMERATE}fps / Transport: TCP"
echo "=================================================="

# ---- 0. 事前チェック --------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "【エラー】このスクリプトは一般ユーザーで実行してください（内部で sudo を使います）。"
  exit 1
fi

# ---- 1. 必要パッケージのインストール ---------------------------------------
echo "[1/5] Installing required packages..."
sudo apt update
sudo apt install -y ffmpeg v4l-utils wget tar curl jq ca-certificates

# カメラアクセスのためにユーザーを video グループへ（再ログインが必要だが、systemd 側でも補助）
echo "Adding $USER to video group..."
sudo usermod -aG video "$USER" || true

# ---- 2. アーキテクチャ判定 --------------------------------------------------
echo "[2/5] Detecting architecture..."
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  aarch64|arm64)
    MTX_ARCH="linux_arm64"
    ;;
  armv7l|armv6l)
    MTX_ARCH="linux_armv7"
    ;;
  x86_64|amd64)
    MTX_ARCH="linux_amd64"
    ;;
  *)
    echo "【エラー】未対応のアーキテクチャです: $ARCH_RAW"
    exit 1
    ;;
esac
echo "Architecture: $ARCH_RAW -> MediaMTX asset: $MTX_ARCH"

# ---- 3. MediaMTX 配置（同梱優先 → ダウンロード） ----------------------------
echo "[3/5] Preparing MediaMTX..."
mkdir -p "$TARGET_DIR"

# 既存サービスを停止（ファイル差し替え時のロック回避）
sudo systemctl stop ffmpeg-rtsp.service 2>/dev/null || true
sudo systemctl stop mediamtx.service    2>/dev/null || true
sudo pkill -f "$TARGET_DIR/mediamtx" >/dev/null 2>&1 || true

install_from_vendor() {
  # 同梱バイナリ: vendor/mediamtx_<arch> もしくは vendor/mediamtx
  local candidate=""
  if [[ -f "$VENDOR_DIR/mediamtx_${MTX_ARCH}" ]]; then
    candidate="$VENDOR_DIR/mediamtx_${MTX_ARCH}"
  elif [[ -f "$VENDOR_DIR/mediamtx" ]]; then
    candidate="$VENDOR_DIR/mediamtx"
  elif [[ -f "$VENDOR_DIR/mediamtx_${MTX_ARCH}.tar.gz" ]]; then
    echo "Extracting bundled tarball: $VENDOR_DIR/mediamtx_${MTX_ARCH}.tar.gz"
    tar -xzf "$VENDOR_DIR/mediamtx_${MTX_ARCH}.tar.gz" -C "$TARGET_DIR"
    return 0
  else
    return 1
  fi

  echo "Using bundled MediaMTX binary: $candidate"
  cp -f "$candidate" "$TARGET_DIR/mediamtx"
  return 0
}

download_mediamtx() {
  local url="" version=""
  echo "Fetching latest MediaMTX release info from GitHub..."
  # まず GitHub API で最新版を取得（失敗してもフォールバックする）
  if url="$(curl -fsSL --max-time 15 https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
            | jq -r --arg arch "$MTX_ARCH" '.assets[] | select(.name | test($arch + "\\.tar\\.gz$")) | .browser_download_url' 2>/dev/null)" \
     && [[ -n "$url" && "$url" != "null" ]]; then
    echo "Latest URL: $url"
  else
    echo "【警告】GitHub API からの取得に失敗。フォールバックバージョン ${MEDIAMTX_FALLBACK_VERSION} を使用します。"
    version="$MEDIAMTX_FALLBACK_VERSION"
    url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_${MTX_ARCH}.tar.gz"
    echo "Fallback URL: $url"
  fi

  local tmp_tar="/tmp/mediamtx_${MTX_ARCH}.tar.gz"
  rm -f "$tmp_tar"

  # ダウンロード（リトライ付き）
  if ! wget --tries=3 --timeout=30 -q --show-progress -O "$tmp_tar" "$url"; then
    echo "【エラー】MediaMTX のダウンロードに失敗しました: $url"
    return 1
  fi

  # サイズチェック（極端に小さい場合は失敗扱い）
  local size
  size="$(stat -c%s "$tmp_tar" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 1000000 ]]; then
    echo "【エラー】ダウンロードしたファイルが小さすぎます (${size} bytes)。中断します。"
    rm -f "$tmp_tar"
    return 1
  fi

  echo "Extracting MediaMTX into $TARGET_DIR ..."
  tar -xzf "$tmp_tar" -C "$TARGET_DIR"
  rm -f "$tmp_tar"
  return 0
}

# 同梱優先 → 失敗ならダウンロード
if install_from_vendor; then
  echo "Bundled MediaMTX installed."
else
  echo "Bundled MediaMTX not found. Downloading from GitHub..."
  if ! download_mediamtx; then
    echo "【エラー】MediaMTX の取得に失敗しました。ネットワークを確認するか、$VENDOR_DIR/mediamtx_${MTX_ARCH} に手動配置してください。"
    exit 1
  fi
fi

# バイナリ存在確認
if [[ ! -f "$TARGET_DIR/mediamtx" ]]; then
  echo "【エラー】$TARGET_DIR/mediamtx が見つかりません。展開に失敗した可能性があります。"
  ls -la "$TARGET_DIR" || true
  exit 1
fi

chmod +x "$TARGET_DIR/mediamtx"

# 実行可能性チェック（アーキテクチャ不一致の早期検出）
if ! "$TARGET_DIR/mediamtx" --version >/dev/null 2>&1; then
  echo "【エラー】mediamtx が実行できませんでした。アーキテクチャ不一致の可能性があります。"
  file "$TARGET_DIR/mediamtx" || true
  exit 1
fi
MTX_VER="$("$TARGET_DIR/mediamtx" --version 2>&1 | head -n1 || echo unknown)"
echo "MediaMTX version: $MTX_VER"

# 設定ファイル配置（リポジトリ内 mediamtx.yml を優先、なければ抽出されたデフォルトを使用）
if [[ -f "$REPO_DIR/mediamtx.yml" ]]; then
  echo "Copying mediamtx.yml from repository to $TARGET_DIR"
  cp -f "$REPO_DIR/mediamtx.yml" "$TARGET_DIR/mediamtx.yml"
elif [[ ! -f "$TARGET_DIR/mediamtx.yml" ]]; then
  echo "【警告】mediamtx.yml がリポジトリにも展開先にも存在しません。MediaMTX 起動に失敗する可能性があります。"
fi

# ---- 4. systemd サービス作成 ----------------------------------------------
echo "[4/5] Creating systemd service files..."

# MediaMTX サービス
sudo tee /etc/systemd/system/mediamtx.service >/dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$TARGET_DIR
ExecStart=$TARGET_DIR/mediamtx $TARGET_DIR/mediamtx.yml
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# FFmpeg サービス
# - SupplementaryGroups=video : 再ログイン無しでもカメラへアクセス可能
# - ExecStartPre で /dev/video0 と RTSP ポート 8554 の準備を待機
sudo tee /etc/systemd/system/ffmpeg-rtsp.service >/dev/null <<EOF
[Unit]
Description=FFmpeg UVC to RTSP Streamer
After=network-online.target mediamtx.service
Wants=network-online.target
Requires=mediamtx.service

[Service]
Type=simple
User=$USER
SupplementaryGroups=video
# /dev/video0 が現れるまで待機（最大30秒）
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do [ -e $VIDEO_DEVICE ] && exit 0; sleep 1; done; echo "$VIDEO_DEVICE not found"; exit 1'
# MediaMTX の RTSP ポート(8554)が開くまで待機（最大30秒）
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/8554) 2>/dev/null && exec 3<&- && exec 3>&- && exit 0; sleep 1; done; echo "RTSP port 8554 not ready"; exit 1'
ExecStart=/usr/bin/ffmpeg -nostdin -hide_banner -loglevel warning \\
  -f v4l2 -fflags nobuffer -flags low_delay \\
  -input_format mjpeg -video_size $VIDEO_SIZE -framerate $FRAMERATE \\
  -i $VIDEO_DEVICE \\
  -c:v libx264 -preset ultrafast -tune zerolatency -g $FRAMERATE -bf 0 \\
  -rtsp_transport tcp -f rtsp rtsp://127.0.0.1:8554/$RTSP_PATH
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- 5. サービス有効化と起動 -----------------------------------------------
echo "[5/5] Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service ffmpeg-rtsp.service
sudo systemctl restart mediamtx.service
# MediaMTX が起動するまで少し待ってから ffmpeg 開始
sleep 2
sudo systemctl restart ffmpeg-rtsp.service

echo ""
echo "=================================================="
echo "  セットアップが完了しました！"
echo "  状態確認:  sudo systemctl status mediamtx ffmpeg-rtsp"
echo "  ログ:      journalctl -u mediamtx -f"
echo "             journalctl -u ffmpeg-rtsp -f"
echo ""
echo "  視聴URL:   rtsp://<このRaspiのIP>:8554/$RTSP_PATH"
echo "=================================================="

# カメラ確認
if [[ -e "$VIDEO_DEVICE" ]]; then
  echo "Camera device: $VIDEO_DEVICE OK"
  ls -l "$VIDEO_DEVICE" || true
else
  echo "【警告】$VIDEO_DEVICE が見つかりません。USB カメラを接続して、ffmpeg-rtsp を再起動してください："
  echo "  sudo systemctl restart ffmpeg-rtsp"
fi
