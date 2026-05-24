# Raspberry Pi 5 RTSP Streamer

このプロジェクトは、Raspberry Pi 5 と UVC カメラ（USB カメラ）を使用して、RTSP ストリーミングサーバーを自動的にセットアップするためのスクリプト群です。

## 特徴

- **MediaMTX**: 高性能な RTSP/RTMP/HLS/WebRTC サーバー（自動ダウンロード対応）。
- **FFmpeg**: カメラ映像を H.264 にエンコードし、MediaMTX に配信。
- **systemd 対応**: 再起動後も自動的にストリーミングを開始します。
- **最適化**: Raspberry Pi 5 向けに、1600x1200 / 15fps / TCP 転送で設定されています。
- **堅牢な起動順序**: `ffmpeg-rtsp` は `/dev/video0` と RTSP ポート 8554 が準備できるまで待機します。
- **オフライン対応**: ネットワークが無い環境向けに、MediaMTX バイナリをリポジトリに同梱できます（後述）。

## 前提条件

- Raspberry Pi 5（または arm64 / armv7 / amd64 の Linux マシン）
- Raspberry Pi OS (64-bit) など、systemd ベースのディストリビューション
- USB 接続の UVC 対応カメラ（`/dev/video0` として認識されるもの）

## セットアップ方法

1. リポジトリをクローンします。
   ```bash
   git clone https://github.com/Ryuto-dev/raspi-rtsp-streamer.git
   cd raspi-rtsp-streamer
   ```
2. `setup.sh` に実行権限を与えて実行します。
   ```bash
   chmod +x setup.sh
   ./setup.sh
   ```

スクリプトは以下を自動で行います。

1. 必要なパッケージ（`ffmpeg`, `v4l-utils`, `wget`, `tar`, `curl`, `jq`）のインストール
2. CPU アーキテクチャの自動判定（`arm64` / `armv7` / `amd64`）
3. MediaMTX の取得
   - `vendor/` ディレクトリに同梱バイナリがあれば**それを優先**して使用
   - 無ければ GitHub の最新リリースを自動ダウンロード
   - GitHub API が失敗した場合はフォールバックとして `v1.18.2` を直接ダウンロード
4. ダウンロード後の動作確認（バイナリの実行 / `--version` チェック）
5. systemd ユニットファイル（`mediamtx.service`, `ffmpeg-rtsp.service`）の生成と有効化
6. サービスの起動

## 使い方

セットアップ完了後、ネットワーク内の PC から以下の URL でストリームを視聴できます（VLC など）。

```
rtsp://<Raspberry_PiのIPアドレス>:8554/live
```

### サービスの管理

```bash
# 状態確認
sudo systemctl status mediamtx ffmpeg-rtsp

# ログを追跡
journalctl -u mediamtx -f
journalctl -u ffmpeg-rtsp -f

# 停止 / 開始 / 再起動
sudo systemctl stop    mediamtx ffmpeg-rtsp
sudo systemctl start   mediamtx ffmpeg-rtsp
sudo systemctl restart mediamtx ffmpeg-rtsp
```

## 設定の変更

- **解像度・フレームレート**: `setup.sh` 上部の `VIDEO_SIZE`, `FRAMERATE` を変更してから再実行してください。
- **MediaMTX の詳細設定**: `mediamtx.yml` を編集してから `./setup.sh` を再実行（`mediamtx.yml` が `~/mediamtx/` にコピーされます）。

## MediaMTX バイナリをリポジトリに同梱したい場合（オフライン環境向け）

ネットワークに接続できない環境でも `setup.sh` が動作するように、MediaMTX バイナリをリポジトリ内に同梱できます。

### 手順

1. リポジトリのルートに `vendor/` ディレクトリを作成します。
   ```bash
   mkdir -p vendor
   ```
2. [MediaMTX の Releases ページ](https://github.com/bluenviron/mediamtx/releases) から、ターゲットの Pi のアーキテクチャに合うアーカイブをダウンロードします。Raspberry Pi 5 (64-bit OS) の場合は `mediamtx_vX.Y.Z_linux_arm64.tar.gz` です。
3. 以下のいずれかの方法でバイナリを `vendor/` に配置します。

   **方法 A: tar.gz をそのまま配置**（推奨／ファイルサイズ大）
   ```bash
   # 例: arm64 用
   cp ~/Downloads/mediamtx_v1.18.2_linux_arm64.tar.gz vendor/mediamtx_linux_arm64.tar.gz
   ```
   `setup.sh` は `vendor/mediamtx_<arch>.tar.gz` を見つけると自動展開します。

   **方法 B: バイナリだけを配置**
   ```bash
   tar -xzf mediamtx_v1.18.2_linux_arm64.tar.gz mediamtx
   mv mediamtx vendor/mediamtx_linux_arm64
   chmod +x vendor/mediamtx_linux_arm64
   ```
   `<arch>` は `linux_arm64` / `linux_armv7` / `linux_amd64` のいずれか。
   アーキテクチャ無印の `vendor/mediamtx` という名前でも認識されます（ただしクロスアーキの混在に注意）。

4. Git に追加してコミット・プッシュします。
   ```bash
   git add vendor/
   git commit -m "Bundle MediaMTX binary for offline setup"
   git push
   ```

> **注意**: MediaMTX のバイナリは数十 MB あるため、同梱するとリポジトリサイズが大きくなります。LFS の使用、もしくは Releases にアタッチして `vendor/` には配置しないという運用も検討してください。

### 同梱バイナリと自動ダウンロードの優先順位

`setup.sh` は次の順序で MediaMTX を取得します。

1. `vendor/mediamtx_<arch>` （バイナリ単体）
2. `vendor/mediamtx`           （バイナリ単体・アーキ無印）
3. `vendor/mediamtx_<arch>.tar.gz` （tar.gz アーカイブ）
4. GitHub の最新リリース（API 経由）
5. フォールバック固定バージョン（`MEDIAMTX_FALLBACK_VERSION` で指定）

## IP アドレスの固定（オプション）

Raspberry Pi の IP アドレスを固定したい場合は、`fixip.sh` を使用できます。

```bash
sudo ./fixip.sh 10.40.99.X
```

※ スクリプト内の `GATEWAY`, `DNS_SERVERS`, `CONNECTION_NAME` などの変数は、使用するネットワーク環境に合わせて適宜修正してください。

## トラブルシューティング

### `mediamtx.service` が `status=203/EXEC` で停止する

バイナリが見つからない・実行権限がない・アーキテクチャ不一致のいずれかです。

```bash
ls -l ~/mediamtx/mediamtx
file   ~/mediamtx/mediamtx     # ELF ヘッダのアーキを確認
~/mediamtx/mediamtx --version  # 実行できるか
```

`setup.sh` を再実行すれば、自動でダウンロードと検証が走ります。

### `ffmpeg-rtsp.service` が起動しない / 接続が切れる

```bash
journalctl -u ffmpeg-rtsp -n 100 --no-pager
ls -l /dev/video0
v4l2-ctl --list-devices
v4l2-ctl --list-formats-ext -d /dev/video0
```

カメラが MJPEG / 1600x1200 / 15fps をサポートしていない場合は、`setup.sh` の `VIDEO_SIZE` / `FRAMERATE` / `-input_format` を環境に合わせて調整してください。

### videoグループの権限が反映されない

`setup.sh` 自体は `usermod -aG video` を行いますが、systemd 側で `SupplementaryGroups=video` を指定しているため、再ログイン無しでもカメラにアクセスできます。手動で `ffmpeg` を起動する場合は一度ログアウト→ログインしてください。

## ファイル構成

- `setup.sh`     : 自動セットアップスクリプト（MediaMTX のダウンロード・systemd 登録・サービス起動）。
- `fixip.sh`     : NetworkManager で IP アドレスを固定するスクリプト。
- `mediamtx.yml` : MediaMTX の設定ファイル（`~/mediamtx/` にコピーされて使用される）。
- `vendor/`     *(任意)* : 同梱用 MediaMTX バイナリの置き場所。
