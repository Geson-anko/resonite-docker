FROM debian:13-slim

# UID/GID for the non-root user. Match the host so it can read the X auth cookie (mode 0700).
ARG HOST_UID=1000
ARG HOST_GID=1001

# Proton/Wine contains 32-bit code, so enable the i386 architecture.
RUN dpkg --add-architecture i386

# Base tools + X11 smoke test (xeyes) + rsync (diff-sync the install into a volume).
# dbus-x11 provides dbus-launch, which Steam Linux Runtime's launcher-service needs to
# start a session bus (without it: "Can't find session bus: ... dbus-launch (No such
# file or directory)").
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dbus-x11 \
      rsync \
      x11-apps \
 && rm -rf /var/lib/apt/lists/*

# GPU vendor used for rendering. Bundle Mesa in the image for AMD / Intel.
# run.sh detects it and passes it via the compose.{nvidia,amd,intel}.yml build arg
# (default nvidia).
ARG GPU=nvidia

# GPU rendering user space.
#  - NVIDIA:    the real driver (libGLX_nvidia / Vulkan ICD) is injected from the host
#               by nvidia-container-toolkit, so only the GLVND/Vulkan loaders (32/64-bit)
#               are installed. No Mesa Vulkan ICD (keep it minimal, no confusing extra ICDs).
#  - AMD/Intel: the user-space driver (Mesa) isn't injected, so bundle it in the image.
#               The packages are shared between AMD and Intel: mesa-vulkan-drivers ships
#               both the RADV (AMD) and ANV (Intel) Vulkan ICDs, libgl1-mesa-dri the
#               radeonsi/iris GL drivers. Only the ICD matching the real PCI ID enumerates
#               devices, so Intel hosts pick ANV and AMD hosts pick RADV automatically.
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

# Audio: the native-Linux PulseAudio client (libpulse).
# When the Bootstrapper detects Wine, Resonite runs the engine natively on Linux (.NET);
# only the renderer .exe runs under Wine. So the engine's audio backend (SoundFlow/miniaudio)
# dlopens Linux's libpulse, not Wine's, to reach the host's PipeWire/PulseAudio. Without it
# (or if it can't connect) the engine can't open an output device: no sound, and it hangs
# the whole update loop at the first-run onboarding "Audio" step. The socket is mounted by
# compose and pointed at via PULSE_SERVER. The engine is x86_64, so amd64 only.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpulse0 \
 && rm -rf /var/lib/apt/lists/*

# Install the latest umu-launcher from GitHub Releases. Use the official Debian 13 .deb
# (the amd64 python3 module + the arch:all main package).
RUN apt-get update \
 && cd /tmp \
 && curl -fsSL https://api.github.com/repos/Open-Wine-Components/umu-launcher/releases/latest \
      | grep -oE 'https://[^"]+(amd64|all)_debian-13[^"]*\.deb' \
      | xargs -n1 curl -fsSL -O \
 && apt-get install -y --no-install-recommends ./*.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/*.deb

# umu-run refuses to run as root, so create a non-root user (resonite). No password.
# UID/GID match the host.
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then groupadd -g "${HOST_GID}" resonite; fi; \
    useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash resonite; \
    passwd -d resonite

# machine-id is generated per container start by the entrypoint (to make it unique).
# Pre-create an empty resonite-owned file so the non-root user can write it.
RUN install -o resonite -g resonite -m 0644 /dev/null /etc/machine-id \
 && mkdir -p /var/lib/dbus \
 && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Pre-create the named-volume mount points as resonite-owned. Docker initializes an empty
# named volume with the ownership of the image-side directory on first mount, so without
# this the volumes would be root-owned and the non-root user couldn't write (first rsync /
# umu unpack would fail with EACCES).
#   /opt/resonite     : writable copy of Resonite (outside HOME; see entrypoint for why)
#   ~/.local/share    : umu/Proton/Steam Linux Runtime + Resonite user data (login/settings)
#   ~/.cache          : Resonite asset cache + shader cache
#   ~/prefix          : Wine prefix (WINEPREFIX)
# Only the "expensive to refetch / keep-me-logged-in" paths are volumes, not all of HOME.
# Disposable state (machine-id, various logs, .dbus) regenerates per container.
RUN install -d -o resonite -g resonite \
      /opt/resonite \
      /home/resonite/.local /home/resonite/.local/share \
      /home/resonite/.cache \
      /home/resonite/prefix

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER resonite
ENV HOME=/home/resonite
WORKDIR /home/resonite

# umu config. WINEPREFIX is ~/prefix; Proton/Steam Linux Runtime go to ~/.local/share;
# assets go to ~/.cache. These are named volumes for persistence (created above).
# GAMEID=umu-default is the generic ID for a game not in umu's DB (i.e. Resonite).
#
# PROTONPATH=GE-Proton pins Proton to GE-Proton (umu auto-fetches the latest from GitHub
# Releases). With PROTONPATH unset, umu uses the default UMU-Proton (Valve Proton based),
# but that breaks the startup-splash logo texture into an SMPTE-color-bars "test card".
# Resonite's renderer runs as a .exe under Proton, so this splash rendering depends on the
# Proton build; GE-Proton fixes it (also the Resonite-on-Linux community recommendation).
# The fetched GE-Proton lands in ~/.local/share/Steam/compatibilitytools.d, persisted in
# the resonite-share volume, so it isn't re-downloaded on later runs.
ENV GAMEID=umu-default \
    WINEPREFIX=/home/resonite/prefix \
    PROTONPATH=GE-Proton

# entrypoint generates machine-id + cds into the install copy, then execs CMD.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Launch Resonite by default (entrypoint runs the copy synced into the volume).
# First run is slow (downloads Proton/runtime + copies the install).
#
# -SkipIntroTutorial: skip the first-run onboarding (language/audio/... tutorial) and go
#   straight to the dashboard. The first-run wizard isn't useful for container runs. The
#   freeze at the audio-dependent "Audio" step is already fixed by libpulse above; this is
#   insurance plus a UX improvement. Drop this arg to see the tutorial normally.
CMD ["umu-run", "/opt/resonite/Resonite.exe", "-SkipIntroTutorial"]
