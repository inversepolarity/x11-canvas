# Example: a browser node you can watch and drive from a browser.
#
# Base image already carries Appium + the Selenium-side drivers, and the chain below
# the emulator is generic. Point APP at a browser and the same container becomes
# a live-attachable web test node.
FROM x11-canvas:local

USER root
RUN apt-get -qqy update \
 && apt-get -qqy install --no-install-recommends \
      firefox-esr \
      dbus-x11 \
      fonts-liberation \
      libgtk-3-0 \
      libxcomposite1 \
      libxdamage1 \
      libxrandr2 \
 && apt-get -qqy clean && rm -rf /var/lib/apt/lists/*
USER canvas

# 1920x1080 so page layout matches what a human would test at; the crop keeps
# the browser filling the canvas rather than floating in it.
ENV APP="firefox --no-remote --private-window about:home" \
    VNC_WINDOW=firefox \
    SCREEN=1920x1080x24 \
    ROOT_COLOR="#0b0b0f" \
    VNC_EXTRA="-ncache 10"

# Notes, in order of how often they bite:
#   * --ipc=host (or --shm-size=2g) on `docker run`: shared-memory starvation
#     kills content processes with no useful message.
#   * Firefox's content sandbox needs unprivileged user namespaces. On a locked
#     down host, add `--security-opt seccomp=unconfined` (weaker isolation) or
#     set MOZ_FORCE_DISABLE_CONTENT_SANDBOX=1 and accept the trade knowingly.
#   * dbus is installed and used by Firefox directly; no `dbus-launch` wrapper is
#     needed, but if you want a full session bus wrap APP as:
#     APP="dbus-launch --exit-with-session firefox --no-remote about:home"
#   * For Chromium instead: APP="chromium --no-sandbox --disable-dev-shm-usage".
