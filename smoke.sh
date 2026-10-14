#!/usr/bin/env bash
#
# x11-canvas-smoke — verify the chain end to end, from inside the container.
# Shipped so a refactor of entrypoint.sh can be checked in one command:
#
#   docker exec <ctr> x11-canvas-smoke
#   ./x11-canvas-smoke                       # also works from the host if DISPLAY is set
#
set -uo pipefail

DISPLAY="${DISPLAY:-:99}"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-6080}"
SCREEN="${SCREEN:-1600x900x24}"
APP="${APP:-xclock}"
fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '  note %s\n' "$*"; }

printf 'x11-canvas smoke: display=%s vnc=%s web=%s\n' "$DISPLAY" "$VNC_PORT" "$WEB_PORT"

# 1. X server answers on the display, with the geometry we asked for.
if geo=$(DISPLAY="$DISPLAY" xwininfo -root 2>/dev/null | awk '/Width:|Height:/{print $2}' | paste -sd x -); then
  want="${SCREEN%x*}"                       # drop the depth
  [ "$geo" = "$want" ] && ok "X is up, root geometry $geo" || bad "geometry is $geo, expected $want"
else
  bad "cannot reach X display $DISPLAY (is Xvfb running / XSOCK present?)"
fi

# 2. The payload actually mapped a real window (named + non-trivial size).
#    openbox's own 1x1 input-focus windows are filtered out, so this genuinely
#    means "the APP drew something", not "the display has children".
if [ "${APP:-none}" != none ]; then
  appwin=$(DISPLAY="$DISPLAY" xwininfo -root -tree 2>/dev/null \
           | grep -E '^[[:space:]]+0x[0-9a-f]+ "[^"]+"' | grep -vE '1x1\+' | head -1)
  if [ -n "$appwin" ]; then
    ok "window mapped:${appwin:0:70}"
  else
    bad "no named, non-trivial window — APP='$APP' is not drawing (SMOKE: check the app's own stderr)"
  fi
fi

# 3. x11vnc is serving RFB, and says which security type it wants.
banner=$( { exec 3<>/dev/tcp/127.0.0.1/"$VNC_PORT" || exit 1; head -c 12 <&3; exec 3<&-; } 2>/dev/null )
case "$banner" in
  RFB\ 003.*) ok "VNC handshake: ${banner%%$'\n'*}" ;;
  *)          bad "no RFB banner on $VNC_PORT (got: '${banner:0:16}')" ;;
esac

# 4. websockify serves the noVNC client over HTTP (raw /dev/tcp: no curl/wget dep).
http_first_line() {
  { exec 3<>/dev/tcp/127.0.0.1/"$WEB_PORT" 2>/dev/null || return 1
    printf 'GET %s HTTP/1.0\r\nHost: x\r\n\r\n' "$1" >&3
    IFS= read -t 5 -r line <&3 || line=""
    exec 3<&- 3>&-
    printf '%s' "$line"; } 2>/dev/null
}
r=$(http_first_line /index.html)
case "$r" in *" 200"*) ok "GET /index.html -> 200" ;; *) bad "GET /index.html -> '${r:-no response}'" ;; esac
r=$(http_first_line /)
case "$r" in *" 200"*) ok "GET / -> 200 (index.html opens automatically)" ;;
                   *) bad "GET / -> '${r:-no response}' (no index.html; only /vnc.html reachable)" ;; esac

# 5. The full browser path: WebSocket upgrade on the web port, then read the RFB
#    banner back out *through* the proxy. This is what noVNC does; if this
#    passes, canvas-side connectivity is real, not just two listening sockets.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$WEB_PORT" "$VNC_PORT" <<'PY'
import base64, os, socket, struct, sys
web, vnc = int(sys.argv[1]), int(sys.argv[2])
key = base64.b64encode(os.urandom(16)).decode()
req = (f"GET /websockify HTTP/1.1\r\nHost: 127.0.0.1:{web}\r\nUpgrade: websocket\r\n"
       f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
try:
    s = socket.create_connection(("127.0.0.1", web), timeout=5)
    s.sendall(req.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        b = s.recv(1)
        if not b: break
        head += b
    status = head.split(b"\r\n", 1)[0].decode(errors="replace")
    if "101" not in status:
        print(f"  FAIL websocket upgrade -> {status}"); sys.exit(1)
    # first frame websockify sends is the RFB banner from x11vnc
    s.settimeout(5)
    b0 = s.recv(1); ln = s.recv(1)[0]
    if ln & 0x7F == 126: ln = struct.unpack(">H", s.recv(2))[0]
    data = b""
    while len(data) < ln: data += s.recv(ln - len(data))
    if data.startswith(b"RFB 003."):
        print(f"  ok   browser path: WS 101 + tunnelled banner {data[:12]!r}"); sys.exit(0)
    print(f"  FAIL tunnel delivered {data[:16]!r}"); sys.exit(1)
except Exception as e:
    print(f"  FAIL {type(e).__name__}: {e}"); sys.exit(1)
PY
  [ $? -eq 0 ] || fail=$((fail + 1))
else
  note "python3 absent; skipped the WebSocket end-to-end check"
fi

# 6. Liveness: the framebuffer is changing (only meaningful for an animating APP).
if [ "${SMOKE_REQUIRE_ANIMATION:-false}" = true ]; then
  h1=$(DISPLAY="$DISPLAY" xwd -root -silent 2>/dev/null | md5sum)
  sleep 2
  h2=$(DISPLAY="$DISPLAY" xwd -root -silent 2>/dev/null | md5sum)
  [ "$h1" != "$h2" ] && ok "display is animating (frame differs after 2s)" \
                     || bad "two root captures are identical — nothing is being drawn"
fi

if [ "$fail" -eq 0 ]; then printf 'x11-canvas smoke: PASS\n'; else printf 'x11-canvas smoke: %d FAILURE(S)\n' "$fail"; fi
exit $(( fail > 0 ))
