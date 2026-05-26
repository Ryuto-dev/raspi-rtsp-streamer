#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi 5 RTSP Streamer Auto Setup (v3 - Low-Latency Default)
#
#  主な変更点 (v3):
#   - **デフォルトを「超低遅延モード」に変更** (1280x720 @ 15fps / -g 15)
#       参考コマンド:
#         ffmpeg -f v4l2 -fflags nobuffer -flags low_delay \
#                -input_format mjpeg -video_size 1280x720 -framerate 15 \
#                -i /dev/video0 \
#                -c:v libx264 -preset ultrafast -tune zerolatency \
#                -g 15 -bf 0 -rtsp_transport tcp -f rtsp rtsp://localhost:8554/live
#   - `--standard` (または `LATENCY_MODE=standard`) で従来の高解像度モード
#     (1600x1200 @ 30fps) に切り替え可能
#   - `--force-resolution` (または `FORCE_RESOLUTION=1`) で
#     v4l2 サポート判定を無視して指定解像度を強制
#       ※ ただし v4l2-ctl による「カメラが本当にその解像度に対応しているか」の
#         確認は行い、未対応なら警告ログを出す。完全に確認不能な場合のみエラー終了。
#   - 解像度サポート確認を MJPEG だけでなく全フォーマットに拡張
#
#  使い方:
#     chmod +x setup.sh
#     ./setup.sh                          # 超低遅延モード (デフォルト)
#     ./setup.sh --standard               # 従来モード (1600x1200 @ 30fps)
#     ./setup.sh --force-resolution       # カメラ非対応と判定されても指定解像度を強制
#     ./setup.sh --uninstall              # サービス停止＆ユニット削除
#     ./setup.sh --verify                 # 状態確認のみ
#
#  環境変数による上書き:
#     LATENCY_MODE=low|standard           # モード切替 (デフォルト: low)
#     FORCE_RESOLUTION=1                  # 解像度サポート判定を無視
#     WANT_VIDEO_SIZE=1280x720            # 明示指定するとモードのデフォルトを上書き
#     WANT_FRAMERATE=15                   # 明示指定するとモードのデフォルトを上書き
#     VIDEO_DEVICE=/dev/video0
#     RTSP_PATH=live
#     RTSP_PORT=8554
#     TARGET_DIR=$HOME/mediamtx
# =============================================================================

set -euo pipefail

# ---- モード切替 ------------------------------------------------------------
# デフォルトは超低遅延モード (low)。`--standard` または LATENCY_MODE=standard で従来モード。
LATENCY_MODE="${LATENCY_MODE:-low}"
# 解像度サポート判定を無視して指定解像度を強制するか
FORCE_RESOLUTION="${FORCE_RESOLUTION:-0}"

# 環境変数で WANT_VIDEO_SIZE / WANT_FRAMERATE が事前に明示指定されたかを覚えておく
# (モードによるデフォルト上書き判定で使う)
_USER_SET_VIDEO_SIZE=0
_USER_SET_FRAMERATE=0
[[ -n "${WANT_VIDEO_SIZE:-}" ]] && _USER_SET_VIDEO_SIZE=1
[[ -n "${WANT_FRAMERATE:-}"  ]] && _USER_SET_FRAMERATE=1

# ---- コマンドライン引数 (モード切替) ---------------------------------------
# main() でも `--verify` / `--uninstall` を扱うが、それより前にモード系フラグだけ
# 抜き出しておく必要があるのでここで先に処理する。
_REMAINING_ARGS=()
while (($#)); do
  case "$1" in
    --low-latency|--ultra-low-latency)
      LATENCY_MODE="low"; shift ;;
    --standard|--normal|--high-quality)
      LATENCY_MODE="standard"; shift ;;
    --force-resolution|--force)
      FORCE_RESOLUTION=1; shift ;;
    --mode=*)
      LATENCY_MODE="${1#*=}"; shift ;;
    *)
      _REMAINING_ARGS+=("$1"); shift ;;
  esac
done
# verify/uninstall などはここで再セット (空配列でも安全に扱う)
if ((${#_REMAINING_ARGS[@]})); then
  set -- "${_REMAINING_ARGS[@]}"
else
  set --
fi

# ---- モード別デフォルト ----------------------------------------------------
case "$LATENCY_MODE" in
  low)
    # 超低遅延モード (参考コマンドに合わせる)
    : "${WANT_VIDEO_SIZE:=1280x720}"
    : "${WANT_FRAMERATE:=15}"
    ;;
  standard)
    # 従来モード (高解像度・高フレームレート)
    : "${WANT_VIDEO_SIZE:=1600x1200}"
    : "${WANT_FRAMERATE:=30}"
    ;;
  *)
    echo "[err ] 未知の LATENCY_MODE: $LATENCY_MODE (low / standard のいずれかを指定してください)" >&2
    exit 1
    ;;
esac

# ---- ユーザー設定 ----------------------------------------------------------
# RTSP のパス (rtsp://<host>:8554/<RTSP_PATH>)
RTSP_PATH="${RTSP_PATH:-live}"
# RTSP ポート
RTSP_PORT="${RTSP_PORT:-8554}"
# カメラデバイス
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"

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
  local mode_label
  case "$LATENCY_MODE" in
    low)      mode_label="ULTRA-LOW-LATENCY (default)";;
    standard) mode_label="STANDARD (high quality)";;
    *)        mode_label="$LATENCY_MODE";;
  esac
  echo "=================================================="
  echo "  Raspberry Pi 5 RTSP Streamer Auto Setup (v3)"
  echo "  Mode   : ${mode_label}"
  echo "  Target : ${WANT_VIDEO_SIZE} @ ${WANT_FRAMERATE}fps / RTSP (TCP) :${RTSP_PORT}/${RTSP_PATH}"
  if [[ "$FORCE_RESOLUTION" == "1" ]]; then
    echo "  Force  : 解像度サポート判定を無視して強制適用"
  fi
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

# ---- カメラのサポート解像度を全フォーマットから取得 ----------------------
# 出力: "MJPG:1280x720" 形式の改行区切りリスト (大文字小文字を正規化)
# 取得失敗時は空文字列を返し、戻り値は常に 0。
list_camera_modes() {
  if [[ ! -e "$VIDEO_DEVICE" ]] || ! command -v v4l2-ctl >/dev/null 2>&1; then
    return 0
  fi
  local raw
  if ! raw="$(v4l2-ctl --list-formats-ext -d "$VIDEO_DEVICE" 2>/dev/null)"; then
    return 0
  fi
  # awk で「現在パース中のピクセルフォーマット」と「Size: Discrete WxH」を組み合わせる
  echo "$raw" | awk '
    # 例: "        [0]: '"'"'MJPG'"'"' (Motion-JPEG, compressed)"
    /\[[0-9]+\]:[[:space:]]*'"'"'[^'"'"']+'"'"'/ {
      # シングルクォートで囲まれた fourcc を抽出
      match($0, /'"'"'[^'"'"']+'"'"'/)
      if (RSTART > 0) {
        fmt = substr($0, RSTART+1, RLENGTH-2)
      }
      next
    }
    /Size: Discrete[[:space:]]+[0-9]+x[0-9]+/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+$/) {
          if (fmt != "") {
            print fmt ":" $i
          }
        }
      }
    }
  ' | sort -u
}

# ---- カメラ解像度の自動解決 -----------------------------------------------
# 解決順:
#   1) FORCE_RESOLUTION=1 なら、サポート確認は行うが、未サポートでも指定値を強制
#      (確認は警告のみ。完全に確認不能な場合はそのまま強制)
#   2) 通常モードでは、希望解像度がサポートされていれば採用、無ければ
#      MJPEG (なければ他フォーマット) の中から「面積が最も近い」候補へフォールバック
resolve_video_size() {
  local want="$WANT_VIDEO_SIZE"
  RESOLVED_VIDEO_SIZE="$want"
  RESOLVED_INPUT_FORMAT="mjpeg"

  if [[ ! -e "$VIDEO_DEVICE" ]]; then
    warn "$VIDEO_DEVICE が現時点で存在しないため、解像度の自動検出をスキップします。"
    if [[ "$FORCE_RESOLUTION" == "1" ]]; then
      warn "FORCE_RESOLUTION=1 のため、起動時に ${want} を強制適用します。"
    else
      warn "起動時に $VIDEO_DEVICE が現れない場合や指定解像度をサポートしない場合は、"
      warn "ffmpeg が失敗する可能性があります。"
    fi
    return 0
  fi
  if ! command -v v4l2-ctl >/dev/null 2>&1; then
    warn "v4l2-ctl が見つかりません。解像度自動検出をスキップします。"
    return 0
  fi

  # 全フォーマットからサポートモードを取得
  local modes
  modes="$(list_camera_modes || true)"

  if [[ -z "$modes" ]]; then
    warn "カメラのサポート解像度一覧を取得できませんでした。"
    if [[ "$FORCE_RESOLUTION" == "1" ]]; then
      warn "FORCE_RESOLUTION=1 のため、${want} を強制適用します。"
      return 0
    fi
    warn "指定値 (${want}) をそのまま使用します。動作しない場合は別の解像度をお試しください。"
    return 0
  fi

  # 希望解像度が MJPEG でサポートされているか
  local has_mjpeg_want=0
  local has_any_want=0
  local supported_formats_for_want=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local fmt="${line%%:*}"
    local sz="${line#*:}"
    if [[ "$sz" == "$want" ]]; then
      has_any_want=1
      supported_formats_for_want+="${fmt} "
      # MJPG / MJPEG / Motion-JPEG いずれかを MJPEG として扱う
      case "$fmt" in
        MJPG|MJPEG|Motion-JPEG|*MJPEG*) has_mjpeg_want=1 ;;
      esac
    fi
  done <<< "$modes"

  if (( has_mjpeg_want == 1 )); then
    ok "camera supports requested MJPEG ${want}"
    RESOLVED_VIDEO_SIZE="$want"
    RESOLVED_INPUT_FORMAT="mjpeg"
    return 0
  fi

  if (( has_any_want == 1 )); then
    # MJPEG では未対応だが他フォーマットでは対応している
    warn "${want} は MJPEG では未対応ですが、他のフォーマットでは対応しています: ${supported_formats_for_want}"
    if [[ "$FORCE_RESOLUTION" == "1" ]]; then
      warn "FORCE_RESOLUTION=1 のため、MJPEG で ${want} を強制適用します (ffmpeg が失敗する可能性あり)。"
      RESOLVED_VIDEO_SIZE="$want"
      RESOLVED_INPUT_FORMAT="mjpeg"
      return 0
    fi
    # MJPEG にこだわらず、最初に見つかった対応フォーマットを使う
    local first_fmt="${supported_formats_for_want%% *}"
    # ffmpeg の -input_format 名にマップ (主要なものだけ)
    local ff_fmt="mjpeg"
    case "$first_fmt" in
      YUYV|YUYV422) ff_fmt="yuyv422" ;;
      UYVY)         ff_fmt="uyvy422" ;;
      NV12)         ff_fmt="nv12"    ;;
      NV21)         ff_fmt="nv21"    ;;
      H264|h264)    ff_fmt="h264"    ;;
      MJPG|MJPEG|Motion-JPEG|*MJPEG*) ff_fmt="mjpeg" ;;
      *) ff_fmt="$(echo "$first_fmt" | tr '[:upper:]' '[:lower:]')" ;;
    esac
    warn "${want} を ${first_fmt} (-input_format ${ff_fmt}) で使用します。"
    RESOLVED_VIDEO_SIZE="$want"
    RESOLVED_INPUT_FORMAT="$ff_fmt"
    return 0
  fi

  # ここに来たということは、どのフォーマットでも want は未サポート
  if [[ "$FORCE_RESOLUTION" == "1" ]]; then
    warn "カメラは ${want} を (どのフォーマットでも) サポートしていません。"
    warn "FORCE_RESOLUTION=1 が指定されているため、MJPEG で ${want} を強制適用します。"
    warn "ffmpeg が失敗する可能性が高いです。失敗する場合は --standard または別解像度をご検討ください。"
    warn "  カメラがサポートしている解像度:"
    echo "$modes" | sed 's/^/    /' >&2
    RESOLVED_VIDEO_SIZE="$want"
    RESOLVED_INPUT_FORMAT="mjpeg"
    return 0
  fi

  # MJPEG モードの中で面積が最も近い解像度にフォールバック
  local mjpeg_sizes
  mjpeg_sizes="$(echo "$modes" | awk -F: '
    {
      fmt=$1; sz=$2
      if (fmt=="MJPG" || fmt=="MJPEG" || fmt=="Motion-JPEG" || fmt ~ /MJPEG/) {
        print sz
      }
    }' | sort -u)"

  local pool="$mjpeg_sizes"
  local pool_label="MJPEG"
  if [[ -z "$pool" ]]; then
    # MJPEG が一切無いカメラの場合は全フォーマットから選ぶ
    pool="$(echo "$modes" | awk -F: '{print $2}' | sort -u)"
    pool_label="非MJPEG (yuyv422 等)"
    RESOLVED_INPUT_FORMAT="yuyv422"
  fi

  if [[ -z "$pool" ]]; then
    warn "解像度プールが空です。指定値 (${want}) をそのまま使用します。"
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
  done <<< "$pool"

  if [[ -n "$best" ]]; then
    warn "カメラは ${want} をサポートしません。代わりに ${best} を使用します (${pool_label})。"
    warn "  --force-resolution を指定すれば ${want} を強制適用できます (動作保証なし)。"
    warn "  利用可能な解像度:"
    echo "$modes" | sed 's/^/    /' >&2
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

  # ffmpeg のオプションをモードに応じて構築
  # 参考コマンド (low モード):
  #   ffmpeg -f v4l2 -fflags nobuffer -flags low_delay \
  #          -input_format mjpeg -video_size 1280x720 -framerate 15 -i /dev/video0 \
  #          -c:v libx264 -preset ultrafast -tune zerolatency \
  #          -g 15 -bf 0 -rtsp_transport tcp -f rtsp rtsp://localhost:8554/live
  local ffmpeg_input_opts
  local ffmpeg_output_opts
  local gop="$WANT_FRAMERATE"

  if [[ "$LATENCY_MODE" == "low" ]]; then
    # 超低遅延: バッファリング極小化, GOP=framerate, B-frame無効
    ffmpeg_input_opts="-f v4l2 -fflags nobuffer -flags low_delay -input_format ${RESOLVED_INPUT_FORMAT} -video_size ${RESOLVED_VIDEO_SIZE} -framerate ${WANT_FRAMERATE}"
    ffmpeg_output_opts="-c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g ${gop} -bf 0"
  else
    # 従来モード (高画質寄り)
    ffmpeg_input_opts="-f v4l2 -input_format ${RESOLVED_INPUT_FORMAT} -video_size ${RESOLVED_VIDEO_SIZE} -framerate ${WANT_FRAMERATE}"
    ffmpeg_output_opts="-c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p -g $(( gop * 2 )) -bf 0"
  fi

  # ffmpeg ユニット:
  #  - /dev/video0 を最大 60 秒待つ
  #  - RTSP:8554 が listen するのを最大 60 秒待つ (これで Connection refused を防ぐ)
  sudo tee /etc/systemd/system/ffmpeg-rtsp.service >/dev/null <<EOF
[Unit]
Description=FFmpeg UVC to RTSP Streamer (mode=${LATENCY_MODE})
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
  ${ffmpeg_input_opts} \\
  -i ${VIDEO_DEVICE} \\
  ${ffmpeg_output_opts} \\
  -rtsp_transport tcp -f rtsp rtsp://127.0.0.1:${RTSP_PORT}/${RTSP_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ok "wrote /etc/systemd/system/{mediamtx,ffmpeg-rtsp}.service (mode=${LATENCY_MODE})"
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
  local mode_label
  case "$LATENCY_MODE" in
    low)      mode_label="ULTRA-LOW-LATENCY";;
    standard) mode_label="STANDARD";;
    *)        mode_label="$LATENCY_MODE";;
  esac
  echo
  echo "=================================================="
  echo "  ✅ セットアップが完了しました"
  echo "--------------------------------------------------"
  echo "  視聴URL : rtsp://${ip:-<このRaspiのIP>}:${RTSP_PORT}/${RTSP_PATH}"
  echo "  モード  : ${mode_label}"
  echo "  解像度  : ${RESOLVED_VIDEO_SIZE} @ ${WANT_FRAMERATE}fps  (希望: ${WANT_VIDEO_SIZE})"
  echo "  入力    : ${VIDEO_DEVICE} (${RESOLVED_INPUT_FORMAT})"
  if [[ "$FORCE_RESOLUTION" == "1" ]]; then
    echo "  Force   : 解像度サポート判定を無視して強制適用中"
  fi
  echo "--------------------------------------------------"
  echo "  状態   : sudo systemctl status mediamtx ffmpeg-rtsp"
  echo "  ログ   : journalctl -u mediamtx -f"
  echo "         : journalctl -u ffmpeg-rtsp -f"
  echo "  検証   : ./setup.sh --verify"
  echo "  撤去   : ./setup.sh --uninstall"
  echo "--------------------------------------------------"
  echo "  従来モード(高画質)で再構築する場合:"
  echo "    ./setup.sh --standard"
  echo "  低遅延モードで解像度を強制する場合:"
  echo "    ./setup.sh --force-resolution WANT_VIDEO_SIZE=1600x1200"
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
      sed -n '2,39p' "$0"; exit 0 ;;
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
