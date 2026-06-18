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

# GPU(NVIDIA)描画用のローダ群。実体のNVIDIAドライバ(libGLX_nvidia / Vulkan ICD)は
# nvidia-container-toolkit がホストから注入するので、ここでは GLVND / Vulkan の
# ローダ(32/64bit)と確認ツール(vulkaninfo)だけ入れる。Mesa は不要。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgl1 libgl1:i386 \
      libvulkan1 libvulkan1:i386 \
      vulkan-tools \
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

# Resonite 本体の書き込み可能コピー置き場(専用 volume のマウントポイント)。
# HOME(=volume)配下に置くと umu が親マウントを gamedrive(S:)にしてしまうため、
# あえて HOME の外に置く。resonite 所有にしておくと named volume 初期化時に
# その所有権が引き継がれ、非rootでも rsync で書き込める。
RUN install -d -o resonite -g resonite /opt/resonite

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER resonite
ENV HOME=/home/resonite
WORKDIR /home/resonite

# umu の設定。WINEPREFIX / Proton / Steam Linux Runtime はすべて HOME 配下に
# 作られるので、HOME を named volume にすれば丸ごと永続化できる。
# GAMEID=umu-default は umu DB に無いゲーム(=Resonite)向けの汎用ID。
ENV GAMEID=umu-default \
    WINEPREFIX=/home/resonite/prefix

# entrypoint で machine-id 生成 + /resonite へ cd してから CMD を exec。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# 既定で Resonite を起動(entrypoint が volume へ同期したコピーを実行)。
# 初回は Proton/runtime のDL + インストールのコピーで時間がかかる。
CMD ["umu-run", "/opt/resonite/Resonite.exe"]
