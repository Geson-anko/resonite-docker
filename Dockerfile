FROM debian:13-slim

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

CMD ["xeyes"]
