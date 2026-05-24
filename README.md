# Raspberry Pi 5 RTSP Streamer

Raspberry Pi 5 と USB (UVC) カメラを使って、家庭内 LAN や学内 LAN に **RTSP ストリーミングサーバ** を立てるための自動セットアップツールです。

`setup.sh` を 1 回叩くだけで、以下を全て自動で行います。

1. 必要パッケージ (`ffmpeg`, `v4l-utils`, `curl`, `wget`, `jq`, `tar`, `file`, …) のインストール
2. CPU アーキテクチャの自動判定 (`linux_arm64` / `linux_armv7` / `linux_armv6` / `linux_amd64`)
3. **MediaMTX バイナリの確実なダウンロード**
   - リポジトリ内 `vendor/` ディレクトリの同梱物を **最優先**
   - GitHub API で取得した最新リリース
   - スクリプトに埋め込んだ既知バージョン (`v1.18.2`, `v1.13.1`, `v1.9.3`) へフォールバック
   - `curl` → `wget` の順で試行、各バージョンで最大 5 回リトライ
   - **`checksums.sha256` で SHA256 検証** (失敗すれば次の候補へ)
   - 展開後に `mediamtx --version` を実行して **動かなければ別バージョンを試す**
4. カメラの解像度を `v4l2-ctl --list-formats-ext` で問い合わせ、
   希望解像度 (`WANT_VIDEO_SIZE`) がサポートされていなければ
   **MJPEG 解像度の中から面積が最も近いものへ自動フォールバック**
5. systemd ユニット (`mediamtx.service`, `ffmpeg-rtsp.service`) を生成
   - `ffmpeg-rtsp` は `/dev/video0` と `127.0.0.1:8554` が ready になるまで最大 60 秒待機
   - `SupplementaryGroups=video` で再ログイン無しでカメラへアクセス
6. サービスを有効化＆起動し、視聴 URL を表示

## 動作確認済み環境

- Raspberry Pi 5 / Raspberry Pi OS (64-bit, Bookworm 以降)
- 任意の UVC USB カメラ (`/dev/video0`)

`arm64` / `armv7` / `armv6` / `amd64` の任意の systemd ベース Linux でも動くはずです。

---

## クイックスタート

```bash
git clone https://github.com/Ryuto-dev/raspi-rtsp-streamer.git
cd raspi-rtsp-streamer
chmod +x setup.sh
./setup.sh
```

完了すると、ネットワーク内の PC (VLC など) から次の URL でストリームを視聴できます。

```
rtsp://<RaspiのIP>:8554/live
```

---

## サービスの操作

```bash
# 状態確認
sudo systemctl status mediamtx ffmpeg-rtsp

# ログを追跡
journalctl -u mediamtx    -f
journalctl -u ffmpeg-rtsp -f

# 停止 / 開始 / 再起動
sudo systemctl stop    mediamtx ffmpeg-rtsp
sudo systemctl start   mediamtx ffmpeg-rtsp
sudo systemctl restart mediamtx ffmpeg-rtsp

# このセットアップ済みの状態をひと目で確認
./setup.sh --verify

# セットアップを撤去 (systemd ユニットを削除)
./setup.sh --uninstall
```

---

## 設定の変更

`setup.sh` 冒頭の変数、または環境変数で上書きできます。

| 変数 | デフォルト | 説明 |
|------|------------|------|
| `WANT_VIDEO_SIZE` | `1600x1200` | 希望解像度。カメラ非対応なら自動で最も近い MJPEG 解像度に変更 |
| `WANT_FRAMERATE` | `15` | フレームレート |
| `VIDEO_DEVICE` | `/dev/video0` | カメラデバイス |
| `RTSP_PATH` | `live` | ストリームのパス (`rtsp://host:8554/<RTSP_PATH>`) |
| `RTSP_PORT` | `8554` | RTSP ポート |
| `TARGET_DIR` | `$HOME/mediamtx` | MediaMTX のインストール先 |

例:

```bash
WANT_VIDEO_SIZE=1280x720 WANT_FRAMERATE=30 ./setup.sh
```

MediaMTX 自体の挙動を変えたい場合は `mediamtx.yml` を編集して `./setup.sh` を再実行してください。リポジトリ内の `mediamtx.yml` が `$TARGET_DIR/mediamtx.yml` にコピーされます。

---

## オフライン環境向け: MediaMTX バイナリの同梱

完全オフラインの環境でも `setup.sh` を完走させたい場合、`vendor/` ディレクトリに MediaMTX のバイナリ or tar.gz を置いておけます。`setup.sh` は次の順序で検索します。

1. `vendor/mediamtx_<arch>`         (素のバイナリ。`<arch>` は `linux_arm64` 等)
2. `vendor/mediamtx`                (素のバイナリ、アーキ無印)
3. `vendor/mediamtx_<arch>.tar.gz`  (公式 tar.gz)
4. `vendor/mediamtx.tar.gz`         (アーキ無印 tar.gz)
5. GitHub API の最新リリース
6. 既知バージョン (`v1.18.2`, `v1.13.1`, `v1.9.3`) に順次フォールバック

### バイナリの入れ方 (例: Raspberry Pi 5)

```bash
mkdir -p vendor
# 例: arm64 / v1.18.2
curl -LO https://github.com/bluenviron/mediamtx/releases/download/v1.18.2/mediamtx_v1.18.2_linux_arm64.tar.gz
mv mediamtx_v1.18.2_linux_arm64.tar.gz vendor/mediamtx_linux_arm64.tar.gz

git add vendor/
git commit -m "Bundle MediaMTX binary for offline setup"
git push
```

> **メモ:** バイナリは 25 MB 程度あります。リポジトリサイズを気にする場合は Git LFS の利用や、Releases にのみ添付して `vendor/` には置かない運用も可能です。

---

## IP アドレスの固定 (`fixip.sh`)

NetworkManager (`nmcli`) ベースで有線 IP を固定するヘルパーです。

```bash
# 例: 10.40.99.20 を /16 で固定 (デフォルト)
sudo ./fixip.sh 10.40.99.20

# サブネットマスクを変えたい場合
sudo ./fixip.sh 192.168.1.20 24
```

スクリプト冒頭の `GATEWAY` / `DNS_SERVERS` / `CONNECTION_NAME` を環境に合わせて編集するか、環境変数で上書きしてください。

```bash
GATEWAY=192.168.1.1 DNS_SERVERS=1.1.1.1,1.0.0.1 CONNECTION_NAME="Wired connection 1" \
  sudo -E ./fixip.sh 192.168.1.20 24
```

---

## トラブルシューティング

### `mediamtx.service` が `status=203/EXEC` で停止する

バイナリが存在しない / 実行権限が無い / アーキテクチャ不一致 のいずれかです。`setup.sh` を再実行すれば自動的にダウンロードし直し、`--version` で実行可能性を確認します。

```bash
ls -l ~/mediamtx/mediamtx
file   ~/mediamtx/mediamtx       # ELF のアーキテクチャを確認
~/mediamtx/mediamtx --version    # 実行できるか
```

### `ffmpeg-rtsp.service` が `Connection refused` で落ちる

MediaMTX がまだポートを開いていないタイミングで ffmpeg が接続しに行ったケースです。本リポジトリの systemd ユニットには **8554 ポートが listen するまで最大 60 秒待つ** `ExecStartPre` を入れてあるため、通常は発生しません。発生する場合は MediaMTX 側のエラーが先に出ているはずです。

```bash
journalctl -u mediamtx    -n 80 --no-pager
journalctl -u ffmpeg-rtsp -n 80 --no-pager
```

### `The V4L2 driver changed the video from 1600x1200 to 1280x720`

カメラが希望解像度をサポートしていません。`setup.sh` 側で自動フォールバックされますが、強制的に別の解像度に固定したい場合は次のように指定してください。

```bash
WANT_VIDEO_SIZE=1280x720 WANT_FRAMERATE=30 ./setup.sh
```

カメラの対応形式は次で確認できます。

```bash
v4l2-ctl --list-formats-ext -d /dev/video0
```

### videoグループ権限が反映されない

`setup.sh` は `usermod -aG video` を行いますが、systemd 側でも `SupplementaryGroups=video` を指定しているため、再ログイン無しでカメラへアクセスできます。CLI から手動で ffmpeg を叩く場合は、一度ログアウト→ログインしてください。

---

## ファイル構成

```
.
├── setup.sh        # 自動セットアップスクリプト (本体)
├── fixip.sh        # NetworkManager で IP を固定するヘルパー
├── mediamtx.yml    # MediaMTX 最小設定 (RTSP 8554/tcp で publisher/reader を受け付ける)
├── README.md       # このファイル
└── vendor/         # (任意) オフライン用 MediaMTX バイナリ置き場
```

## ライセンス

MIT License (本リポジトリのスクリプト群)
MediaMTX 自体のライセンスは [本家リポジトリ](https://github.com/bluenviron/mediamtx) を参照してください。
