# Example: swap the payload. Nothing about Xvfb/x11vnc/websockify changes —
# only APP, and optionally the screen size and the crop target.
FROM x11-canvas:local

USER root
RUN apt-get -qqy update \
 && apt-get -qqy install --no-install-recommends python3-tk \
 && apt-get -qqy clean && rm -rf /var/lib/apt/lists/*
USER canvas

COPY viewer.py /app/viewer.py

# APP is a shell command line, so anything you could type in a terminal works.
# VNC_WINDOW is a WM_CLASS or WM_NAME regex: the stream is cropped to that
# window instead of the whole screen. SCREEN matches the app so there is no
# dead space around it (and fewer pixels to encode per frame).
ENV APP="python3 /app/viewer.py" \
    VNC_WINDOW=canvas-demo \
    SCREEN=800x400x24 \
    ROOT_COLOR="#0b0b0f"

# docker run -p 6080:6080 <tag>, then open http://localhost:6080/vnc.html
