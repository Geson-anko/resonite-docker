# resonite-docker

[Resonite](https://resonite.com/)(VR ソーシャルプラットフォーム)を Linux 上の Docker で動かし、**ホストのデスクトップ**(X11 / Wayland)へ描画しながら、**GPU アクセラレーション**(NVIDIA / AMD / Intel)と**ホスト音声**を使えるようにする構成です。

コンテナは Resonite 本体を**同梱しません**。ホストの Steam 版インストールを read-only で bind mount し、[umu-launcher](https://github.com/Open-Wine-Components/umu-launcher)(Proton/Wine)経由で起動します。難所は Resonite そのものではなくホスト統合(X11・GPU・音声・共有メモリ IPC・user namespace)で、このリポジトリはその一式をまとめたものです。

> 🌐 **English version: see [README.md](README.md).**

---

描画は常に **X11 経由**です。Resonite のレンダラは Proton/Wine の `.exe`(X11 アプリ)なので、Wayland セッションでも **Xwayland** を介して描画します。ここでいう「Wayland 対応」とは「Xwayland のディスプレイへ正しく接続する」ことであり、ネイティブ Wayland レンダリングは行いません。

## 仕組み(メンタルモデル)

Resonite の Bootstrapper は Wine を検出すると実行を分割します:

- **エンジンはネイティブ Linux の .NET で動きます。** 音声バックエンドは Wine ではなく `libpulse` 経由でホストの PipeWire/PulseAudio に接続します。
- **レンダラの `.exe` だけが Proton/Wine で動き**、X11(Wayland では Xwayland)へ描画します。
- **エンジン ↔ レンダラ IPC** は `/dev/shm` 上の memory-mapped file(`Cloudtoid.Interprocess`)を使います。これが `ipc: host` を必要とする理由です。

この分割が構成のほぼ全ての設定を決めています。

## 必要なもの

- **Linux** と Docker + Docker Compose。
- コンテナが描画できる**グラフィカルセッション**。Wayland では **Xwayland が動作している**こと(`DISPLAY` と `/tmp/.X11-unix/X*` ソケットが存在すること)。
- 既存の **Resonite インストール**(Steam 版)。既定パス: `~/.steam/steam/steamapps/common/Resonite`。
- **GPU**:
  | ベンダー | 状態 | 備考 |
  | --- | --- | --- |
  | NVIDIA | ✅ 検証済み | [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) が必要。ドライバはホストから注入。 |
  | AMD | ✅ 検証済み | Mesa/RADV をイメージに同梱。 |
  | Intel | ✅ 検証済み | iGPU を Mesa(iris/ANV)で。動作は重い。 |
- `/run/user/<uid>/pulse/native` で動作している **PipeWire**(または PulseAudio)ソケット。
- ホストの `kernel.apparmor_restrict_unprivileged_userns=0`(Ubuntu 24.04 以降は既定で有効になっており、Steam Linux Runtime の pressure-vessel を阻害します):
  ```bash
  # 一時的
  sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
  # 永続化
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-resonite-userns.conf && sudo sysctl --system
  ```

## クイックスタート

```bash
git clone https://github.com/Geson-anko/resonite-docker.git
cd resonite-docker

./init.sh        # 手順1: ホストを調べて .env を生成(UID/GID, DISPLAY, X クッキー, GPU, ...)
./run.sh         # 手順2: GPU を検出し、適した overlay で `docker compose up --build`
```

`init.sh` は音声ソケットや userns の sysctl が無いと(非致命の)警告を出します — クリーンな起動のためには先に解消してください。

Resonite が既定の Steam パスに無い場合:

```bash
RESONITE_DIR=/path/to/Resonite ./init.sh
```

> **`./run.sh` の前に必ず `./init.sh` を実行してください。** `.env` は gitignore 対象で、`compose.yaml` はこれが無いと即失敗します。再ログイン後やモニタ/GPU 構成を変えた後は `./init.sh` を再実行してください(X クッキーのパスはセッション固有です)。

**初回起動は時間がかかります:** GE-Proton + Steam Linux Runtime のダウンロードと、約 2GB の Resonite を volume へ rsync するためです。2 回目以降は変化したファイルだけ同期します。

## 操作

`run.sh` は追加引数をそのまま `docker compose` へ渡します(overlay は選択済み):

```bash
./run.sh logs -f     # ログを追う
./run.sh up -d       # デタッチ起動
./run.sh down        # 停止して削除
./run.sh down -v     # volume も削除(完全リセット: 再同期 + 再ログイン)
```

## 永続化

`down` を跨いで残るのは named volume 4 つだけ — `$HOME` 全体ではありません。使い捨て状態(machine-id・各種ログ・`.dbus`)はコンテナごとに再生成されます。

| Volume | マウント先 | 内容 |
| --- | --- | --- |
| `resonite-app` | `/opt/resonite` | インストールの書き込み可能コピー(read-only マウントから rsync) |
| `resonite-share` | `~/.local/share` | umu/Proton/Steam Linux Runtime + Resonite のログイン・設定 |
| `resonite-cache` | `~/.cache` | アセット + シェーダキャッシュ |
| `resonite-prefix` | `~/prefix` | Wine プレフィックス(`WINEPREFIX`) |

## リポジトリ構成

| ファイル | 役割 |
| --- | --- |
| `init.sh` | **ホスト側**で実行し、`.env` と FamilyWild 化した X クッキー `.xauth` を生成。 |
| `run.sh` | GPU ベンダーを検出し、対応する overlay で `docker compose` を実行。 |
| `compose.yaml` | GPU 非依存のベース(X11・音声・IPC・volume・namespace)。 |
| `compose.{nvidia,amd,intel}.yml` | GPU ベンダー overlay(ちょうど 1 つをベースに重ねる)。 |
| `Dockerfile` | 最小の Debian イメージ: umu-launcher・libpulse、Mesa は AMD/Intel のときだけ。 |
| `entrypoint.sh` | インストールを書き込み可能 volume へ rsync してから起動。 |

このリポジトリの価値は各ホストハックの *なぜ* にあります — **設定を変える前に、その隣のコメントを読んでください。**

## トラブルシューティング

失敗の多くは Resonite のバグではなくホスト統合の問題です。まず `./run.sh logs -f` を見て、症状を照らし合わせてください:

| 症状 | 想定原因 / 対処 |
| --- | --- |
| ウィンドウが出ず無言で終了 / `cannot open display` | X 認証かディスプレイ指定。`./init.sh` を再実行し、`.xauth` が空でない(`xauth -f .xauth list`)こと、`DISPLAY` が**自分が所有する** X ソケットを指すことを確認。 |
| ランダムにクラッシュ/ハング、`X_ShmPutImage` / `BadValue` | X MIT-SHM が IPC 名前空間を跨げない。`compose.yaml` に `ipc: host` があること。 |
| 「Bootstrapper messaging timeout」、レンダラが起動しない | エンジン↔レンダラ IPC に広い `/dev/shm` が必要。`ipc: host` で確保(`shm_size` は併用しない)。 |
| 初回「Audio」ステップでフリーズ / 音が出ない | ホスト音声に届いていない。`libpulse0` が入っていること、PulseAudio/PipeWire ソケットが mount されていること、PipeWire が動作していることを確認。 |
| `Can't find session bus` / `dbus-launch: No such file` | イメージに `dbus-x11` が必要。 |
| 起動スプラッシュがカラーバー/テストカード状に崩れる | 既定の Proton がロゴ描画を誤る。`Dockerfile` の `PROTONPATH=GE-Proton` で解消。Proton 11 / Experimental は避ける。 |
| 初回 rsync / umu 展開で `EACCES` | volume のマウントポイントが root 所有になっている。`Dockerfile` が `resonite` 所有で先に作成済み。`.env` の UID/GID がホストと一致するか確認。 |
| 別の GPU で描画される / モニタに何も出ない(マルチ GPU) | `./init.sh` を再実行してモニタ接続側の GPU を検出し直す。 |

## クレジット

- [Resonite](https://resonite.com/) by Yellow Dog Man Studios。
- [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher)(Open Wine Components)、[GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom)。

## ライセンス

[MIT](LICENSE) © Geson-anko
