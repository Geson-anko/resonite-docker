FROM debian:13-slim

# 非rootユーザのUID/GID。X認証クッキー(mode 0700)を読めるようホストに合わせる。
ARG HOST_UID=1000
ARG HOST_GID=1001

# Proton/Wine は 32bit コードを含むので i386 アーキテクチャを有効化。
RUN dpkg --add-architecture i386

# 基本ツール + X11動作確認用(xeyes)。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      x11-apps \
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

# machine-id を用意(無いと dbus セッションバスが起動できず警告/不具合の元)。
RUN cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id \
 && mkdir -p /var/lib/dbus \
 && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# umu-run は root だと実行を拒否するので非rootユーザ(resonite)を作成。
# パスワードは削除(no-password)。UID/GID はホストに合わせる。
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then groupadd -g "${HOST_GID}" resonite; fi; \
    useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash resonite; \
    passwd -d resonite

USER resonite
ENV HOME=/home/resonite
WORKDIR /home/resonite

# umu の設定。WINEPREFIX / Proton / Steam Linux Runtime はすべて HOME 配下に
# 作られるので、HOME を named volume にすれば丸ごと永続化できる。
# GAMEID=umu-default は umu DB に無いゲーム(=Resonite)向けの汎用ID。
ENV GAMEID=umu-default \
    WINEPREFIX=/home/resonite/prefix

# 既定で Resonite を起動。初回は Proton と runtime をDLするので時間がかかる。
CMD ["umu-run", "/resonite/Resonite.exe"]
