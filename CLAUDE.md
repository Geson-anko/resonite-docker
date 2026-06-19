# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

このリポジトリは [Resonite](https://resonite.com/)(VR ソーシャルプラットフォーム)を Linux 上の Docker で動かし、**ホストの X11 デスクトップへ描画**しながら、GPU(NVIDIA / AMD)アクセラレーションとホスト音声を使えるようにする構成一式である。コンテナは Resonite 本体を同梱しない — ホストの Steam 版インストールを read-only で bind mount し、[`umu-launcher`](https://github.com/Open-Wine-Components/umu-launcher)(Proton/Wine)経由で起動する。

アプリのソースコードは無く、リポジトリの中身はシェルスクリプト数本・`Dockerfile`・Docker Compose ファイルだけである。難所はホスト統合(X11・GPU・音声・共有メモリ IPC・user namespace)で、非自明な判断のほぼ全てがインラインコメントに書かれている。**設定を変える前に、必ずその設定の隣のコメントを読むこと。**

## コマンド

```bash
./init.sh        # 手順1: ホストを調べて .env を生成(UID/GID, DISPLAY, GPU UUID, render/video GID, RESONITE_DIR)
./run.sh         # 手順2: GPU を検出し、適した compose overlay で `docker compose up --build`

# RESONITE_DIR は既定で ~/.steam/steam/steamapps/common/Resonite。別の場所なら上書きする:
RESONITE_DIR=/path/to/Resonite ./init.sh

# run.sh は追加引数をそのまま docker compose へ渡す(overlay は選択済み):
./run.sh down
./run.sh logs -f
./run.sh up -d
```

`./run.sh` の前に必ず `./init.sh` を実行する — `.env` は gitignore 対象で、`compose.yaml` はこれが無いと即失敗する(`RESONITE_DIR:?run ./init.sh first`)。

テスト/Lint の仕組みは無い。シェルスクリプトは `set -euo pipefail`。編集したら `bash -n <script>`(可能なら `shellcheck` / `shfmt`)で確認する。

## アーキテクチャ

### 2段階の起動: `init.sh` → `run.sh`

`init.sh` は**ホスト側**で実行し、マシンごとに異なる値を全て検出して `.env` に書き出す:

- ホストの `UID`/`GID` — コンテナの非 root ユーザ `resonite` をこれに合わせて作り、named volume 上のファイルや X 認証クッキーを読み書きできるようにする。
- `DISPLAY` — SSH 接続で `$DISPLAY` が空のときは `who` / `/tmp/.X11-unix` から拾う。
- `NVIDIA_GPU_UUID` — モニタが実際につながっている GPU の UUID(マルチ GPU で重要。PRIME コピーを避ける)。
- `RENDER_GID` / `VIDEO_GID` — ホストの `/dev/dri` の GID。`group_add` でコンテナユーザに付与する。

加えて、コンテナ内からは直せない2つのホスト前提を(非致命の)警告で知らせる: PulseAudio/PipeWire ソケットが動いていること、`kernel.apparmor_restrict_unprivileged_userns=0` であること(Steam Linux Runtime の pressure-vessel が user namespace を張るのに必要)。

`run.sh` は GPU ベンダーを検出し(NVIDIA は `nvidia-smi`/デバイスノード、それ以外は DRM の PCI ベンダー ID)、対応する overlay を重ねて `docker compose` を実行する。

### Compose のレイヤリング

`compose.yaml` が GPU 非依存のベース。`run.sh` がちょうど1つの overlay を重ねる:

- `compose.nvidia.yml` — `runtime: nvidia`(toolkit がホストのドライバを注入)、`NVIDIA_VISIBLE_DEVICES`/`NVIDIA_DRIVER_CAPABILITIES` を設定。イメージ内の Mesa は使われない。
- `compose.amd.yml` — 通常の `runc`。GPU アクセスはベースの `/dev/dri` + グループで足り、Mesa/RADV のユーザ空間ドライバはイメージに同梱(`GPU=amd` ビルド arg)。**AMD 経路は実機未検証**(開発環境は NVIDIA)。

### Resonite の実際の動き方(最重要のメンタルモデル)

Resonite の Bootstrapper は Wine を検出すると実行を分割する: **エンジンはネイティブ Linux の .NET で動き**、**レンダラの `.exe` だけが Wine/Proton で動く**。これが構成全体を決める:

- **音声**は Wine 音声ではなくネイティブ Linux の `libpulse`(イメージが `libpulse0` を入れる)を使う — エンジンが `dlopen` し、`PULSE_SERVER` 経由でホストの PipeWire/PulseAudio に繋ぐ。無いと初回オンボーディングの「Audio」ステップでエンジンがハングする(最新コミットで修正した freeze)。
- **エンジン↔レンダラ IPC** は `/dev/shm` 上の `Cloudtoid.Interprocess` の memory-mapped file を使う。これが `ipc: host` を必要とする理由(X11 の MIT-SHM と広い `/dev/shm` も同時に得られる)。

### read-only のホスト install → 書き込み可能なコピー(`entrypoint.sh`)

Resonite は自身の install ディレクトリに書き込む(ログ等)ため、read-only の bind mount からは起動できない。`entrypoint.sh` は `/resonite`(ro)→ `/opt/resonite`(書き込み可能な named volume)へ `rsync` し、そこへ `cd` してから CMD を exec する。ホストの install は一切変更しない。2回目以降は変化したファイルだけ同期する。

**重要:** `/opt/resonite` は意図的に **`$HOME` の外**に置く。`$HOME` 自体が volume mount なので、その配下に install を置くと umu が親マウントを Wine の `S:` ゲームドライブにしてしまい、現在ドライブが `S:` になって絶対 Unix パス(`/dev/shm` 等)が誤解決される。`$HOME` 外なら現在ドライブが `Z:`(→ `/`)で正しく解決される。

### 永続化モデル

永続化するのは named volume 4つだけ — `$HOME` 全体ではない。使い捨て状態(`machine-id`・各種ログ・`.dbus`)はコンテナごとに再生成させる:

- `resonite-app` → `/opt/resonite`(書き込み可能な install コピー)
- `resonite-share` → `~/.local/share`(umu/Proton/Steam Linux Runtime + Resonite のログイン・設定)
- `resonite-cache` → `~/.cache`(アセット + シェーダキャッシュ)
- `resonite-prefix` → `~/prefix`(`WINEPREFIX`)

これらのマウントポイントは `Dockerfile` で `resonite` 所有として先に作っておく。初回 volume 初期化で root 所有になるのを防ぐため(さもないと rsync/umu 展開が `EACCES` で失敗する)。

## 規約

- **コメントが根拠を担う。** このプロジェクトの価値は各ホストハックの *なぜ* にある。設定を変えたら隣のコメントも更新し、追加したらそれが防ぐ失敗モードを(既存コメントと同様に)説明する。
- **リポジトリ内のコメントは日本語**。この CLAUDE.md も日本語。`.claude/` の agents / skills は英語で統一している。ユーザの言語に合わせて応答する(`japanese` skill 参照)。
- ホスト固有の値をハードコードしない — それらは `init.sh` 経由で `.env` に入れる。GPU ベンダー固有の設定は overlay に、共通設定は `compose.yaml` に置く。
- `Dockerfile` は意図的に最小: NVIDIA には GLVND/Vulkan ローダだけ(ドライバは toolkit が注入)、Mesa は **AMD のときだけ**入れる。ランタイムが既に提供する ICD/ドライバを足さない。
- 永続化レイアウト・`/opt/resonite` の置き場所・`ipc: host` / namespace 設定の変更は、ドライブレター解決・共有メモリ IPC・X11 にまたがって効く。これらは load-bearing(構造を支える)設定として扱う。
