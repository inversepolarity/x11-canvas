# x11-canvas — bare Xvfb → x11vnc → websockify → browser canvas.
# No Android, no Appium, no supervisor, no build secrets. The only download is
# the optional desktop wallpaper (WALLPAPER_URL) baked in below.
FROM debian:trixie-slim
# `debian:trixie-slim` works identically; the package set below is Debian/Ubuntu-common.

ARG DEBIAN_FRONTEND=noninteractive
ARG WALLPAPER_URL="https://raw.githubusercontent.com/even-zero/media/refs/heads/main/e0/e0_wallpaper_01.jpg"

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
# firefox-esr         the browser behind openbox's "Web browser" menu entry
# feh                 sets the root-window wallpaper (feh --bg-fill)
# curl                fetches the wallpaper image (WALLPAPER_URL)
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
      firefox-esr \
      dbus-x11 \
      fonts-liberation \
      feh \
      curl \
 && apt-get -qqy clean \
 && rm -rf /var/lib/apt/lists/*

# noVNC ships vnc.html but no index.html, so http://host:port/ returns a
# directory listing. Ship an index.html so the viewer opens automatically.
RUN cp /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Bake in the desktop wallpaper. Build with --build-arg WALLPAPER_URL=... to
# change it, or override WALLPAPER at run time with a path or URL.
RUN mkdir -p /usr/share/x11-canvas \
 && curl -fsSL "$WALLPAPER_URL" -o /usr/share/x11-canvas/wallpaper \
 && ls -l /usr/share/x11-canvas/wallpaper

# Default to root so the interactive terminal (xterm) can install packages
# and administer the container without sudo or password setup.
ENV HOME=/root \
    DISPLAY=:99

COPY entrypoint.sh /usr/local/bin/x11-canvas-entrypoint
COPY smoke.sh       /usr/local/bin/x11-canvas-smoke
COPY selftest.sh    /usr/local/bin/x11-canvas-selftest
RUN chmod 755 /usr/local/bin/x11-canvas-*

# Defaults live here so `docker run -e ...` is the only knob you need.
ENV SCREEN=1600x900x24 \
    WM=openbox \
    APP="xclock -update 1" \
    MOZ_FORCE_DISABLE_CONTENT_SANDBOX=1 \
    VNC_PORT=5900 \
    WEB_PORT=6080 \
    WEB_BIND=0.0.0.0 \
    NOVNC_ROOT=/usr/share/novnc \
    WALLPAPER=/usr/share/x11-canvas/wallpaper \
    ROOT_COLOR="#111111" \
    EXIT_ON_APP_EXIT=true

EXPOSE 5900 6080

# Plain TCP probe: if the canvas is serving, the chain is up end to end.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/${WEB_PORT:-6080}' || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/x11-canvas-entrypoint"]
