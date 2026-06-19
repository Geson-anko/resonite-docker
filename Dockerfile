FROM debian:13-slim

# 非rootユーザのUID/GID。X認証クッキー(mode 0700)を読めるようホストに合わせる。
ARG HOST_UID=1000
ARG HOST_GID=1001

# Proton/Wine は 32bit コードを含むので i386 アーキテクチャを有効化。
RUN dpkg --add-architecture i386

# 基本ツール + X11動作確認用(xeyes) + rsync(インストールをvolumeへ差分同期)。
# dbus-x11 は dbus-launch を提供する。Steam Linux Runtime の
# launcher-service がセッションバスを起こすのに必要(無いと
# "Can't find session bus: ... dbus-launch (No such file or directory)")。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dbus-x11 \
      rsync \
      x11-apps \
 && rm -rf /var/lib/apt/lists/*

# 描画に使う GPU ベンダー。AMD / Intel のとき Mesa をイメージに同梱する。
# run.sh が検出し compose.{nvidia,amd,intel}.yml の build arg 経由で渡す(既定 nvidia)。
ARG GPU=nvidia

# GPU 描画用のユーザ空間。
#  - NVIDIA:    実体のドライバ(libGLX_nvidia / Vulkan ICD)は nvidia-container-toolkit が
#               ホストから注入するので、GLVND/Vulkan のローダ(32/64bit)だけ入れる。
#               Mesa の Vulkan ICD は入れない(最小・余計なICDで混乱させない)。
#  - AMD/Intel: ユーザ空間ドライバ(Mesa)は注入されないのでイメージに同梱する。
#               パッケージは AMD と Intel で共通: mesa-vulkan-drivers は RADV(AMD)と
#               ANV(Intel)両方の Vulkan ICD を、libgl1-mesa-dri は radeonsi/iris の
#               GL ドライバを含む。実機の PCI ID に合う ICD だけがデバイスを列挙するので、
#               Intel 機では ANV、AMD 機では RADV が自動的に選ばれる。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgl1 libgl1:i386 \
      libvulkan1 libvulkan1:i386 \
      vulkan-tools \
 && if [ "$GPU" = "amd" ] || [ "$GPU" = "intel" ]; then \
      apt-get install -y --no-install-recommends \
        libglx-mesa0 libglx-mesa0:i386 \
        libgl1-mesa-dri libgl1-mesa-dri:i386 \
        mesa-vulkan-drivers mesa-vulkan-drivers:i386 ; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# 音声: ネイティブ Linux 側の PulseAudio クライアント(libpulse)。
# Resonite は Bootstrapper が Wine を検出するとエンジン本体をネイティブ Linux の .NET で
# 起動する(Wine で動くのは Renderer の .exe だけ)。そのためエンジンの音声バックエンド
# (SoundFlow/miniaudio)は Wine ではなく Linux の libpulse を dlopen し、ホストの
# PipeWire/PulseAudio に繋ぐ。これが無い・繋げないと出力デバイスを開けず、音が出ないうえ
# 初回オンボーディングの「Audio」ステップでエンジンの Update ループごとハングしてフリーズする。
# 実体のソケットは compose で mount し PULSE_SERVER で指す。エンジンは x86_64 なので amd64 のみ。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpulse0 \
 && rm -rf /var/lib/apt/lists/*

# umu-launcher の latest を GitHub Releases から取得してインストール。
# Debian 13 用の公式 .deb (amd64 の python3 モジュール + arch:all 本体) を使う。
RUN apt-get update \
 && cd /tmp \
 && curl -fsSL https://api.github.com/repos/Open-Wine-Components/umu-launcher/releases/latest \
      | grep -oE 'https://[^"]+(amd64|all)_debian-13[^"]*\.deb' \
      | xargs -n1 curl -fsSL -O \
 && apt-get install -y --no-install-recommends ./*.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/*.deb

# umu-run は root だと実行を拒否するので非rootユーザ(resonite)を作成。
# パスワードは削除(no-password)。UID/GID はホストに合わせる。
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then groupadd -g "${HOST_GID}" resonite; fi; \
    useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash resonite; \
    passwd -d resonite

# machine-id は entrypoint がコンテナ起動毎に生成する(コンテナ固有にするため)。
# 非rootでも書けるよう、空ファイルを resonite 所有で用意しておく。
RUN install -o resonite -g resonite -m 0644 /dev/null /etc/machine-id \
 && mkdir -p /var/lib/dbus \
 && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 永続化する named volume のマウントポイントを resonite 所有で先に作っておく。
# Docker は空の named volume を初回マウント時にイメージ側ディレクトリの所有権で
# 初期化するため、ここで resonite 所有にしておかないと root 所有の volume になり
# 非rootユーザが書き込めなくなる(初回 rsync / umu 展開が EACCES で失敗する)。
#   /opt/resonite     : Resonite 本体の書き込み可能コピー(HOME外。理由は entrypoint 参照)
#   ~/.local/share    : umu/Proton/Steam Linux Runtime + Resonite ユーザデータ(login/設定)
#   ~/.cache          : Resonite アセットキャッシュ + シェーダキャッシュ
#   ~/prefix          : Wine プレフィックス(WINEPREFIX)
# HOME 全体ではなく「再取得が高価/ログイン状態を保ちたい」ものだけを volume にする。
# machine-id・各種 log・.dbus 等の使い捨て状態はコンテナごとに新規生成させる。
RUN install -d -o resonite -g resonite \
      /opt/resonite \
      /home/resonite/.local /home/resonite/.local/share \
      /home/resonite/.cache \
      /home/resonite/prefix

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER resonite
ENV HOME=/home/resonite
WORKDIR /home/resonite

# umu の設定。WINEPREFIX は ~/prefix、Proton/Steam Linux Runtime は ~/.local/share、
# アセットは ~/.cache に作られる。これらを named volume にして永続化する(上で作成)。
# GAMEID=umu-default は umu DB に無いゲーム(=Resonite)向けの汎用ID。
#
# PROTONPATH=GE-Proton で Proton を GE-Proton に固定する(umu が GitHub Releases から
# 最新版を自動取得)。PROTONPATH 未指定だと umu は既定の UMU-Proton(Valve Proton ベース)
# を使うが、それだと Resonite の起動スプラッシュのロゴテクスチャ描画が壊れ、SMPTE
# カラーバー+ノイズの「テストカード」状になる。Resonite の Renderer は Proton 上の .exe で
# 動くため、このロゴ描画は Proton 実装に依存する。GE-Proton はこの描画問題を解消する
# (Resonite on Linux コミュニティの推奨も Proton-GE)。取得した GE-Proton は umu が
# ~/.local/share/Steam/compatibilitytools.d に置くので resonite-share volume に永続化され、
# 2回目以降は再ダウンロードしない。
ENV GAMEID=umu-default \
    WINEPREFIX=/home/resonite/prefix \
    PROTONPATH=GE-Proton

# entrypoint で machine-id 生成 + /resonite へ cd してから CMD を exec。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# 既定で Resonite を起動(entrypoint が volume へ同期したコピーを実行)。
# 初回は Proton/runtime のDL + インストールのコピーで時間がかかる。
#
# -SkipIntroTutorial: 初回オンボーディング(言語/音声/…のチュートリアル)を出さずに
#   そのままダッシュへ入る。コンテナ運用では毎回の初回ウィザードが不要なため省く。
#   音声依存の「Audio」ステップでのフリーズは上の libpulse で解消済みで、これはその保険
#   兼 UX 改善。チュートリアルを通常どおり見たい場合はこの引数を外す。
CMD ["umu-run", "/opt/resonite/Resonite.exe", "-SkipIntroTutorial"]
