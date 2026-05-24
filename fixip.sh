#!/usr/bin/env bash
# =============================================================================
#  Raspberry Pi 5 - 有線 IP アドレス固定スクリプト (NetworkManager / nmcli)
#
#  使い方:
#     sudo ./fixip.sh <設定したい IP> [プレフィックス長]
#     例)  sudo ./fixip.sh 10.40.99.20         # /16 (デフォルト)
#          sudo ./fixip.sh 192.168.1.20 24     # /24
#
#  ※ ネットワーク環境に合わせて下記の GATEWAY / DNS_SERVERS / CONNECTION_NAME
#    を編集してください。
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "【エラー】このスクリプトは sudo で実行してください。" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "使い方: sudo $0 <IP> [プレフィックス長(=16)]" >&2
  exit 1
fi

TARGET_IP="$1"
PREFIX="${2:-16}"

# ------------------ ネットワーク設定 ------------------
GATEWAY="${GATEWAY:-10.40.120.1}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8,8.8.4.4}"
CONNECTION_NAME="${CONNECTION_NAME:-Wired connection 1}"
# ------------------------------------------------------

echo "=================================================="
echo "  Raspberry Pi 5 IP Static Configuration"
echo "  Connection : $CONNECTION_NAME"
echo "  Target IP  : ${TARGET_IP}/${PREFIX}"
echo "  Gateway    : $GATEWAY"
echo "  DNS        : $DNS_SERVERS"
echo "=================================================="

if ! command -v nmcli >/dev/null 2>&1; then
  echo "【エラー】nmcli が見つかりません。NetworkManager がインストールされていません。" >&2
  exit 1
fi

if ! nmcli -t -f NAME connection show | grep -Fxq "$CONNECTION_NAME"; then
  echo "【エラー】接続 '$CONNECTION_NAME' が見つかりません。" >&2
  echo "  利用可能な接続:" >&2
  nmcli -t -f NAME connection show | sed 's/^/    /' >&2
  exit 1
fi

echo "[1/3] Modifying NetworkManager connection settings..."
nmcli connection modify "$CONNECTION_NAME" ipv4.addresses "${TARGET_IP}/${PREFIX}"
nmcli connection modify "$CONNECTION_NAME" ipv4.gateway   "$GATEWAY"
nmcli connection modify "$CONNECTION_NAME" ipv4.dns       "$DNS_SERVERS"
nmcli connection modify "$CONNECTION_NAME" ipv4.method    manual

echo "[2/3] Applying network changes (SSH may briefly disconnect)..."
nmcli connection down "$CONNECTION_NAME" >/dev/null 2>&1 || true
nmcli connection up   "$CONNECTION_NAME"

echo "[3/3] Verification..."
echo "--------------------------------------------------"
ip -4 addr show | awk '/inet /{print "  ", $0}'
echo "--------------------------------------------------"
echo "✅ IP アドレス固定が完了しました。"
echo "    今後は ${TARGET_IP} でアクセスしてください。"
echo "=================================================="
