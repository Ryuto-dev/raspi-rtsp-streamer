#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi 5 RTSP Streamer Auto Setup (v2 - Full Rewrite)
#
#  特徴:
#   - MediaMTX を「確実に」ダウンロードして配置する多段フォールバック実装
#       1) vendor/ ディレクトリの同梱バイナリ / tar.gz を最優先
#       2) GitHub API で取得した最新バージョン
#       3) スクリプトに埋め込まれた既知バージョン (常時更新可能)
#       4) curl と wget の両方を試す
#   - 取得した tar.gz は (可能なら) SHA256 で検証
#   - バイナリ実行可能性 (--version) で最終確認、不正なら次の候補へ
#   - カメラの解像度を v4l2-ctl で実機問い合わせし、要望解像度が無ければ
#     自動で最も近い MJPEG 解像度にフォールバック
#   - systemd ユニットは「MediaMTX が RTSP:8554 を listen するまで待ってから
#     ffmpeg を起動」する堅牢な順序
#
#  使い方:
#     chmod +x setup.sh
#     ./setup.sh                # 通常セットアップ
#     ./setup.sh --uninstall    # サービス停止＆ユニット削除
#     ./setup.sh --verify       # 状態確認のみ
# =============================================================================

set -euo pipefail

# ---- ユーザー設定 ----------------------------------------------------------
# RTSP のパス (rtsp://<host>:8554/<RTSP_PATH>)
RTSP_PATH="${RTSP_PATH:-live}"
# RTSP ポート
RTSP_PORT="${RTSP_PORT:-8554}"
# カメラデバイス
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
# 希望解像度・FPS (カメラがサポートしない場合は自動で最も近い MJPEG 解像度に変更)
WANT_VIDEO_SIZE="${WANT_VIDEO_SIZE:-1600x1200}"
WANT_FRAMERATE="${WANT_FRAMERATE:-30}"

# MediaMTX のインストール先
TARGET_DIR="${TARGET_DIR:-$HOME/mediamtx}"

# 既知の MediaMTX バージョン候補 (上から順に試す / 新しい順)
# ※ GitHub API で取得した最新版が常に最優先される。これは API 不通時のフォールバック。
KNOWN_VERSIONS=(
  "v1.18.2"
  "v1.13.1"
  "v1.9.3"
)

# スクリプトの場所 (リポジトリのルート)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$REPO_DIR/vendor"

# ---- ヘルパー --------------------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
log()   { echo "${CYN}[setup]${RST} $*"; }
ok()    { echo "${GRN}[ ok ]${RST} $*"; }
warn()  { echo "${YLW}[warn]${RST} $*" >&2; }
err()   { echo "${RED}[err ]${RST} $*" >&2; }
die()   { err "$*"; exit 1; }

banner() {
  echo "=================================================="
  echo "  Raspberry Pi 5 RTSP Streamer Auto Setup (v2)"
  echo "  Target: ${WANT_VIDEO_SIZE} @ ${WANT_FRAMERATE}fps / RTSP (TCP) :${RTSP_PORT}/${RTSP_PATH}"
  echo "=================================================="
}

require_user() {
  if [[ $EUID -eq 0 ]]; then
    die "root で実行しないでください。一般ユーザーで実行してください (内部で sudo を使います)。"
  fi
}

# ---- アーキ判定 ------------------------------------------------------------
detect_arch() {
  local raw; raw="$(uname -m)"
  case "$raw" in
    aarch64|arm64)        echo "linux_arm64"  ;;
    armv7l)               echo "linux_armv7"  ;;
    armv6l)               echo "linux_armv6"  ;;
    x86_64|amd64)         echo "linux_amd64"  ;;
    *) die "未対応のアーキテクチャ: $raw" ;;
  esac
}

# ---- パッケージインストール ------------------------------------------------
install_packages() {
  log "[1/6] Installing required packages..."
  sudo apt-get update -y
  sudo apt-get install -y \
    ffmpeg v4l-utils \
    wget curl tar jq ca-certificates coreutils file
  sudo usermod -aG video "$USER" || true
  ok "packages installed"
}

# ---- 既存サービス停止 ------------------------------------------------------
stop_existing_services() {
  sudo systemctl stop ffmpeg-rtsp.service 2>/dev/null || true
  sudo systemctl stop mediamtx.service    2>/dev/null || true
  sudo pkill -f "${TARGET_DIR}/mediamtx" 2>/dev/null || true
}

# ---- 同梱バイナリの利用 ----------------------------------------------------
try_install_from_vendor() {
  local arch="$1"
  mkdir -p "$TARGET_DIR"

  # 1) アーキ指定の素バイナリ
  if [[ -f "$VENDOR_DIR/mediamtx_${arch}" ]]; then
    log "Using bundled binary: vendor/mediamtx_${arch}"
    cp -f "$VENDOR_DIR/mediamtx_${arch}" "$TARGET_DIR/mediamtx"
    return 0
  fi
  # 2) アーキ無印の素バイナリ
  if [[ -f "$VENDOR_DIR/mediamtx" ]]; then
    log "Using bundled binary: vendor/mediamtx"
    cp -f "$VENDOR_DIR/mediamtx" "$TARGET_DIR/mediamtx"
    return 0
  fi
  # 3) tar.gz
  local tgz
  for tgz in "$VENDOR_DIR/mediamtx_${arch}.tar.gz" "$VENDOR_DIR/mediamtx.tar.gz"; do
    if [[ -f "$tgz" ]]; then
      log "Extracting bundled tarball: $tgz"
      tar -xzf "$tgz" -C "$TARGET_DIR" || { warn "extract failed: $tgz"; continue; }
      return 0
    fi
  done
  return 1
}

# ---- ダウンロードヘルパー --------------------------------------------------
# $1: URL  $2: 出力先パス
# 戻り値: 0=成功, 1=失敗。curl → wget の順で試す。
download_to() {
  local url="$1" out="$2"
  rm -f "$out"

  if command -v curl >/dev/null 2>&1; then
    log "  curl <- $url"
    if curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 600 \
            --progress-bar -o "$out" "$url"; then
      return 0
    fi
    warn "  curl failed for $url"
  fi

  if command -v wget >/dev/null 2>&1; then
    log "  wget <- $url"
    if wget --tries=5 --waitretry=3 --timeout=60 \
            --show-progress -q -O "$out" "$url"; then
      return 0
    fi
    warn "  wget failed for $url"
  fi

  rm -f "$out"
  return 1
}

# ---- 期待バージョンの URL を生成 (アーキ別の正式名) -----------------------
asset_url() {
  local version="$1" arch="$2"
  echo "https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_${arch}.tar.gz"
}
checksums_url() {
  local version="$1"
  echo "https://github.com/bluenviron/mediamtx/releases/download/${version}/checksums.sha256"
}

# ---- SHA256 検証 (checksums ファイルが取得できれば) -----------------------
# $1: tar.gz パス, $2: version, $3: arch, $4: 一時dir
verify_checksum_if_possible() {
  local tgz="$1" version="$2" arch="$3" tmpdir="$4"
  local cs_file="${tmpdir}/checksums.sha256"
  local cs_url; cs_url="$(checksums_url "$version")"

  if ! download_to "$cs_url" "$cs_file"; then
    warn "  checksum file not available, skipping verification"
    return 0   # 取得できない場合は検証スキップ (致命的ではない)
  fi

  local expected actual fname
  fname="mediamtx_${version}_${arch}.tar.gz"
  expected="$(awk -v f="$fname" '$2=="*"f || $2==f {print $1}' "$cs_file" | head -n1)"
  if [[ -z "$expected" ]]; then
    warn "  expected hash not found in checksums.sha256, skipping verification"
    return 0
  fi
  actual="$(sha256sum "$tgz" | awk '{print $1}')"
  if [[ "$expected" == "$actual" ]]; then
    ok "  SHA256 OK ($expected)"
    return 0
  fi
  err "  SHA256 mismatch:"
  err "    expected: $expected"
  err "    actual:   $actual"
  return 1
}

# ---- 1 バージョン分のダウンロード＆展開＆検証を試す ----------------------
# $1: version, $2: arch
try_install_version() {
  local version="$1" arch="$2"
  local tmpdir; tmpdir="$(mktemp -d -t mediamtx-XXXXXX)"
  local tgz="$tmpdir/mediamtx_${version}_${arch}.tar.gz"
  local url; url="$(asset_url "$version" "$arch")"

  log "Trying ${version} for ${arch}..."
  if ! download_to "$url" "$tgz"; then
    err "  download failed: $url"
    rm -rf "$tmpdir"; return 1
  fi

  # サイズチェック
  local size; size="$(stat -c%s "$tgz" 2>/dev/null || echo 0)"
  if (( size < 500000 )); then
    err "  downloaded file is suspiciously small (${size} bytes)"
    rm -rf "$tmpdir"; return 1
  fi

  # 中身が gzip かを確認 (GitHub から HTML が返ったケースを検出)
  if ! file "$tgz" | grep -qiE 'gzip compressed'; then
    err "  downloaded file is not gzip (likely an HTML error page)"
    head -c 200 "$tgz" | tr -d '\0' >&2; echo >&2
    rm -rf "$tmpdir"; return 1
  fi

  if ! verify_checksum_if_possible "$tgz" "$version" "$arch" "$tmpdir"; then
    rm -rf "$tmpdir"; return 1
  fi

  mkdir -p "$TARGET_DIR"
  if ! tar -xzf "$tgz" -C "$TARGET_DIR"; then
    err "  extract failed: $tgz"
    rm -rf "$tmpdir"; return 1
  fi

  if [[ ! -f "$TARGET_DIR/mediamtx" ]]; then
    err "  mediamtx binary not found in archive"
    rm -rf "$tmpdir"; return 1
  fi
  chmod +x "$TARGET_DIR/mediamtx"

  if ! "$TARGET_DIR/mediamtx" --version >/dev/null 2>&1; then
    err "  binary not executable on this system (architecture mismatch?)"
    file "$TARGET_DIR/mediamtx" || true
    rm -rf "$tmpdir"; return 1
  fi

  ok "  installed: $("$TARGET_DIR/mediamtx" --version 2>&1 | head -n1)"
  rm -rf "$tmpdir"
  return 0
}

# ---- GitHub API で最新バージョンを取得 ------------------------------------
fetch_latest_version() {
  local json
  if json="$(curl -fsSL --max-time 15 https://api.github.com/repos/bluenviron/mediamtx/releases/latest 2>/dev/null)"; then
    echo "$json" | jq -r '.tag_name' 2>/dev/null
  else
    echo ""
  fi
}

# ---- MediaMTX 取得 (フル多段フォールバック) -------------------------------
install_mediamtx() {
  local arch="$1"
  log "[3/6] Installing MediaMTX (multi-fallback)..."

  # (A) 同梱
  if try_install_from_vendor "$arch"; then
    chmod +x "$TARGET_DIR/mediamtx"
    if "$TARGET_DIR/mediamtx" --version >/dev/null 2>&1; then
      ok "bundled MediaMTX is usable: $("$TARGET_DIR/mediamtx" --version 2>&1 | head -n1)"
      return 0
    fi
    warn "bundled binary failed to execute, falling back to download"
    rm -f "$TARGET_DIR/mediamtx"
  fi

  # 試すバージョン一覧を組み立て (最新 → 既知の順、重複除去)
  local -a tries=()
  local latest; latest="$(fetch_latest_version || true)"
  if [[ -n "$latest" && "$latest" != "null" ]]; then
    log "GitHub latest release: $latest"
    tries+=("$latest")
  else
    warn "GitHub API unavailable; falling back to bundled known versions"
  fi
  local v
  for v in "${KNOWN_VERSIONS[@]}"; do
    if [[ ! " ${tries[*]:-} " == *" $v "* ]]; then
      tries+=("$v")
    fi
  done

  # (B) 各バージョンを順にトライ
  for v in "${tries[@]}"; do
    if try_install_version "$v" "$arch"; then
      return 0
    fi
    warn "version $v failed, trying next..."
  done

  die "MediaMTX のダウンロード/インストールに全て失敗しました。
ネットワークを確認するか、vendor/mediamtx_${arch}.tar.gz を手動配置して再実行してください。"
}

# ---- mediamtx.yml の配置 ---------------------------------------------------
install_mediamtx_yml() {
  log "[3b/6] Installing mediamtx.yml..."
  if [[ -f "$REPO_DIR/mediamtx.yml" ]]; then
    cp -f "$REPO_DIR/mediamtx.yml" "$TARGET_DIR/mediamtx.yml"
    ok "copied repo's mediamtx.yml -> $TARGET_DIR/mediamtx.yml"
  elif [[ -f "$TARGET_DIR/mediamtx.yml" ]]; then
    ok "using mediamtx.yml extracted from tarball"
  else
    warn "no mediamtx.yml found; MediaMTX may fail to start"
  fi
}

# ---- カメラ解像度の自動解決 -----------------------------------------------
# 希望解像度がサポートされていれば採用、無ければ MJPEG の中から「面積が最も近い」候補へ
resolve_video_size() {
  local want="$WANT_VIDEO_SIZE"
  RESOLVED_VIDEO_SIZE="$want"
  RESOLVED_INPUT_FORMAT="mjpeg"

  if [[ ! -e "$VIDEO_DEVICE" ]]; then
    warn "$VIDEO_DEVICE が現時点で存在しないため、解像度の自動検出をスキップします。"
    warn "起動時に $VIDEO_DEVICE が現れない場合や指定解像度をサポートしない場合は、"
    warn "ffmpeg が失敗する可能性があります。"
    return 0
  fi
  if ! command -v v4l2-ctl >/dev/null 2>&1; then
    warn "v4l2-ctl が見つかりません。解像度自動検出をスキップします。"
    return 0
  fi

  local list
  if ! list="$(v4l2-ctl --list-formats-ext -d "$VIDEO_DEVICE" 2>/dev/null)"; then
    warn "v4l2-ctl で解像度を取得できませんでした。指定値をそのまま使います。"
    return 0
  fi

  # MJPEG セクションを抽出して 'Size: Discrete WxH' を集める
  local mjpeg_block
  mjpeg_block="$(echo "$list" | awk '
    /\[[0-9]+\]:/ { in_blk=0 }
    /MJPG|Motion-JPEG|MJPEG/ { in_blk=1 }
    in_blk { print }
  ')"

  local sizes
  sizes="$(echo "$mjpeg_block" | grep -oE 'Size: Discrete [0-9]+x[0-9]+' | awk '{print $3}' | sort -u || true)"

  if [[ -z "$sizes" ]]; then
    warn "カメラの MJPEG 解像度一覧が取得できません。指定値をそのまま使います。"
    return 0
  fi

  if echo "$sizes" | grep -qx "$want"; then
    ok "camera supports requested MJPEG ${want}"
    return 0
  fi

  # 最も「希望面積に近い」解像度を選ぶ
  local want_w want_h want_area
  want_w="${want%x*}"; want_h="${want#*x}"
  want_area=$(( want_w * want_h ))

  local best="" best_diff=""
  local s w h area diff
  while read -r s; do
    [[ -z "$s" ]] && continue
    w="${s%x*}"; h="${s#*x}"
    area=$(( w * h ))
    diff=$(( area > want_area ? area - want_area : want_area - area ))
    if [[ -z "$best" || "$diff" -lt "$best_diff" ]]; then
      best="$s"; best_diff="$diff"
    fi
  done <<< "$sizes"

  if [[ -n "$best" ]]; then
    warn "カメラは ${want} をサポートしません。代わりに ${best} を使用します。"
    warn "  利用可能な MJPEG 解像度: $(echo "$sizes" | paste -sd' ' -)"
    RESOLVED_VIDEO_SIZE="$best"
  fi
}

# ---- systemd ユニット作成 --------------------------------------------------
install_systemd_units() {
  log "[4/6] Writing systemd unit files..."

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

  # ffmpeg ユニット:
  #  - /dev/video0 を最大 60 秒待つ
  #  - RTSP:8554 が listen するのを最大 60 秒待つ (これで Connection refused を防ぐ)
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
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do [ -e ${VIDEO_DEVICE} ] && exit 0; sleep 1; done; echo "${VIDEO_DEVICE} not found"; exit 1'
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/${RTSP_PORT}) 2>/dev/null && exec 3<&- && exec 3>&- && exit 0; sleep 1; done; echo "RTSP port ${RTSP_PORT} not ready"; exit 1'
ExecStart=/usr/bin/ffmpeg -nostdin -hide_banner -loglevel warning \\
  -f v4l2 -fflags nobuffer -flags low_delay \\
  -input_format ${RESOLVED_INPUT_FORMAT} -video_size ${RESOLVED_VIDEO_SIZE} -framerate ${WANT_FRAMERATE} \\
  -i ${VIDEO_DEVICE} \\
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \\
  -g ${WANT_FRAMERATE} -bf 0 \\
  -rtsp_transport tcp -f rtsp rtsp://127.0.0.1:${RTSP_PORT}/${RTSP_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ok "wrote /etc/systemd/system/{mediamtx,ffmpeg-rtsp}.service"
}

# ---- サービス起動 ---------------------------------------------------------
start_services() {
  log "[5/6] Enabling and starting services..."
  sudo systemctl daemon-reload
  sudo systemctl enable mediamtx.service ffmpeg-rtsp.service
  sudo systemctl restart mediamtx.service
  # MediaMTX が listen し始めるまで少し待つ
  local ok_rtsp=0 _i
  for _i in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/${RTSP_PORT}) 2>/dev/null; then
      exec 3<&- 3>&- || true
      ok_rtsp=1; break
    fi
    sleep 1
  done
  if (( ok_rtsp == 1 )); then
    ok "MediaMTX is listening on ${RTSP_PORT}"
  else
    warn "MediaMTX が ${RTSP_PORT} で listen していません。後ほどログを確認してください: journalctl -u mediamtx -n 80"
  fi
  sudo systemctl restart ffmpeg-rtsp.service
}

# ---- 結果サマリ -----------------------------------------------------------
summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "=================================================="
  echo "  ✅ セットアップが完了しました"
  echo "--------------------------------------------------"
  echo "  視聴URL : rtsp://${ip:-<このRaspiのIP>}:${RTSP_PORT}/${RTSP_PATH}"
  echo "  解像度  : ${RESOLVED_VIDEO_SIZE} @ ${WANT_FRAMERATE}fps  (希望: ${WANT_VIDEO_SIZE})"
  echo "  入力    : ${VIDEO_DEVICE} (${RESOLVED_INPUT_FORMAT})"
  echo "--------------------------------------------------"
  echo "  状態   : sudo systemctl status mediamtx ffmpeg-rtsp"
  echo "  ログ   : journalctl -u mediamtx -f"
  echo "         : journalctl -u ffmpeg-rtsp -f"
  echo "  検証   : ./setup.sh --verify"
  echo "  撤去   : ./setup.sh --uninstall"
  echo "=================================================="
}

# ---- --verify モード ------------------------------------------------------
do_verify() {
  banner
  echo "--- systemd ---"
  sudo systemctl --no-pager status mediamtx ffmpeg-rtsp || true
  echo
  echo "--- listening ports ---"
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk 'NR==1 || /:8554|:1935|:8888|:8889|:8000/' || true
  echo
  echo "--- camera ---"
  if [[ -e "$VIDEO_DEVICE" ]]; then
    ls -l "$VIDEO_DEVICE"
    command -v v4l2-ctl >/dev/null && v4l2-ctl --list-formats-ext -d "$VIDEO_DEVICE" | head -40 || true
  else
    warn "$VIDEO_DEVICE が見つかりません"
  fi
  echo
  echo "--- mediamtx ---"
  if [[ -x "$TARGET_DIR/mediamtx" ]]; then
    "$TARGET_DIR/mediamtx" --version || true
    file "$TARGET_DIR/mediamtx" || true
  else
    warn "$TARGET_DIR/mediamtx が見つかりません"
  fi
}

# ---- --uninstall モード ---------------------------------------------------
do_uninstall() {
  banner
  log "Stopping & disabling services..."
  sudo systemctl stop    ffmpeg-rtsp.service mediamtx.service 2>/dev/null || true
  sudo systemctl disable ffmpeg-rtsp.service mediamtx.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/ffmpeg-rtsp.service /etc/systemd/system/mediamtx.service
  sudo systemctl daemon-reload
  ok "systemd units removed"
  log "MediaMTX バイナリ ($TARGET_DIR) は残しています。完全削除するには手動で 'rm -rf $TARGET_DIR' を実行してください。"
}

# ===========================================================================
# main
# ===========================================================================
main() {
  case "${1:-}" in
    --verify)     do_verify;    exit 0 ;;
    --uninstall)  do_uninstall; exit 0 ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
  esac

  require_user
  banner

  install_packages

  log "[2/6] Detecting architecture..."
  local arch; arch="$(detect_arch)"
  ok "architecture: $(uname -m) -> $arch"

  stop_existing_services
  install_mediamtx "$arch"
  install_mediamtx_yml

  log "[3c/6] Resolving camera video size..."
  resolve_video_size
  ok "video size: ${RESOLVED_VIDEO_SIZE} (input format: ${RESOLVED_INPUT_FORMAT})"

  install_systemd_units
  start_services
  log "[6/6] Done."
  summary
}

main "$@"
