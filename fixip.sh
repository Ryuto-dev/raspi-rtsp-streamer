#!/bin/bash

# エラーが発生したら即座にスクリプトを終了する
set -e

# 引数（設定したいIP）が空でないかチェック
if [ -z "$1" ]; then
    echo "【エラー】設定したいIPアドレスを指定してください。"
    echo "使い方: ./fixip.sh 10.40.99.X"
    exit 1
fi

TARGET_IP=$1

# --------------------------------------------------
# 【重要】学校の環境に合わせてここを修正してください
# --------------------------------------------------
# ※先ほどのログをもとに記述していますが、
#   ネットワーク全体のルール（サブネット等）に合わせて調整してください。
GATEWAY="10.40.120.1" 
DNS_SERVERS="8.8.8.8,8.8.4.4"
CONNECTION_NAME="Wired connection 1"
# --------------------------------------------------

echo "=================================================="
echo "  Raspberry Pi 5 IP Static Configuration"
echo "  Target IP: $TARGET_IP"
echo "  Gateway:   $GATEWAY"
echo "=================================================="

echo "[1/3] Modifying NetworkManager connection settings..."
# IPアドレス、ゲートウェイ、DNSの手動設定
# ※学内LANの仕様に合わせてサブネットマスクを /16 や /24 に適宜変更してください
sudo nmcli connection modify "$CONNECTION_NAME" ipv4.addresses "$TARGET_IP/16"
sudo nmcli connection modify "$CONNECTION_NAME" ipv4.gateway "$GATEWAY"
sudo nmcli connection modify "$CONNECTION_NAME" ipv4.dns "$DNS_SERVERS"
sudo nmcli connection modify "$CONNECTION_NAME" ipv4.method manual

echo "[2/3] Applying network changes..."
# ネットワーク設定の即時反映（SSHが一度切れる場合があります）
sudo nmcli connection up "$CONNECTION_NAME"

echo "[3/3] Verification..."
echo "--------------------------------------------------"
ip addr show eth0 | grep "inet "
echo "--------------------------------------------------"
echo "【成功】IPアドレスの固定化が完了しました！"
echo "今後は新しいIP [ $TARGET_IP ] でアクセスしてください。"
echo "=================================================="