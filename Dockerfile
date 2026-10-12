# x11-canvas — bare Xvfb → x11vnc → websockify → browser canvas.
# No Android, no Appium, no supervisor, no build secrets, nothing downloaded.
FROM ubuntu:26.04
# `debian:trixie-slim` works identically; the package set below is Debian/Ubuntu-common.

ARG DEBIAN_FRONTEND=noninteractive

#==========================
# The entire dependency set
#--------------------------
# xvfb                the display (X server with no hardware behind it)
# x11vnc              X framebuffer -> RFB/VNC; attaches to a *running* display
# novnc               the browser-side JS client (static files, no daemon)
# python3-websockify  HTTP+WebSocket <-> TCP proxy, serves noVNC and tunnels RFB
# openbox             window manager (only if WM=openbox)
# x11-xserver-utils   xsetroot (flat root colour instead of the default stipple)
# xdotool             find a window id, for VNC_WINDOW cropping
# x11-utils           xwininfo/xlsclients, used by the smoke test
# x11-apps            xclock, the zero-dependency default payload
# xterm               a terminal on the canvas: right-click menu / debugging
# xfonts-base         core X fonts, still needed by older X clients
# fonts-dejavu-core   fontconfig fonts, needed by anything modern (GTK/Qt/browser)
#==========================
RUN apt-get -qqy update \
 && apt-get -qqy install --no-install-recommends \
      xvfb \
      x11vnc \
      novnc \
      python3-websockify \
      openbox \
      x11-xserver-utils \
      xdotool \
      x11-utils \
      x11-apps \
      xterm \
      xfonts-base \
      fonts-dejavu-core \
 && apt-get -qqy clean \
 && rm -rf /var/lib/apt/lists/*

# X11 + VNC need a writable HOME and /tmp; run unprivileged (nothing here needs
# root: no /dev/kvm, no chown of anything, no sudoers hack).
RUN useradd --create-home --shell /bin/bash canvas
USER canvas
ENV HOME=/home/canvas \
    DISPLAY=:99

COPY --chown=canvas:canvas entrypoint.sh /usr/local/bin/x11-canvas-entrypoint
COPY --chown=canvas:canvas smoke.sh       /usr/local/bin/x11-canvas-smoke
COPY --chown=canvas:canvas selftest.sh    /usr/local/bin/x11-canvas-selftest
RUN chmod 755 /usr/local/bin/x11-canvas-*

# Defaults live here so `docker run -e ...` is the only knob you need.
ENV SCREEN=1600x900x24 \
    WM=openbox \
    APP="xclock -update 1" \
    VNC_PORT=5900 \
    WEB_PORT=6080 \
    WEB_BIND=0.0.0.0 \
    NOVNC_ROOT=/usr/share/novnc \
    ROOT_COLOR="#111111" \
    EXIT_ON_APP_EXIT=true

EXPOSE 5900 6080

# Plain TCP probe: if the canvas is serving, the chain is up end to end.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/${WEB_PORT:-6080}' || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/x11-canvas-entrypoint"]
