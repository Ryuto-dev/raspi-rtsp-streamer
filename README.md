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
   **MJPEG (なければ他フォーマット) の中から面積が最も近いものへ自動フォールバック**
   - `--force-resolution` で、サポート判定を無視して **指定解像度を強制適用** することも可能
5. systemd ユニット (`mediamtx.service`, `ffmpeg-rtsp.service`) を生成
   - **デフォルトで超低遅延モード** (`-fflags nobuffer -flags low_delay`、GOP=framerate、B-frame無効、`preset ultrafast`、`tune zerolatency`)
   - `--standard` で従来の高画質モードに切り替え可能
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
./setup.sh                  # 超低遅延モード (1280x720 @ 15fps) - デフォルト
```

完了すると、ネットワーク内の PC (VLC など) から次の URL でストリームを視聴できます。

```
rtsp://<RaspiのIP>:8554/live
```

---

## モード切替

| モード | フラグ | デフォルト解像度 | デフォルトFPS | ffmpeg 主要オプション | 用途 |
|--------|--------|------------------|---------------|----------------------|------|
| **超低遅延 (デフォルト)** | `--low-latency` / `--ultra-low-latency` (省略可) | `1280x720` | `15` | `-fflags nobuffer -flags low_delay`, `-preset ultrafast`, `-tune zerolatency`, `-g 15`, `-bf 0` | リアルタイム監視・遠隔操作・タイムラグを最小化したい場合 |
| **従来 (高画質)**         | `--standard` / `--normal` / `--high-quality`     | `1600x1200` | `30` | `-preset veryfast`, `-tune zerolatency`, `-g 60`, `-bf 0` | 録画・高解像度配信・遅延より画質を優先する場合 |

生成される `ffmpeg-rtsp.service` の ExecStart 例 (超低遅延モード):

```
ffmpeg -f v4l2 -fflags nobuffer -flags low_delay \
       -input_format mjpeg -video_size 1280x720 -framerate 15 \
       -i /dev/video0 \
       -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
       -g 15 -bf 0 \
       -rtsp_transport tcp -f rtsp rtsp://127.0.0.1:8554/live
```

### モード切替の例

```bash
# デフォルト = 超低遅延モード
./setup.sh

# 従来モード (1600x1200 @ 30fps, 高画質寄り)
./setup.sh --standard

# 超低遅延モードのまま解像度だけ 1600x1200 にしたい
WANT_VIDEO_SIZE=1600x1200 ./setup.sh

# 低遅延モード + フレームレートだけ 30 に
WANT_FRAMERATE=30 ./setup.sh

# 環境変数でモード指定
LATENCY_MODE=standard ./setup.sh
```

---

## カメラが対応しているはずの解像度なのに別解像度に落とされる場合

例えば本当は `1600x1200` に対応しているのに、`v4l2-ctl` の出力解釈やカメラドライバの挙動で
`1280x720` 等にフォールバックされてしまうケースがあります。その場合は
**`--force-resolution`** を付けると、サポート判定を無視して指定解像度を強制適用します。

```bash
# 1600x1200 を強制 (低遅延モードのまま)
WANT_VIDEO_SIZE=1600x1200 ./setup.sh --force-resolution

# 従来モードで強制
./setup.sh --standard --force-resolution

# 環境変数版
FORCE_RESOLUTION=1 WANT_VIDEO_SIZE=1600x1200 ./setup.sh
```

`--force-resolution` を指定しても、`v4l2-ctl --list-formats-ext` の結果はログに残します。
ffmpeg が起動できなかった場合は `journalctl -u ffmpeg-rtsp -n 80` でカメラの実サポート状況を確認してください。

カメラの対応形式は次で確認できます:

```bash
v4l2-ctl --list-formats-ext -d /dev/video0
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

| 変数 | デフォルト (low モード) | デフォルト (standard モード) | 説明 |
|------|------------------------|------------------------------|------|
| `LATENCY_MODE` | `low` | `standard` | `low` = 超低遅延, `standard` = 従来 |
| `FORCE_RESOLUTION` | `0` | `0` | `1` で解像度サポート判定を無視 |
| `WANT_VIDEO_SIZE` | `1280x720` | `1600x1200` | 希望解像度。明示すると上記デフォルトを上書き |
| `WANT_FRAMERATE` | `15` | `30` | フレームレート。明示すると上記デフォルトを上書き |
| `VIDEO_DEVICE` | `/dev/video0` | `/dev/video0` | カメラデバイス |
| `RTSP_PATH` | `live` | `live` | ストリームのパス (`rtsp://host:8554/<RTSP_PATH>`) |
| `RTSP_PORT` | `8554` | `8554` | RTSP ポート |
| `TARGET_DIR` | `$HOME/mediamtx` | `$HOME/mediamtx` | MediaMTX のインストール先 |

例:

```bash
# 超低遅延モード + 解像度だけ変更
WANT_VIDEO_SIZE=1920x1080 ./setup.sh

# 従来モードでフレームレートを上げる
./setup.sh --standard
WANT_FRAMERATE=60 ./setup.sh --standard

# 解像度を強制適用
WANT_VIDEO_SIZE=1600x1200 ./setup.sh --force-resolution
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

### 映像の遅延が大きい

`./setup.sh` をオプション無しで実行すると、超低遅延モード (デフォルト) で構成されます。
それでも遅延が大きいと感じる場合は次を確認してください。

1. **クライアント側のバッファ**: VLC は標準で大きな受信バッファを持ちます。`ツール > 設定 > 入力/コーデック > ネットワークキャッシュ` を 100ms など低い値に。`ffplay -fflags nobuffer -flags low_delay -framedrop -i rtsp://...` が最も低遅延で確認しやすいです。
2. **解像度/FPS の引き下げ**: `WANT_VIDEO_SIZE=640x480 ./setup.sh` などにするとさらに低遅延になります。
3. **TCP→UDP の検討**: 本リポジトリは安定性重視で TCP 固定にしていますが、ロスの少ない LAN なら UDP の方が短遅延です (本スクリプトでは対応していません。手動で `-rtsp_transport udp` に変更可能)。
4. **従来モードに戻っていないか**: `journalctl -u ffmpeg-rtsp -n 20` で実行中の ExecStart を確認。`-fflags nobuffer -flags low_delay` が含まれていれば低遅延モードです。

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

カメラが希望解像度をサポートしていないと `v4l2-ctl` が判定したケースです。
`setup.sh` 側で自動フォールバックされますが、
**実機が本当は対応しているのに誤判定された場合** は次のように強制適用してください。

```bash
# 1600x1200 を強制適用
WANT_VIDEO_SIZE=1600x1200 ./setup.sh --force-resolution
```

別解像度に固定したい場合は通常の環境変数で指定するだけで OK です。

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
