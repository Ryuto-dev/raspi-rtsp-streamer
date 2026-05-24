# Raspberry Pi 5 RTSP Streamer

このプロジェクトは、Raspberry Pi 5とUVCカメラ（USBカメラ）を使用して、RTSPストリーミングサーバーを自動的にセットアップするためのスクリプト群です。

## 特徴

- **MediaMTX**: 高性能なRTSP/RTMP/HLS/WebRTCサーバー。
- **FFmpeg**: カメラ映像をH.264にエンコードし、MediaMTXに配信。
- **systemd 対応**: 再起動後も自動的にストリーミングを開始します。
- **最適化**: Raspberry Pi 5向けに、1600x1200 / 15fps / TCP転送で設定されています。

## 前提条件

- Raspberry Pi 5
- Raspberry Pi OS (64-bit)
- USB接続のUVC対応カメラ（`/dev/video0` として認識されるもの）

## セットアップ方法

1.  リポジトリをクローンまたはダウンロードします。
2.  `setup.sh` に実行権限を与えます。
    ```bash
    chmod +x setup.sh
    ```
3.  セットアップスクリプトを実行します。
    ```bash
    ./setup.sh
    ```

スクリプトは以下の処理を自動で行います。
- 必要なパッケージ（ffmpeg, v4l-utils等）のインストール
- MediaMTXのダウンロードと配置
- systemdサービス（`mediamtx.service`, `ffmpeg-rtsp.service`）の作成と有効化

## 使い方

セットアップ完了後、ネットワーク内のPCから以下のURLでストリームを視聴できます（VLCメディアプレーヤー等を使用）。

```
rtsp://<Raspberry_PiのIPアドレス>:8554/live
```

### サービスの管理

ストリーミングの状態確認や停止・開始は以下のコマンドで行います。

- **状態確認**:
  ```bash
  sudo systemctl status mediamtx ffmpeg-rtsp
  ```
- **停止**:
  ```bash
  sudo systemctl stop mediamtx ffmpeg-rtsp
  ```
- **開始**:
  ```bash
  sudo systemctl start mediamtx ffmpeg-rtsp
  ```
- **再起動**:
  ```bash
  sudo systemctl restart mediamtx ffmpeg-rtsp
  ```

## 設定の変更

- **解像度やフレームレート**: `setup.sh` 内の FFmpeg の実行引数を変更して再実行してください。
- **MediaMTXの詳細設定**: `mediamtx.yml` を編集してください。

## IPアドレスの固定（オプション）

Raspberry PiのIPアドレスを固定したい場合は、`fixip.sh` を使用できます。

```bash
sudo ./fixip.sh 10.40.99.X
```

※ **注意**: スクリプト内の `GATEWAY`, `DNS_SERVERS`, `CONNECTION_NAME` などの変数は、使用するネットワーク環境に合わせて適宜修正してください。

## ファイル構成

- `setup.sh`: 自動セットアップスクリプト。
- `fixip.sh`: NetworkManagerを使用してIPアドレスを固定するスクリプト。
- `mediamtx.yml`: MediaMTXの設定ファイル（サーバーの動作設定）。
