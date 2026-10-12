#!/usr/bin/env bash
#
# x11-canvas-selftest — run the entrypoint through every mode it claims to
# support and assert the observable behaviour. This is the refactor guard:
# after you swap APP=xclock for APP=your-thing, or change the VNC/web args,
# this is what tells you the chain is still a chain.
#
#   ./selftest.sh                  # from a checkout (needs the apt packages, see Dockerfile)
#   docker run --rm x11-canvas /usr/local/bin/x11-canvas-selftest
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Works both from a checkout and from the installed image, where the scripts are
# renamed (x11-canvas-entrypoint / x11-canvas-smoke in /usr/local/bin).
_pick() {
  [ -e "$1" ] && {
    printf '%s' "$1"
    return
  }
  command -v "$2" || printf '%s' "$1"
}
ENTRY="${X11_ENTRY:-$(_pick "$HERE/entrypoint.sh" x11-canvas-entrypoint)}"
SMOKE="${X11_SMOKE:-$(_pick "$HERE/smoke.sh" x11-canvas-smoke)}"
WORK="$(mktemp -d)"
NOVNC_ROOT="${NOVNC_ROOT:-/usr/share/novnc}"
pass=0 fail=0 n=0
LOG="" EPID=""

cleanup_work() {
  [ -n "$EPID" ] && kill -KILL "$EPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup_work EXIT

hdr() { printf '\n\033[1m# %s\033[0m\n' "$*"; }
ok() {
  printf '  ok   %s\n' "$*"
  pass=$((pass + 1))
}
bad() {
  printf '  FAIL %s\n' "$*"
  fail=$((fail + 1))
}

# start <name> <timeout_s> <ENV=VAL...>   -> 0 once "ready:" appears
start() {
  local name="$1" tmo="$2"
  shift 2
  n=$((n + 1))
  LOG="$WORK/$name.log"
  # Remember which display this case asked for, so stop() can reclaim it.
  printf '%s\n' "$*" | tr ' ' '\n' | sed -n 's/^DISPLAY=//p' >"$WORK/$name.disp"
  local pre_d
  pre_d="$(cat "$WORK/$name.disp" 2>/dev/null)"
  if [ -n "$pre_d" ] && DISPLAY="$pre_d" xdpyinfo >/dev/null 2>&1; then
    bad "$name: display $pre_d was already live before the case started"
    return 1
  fi
  # Deliberately NOT setsid: the entrypoint then does not lead our process group,
  # which exercises its "only kill what I spawned" cleanup branch. Inside a
  # container it *is* the group leader (PID 1) and takes the group-kill branch.
  (
    env NOVNC_ROOT="$NOVNC_ROOT" "$@" bash "$ENTRY" >"$LOG" 2>&1 &
    echo "$!" >"$WORK/$name.epid"
  )
  EPID="$(cat "$WORK/$name.epid")"
  for ((i = 0; i < tmo * 4; i++)); do
    grep -qa "x11-canvas: ready:" "$LOG" 2>/dev/null && return 0
    kill -0 "$EPID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

stop() {
  local name="$1" disp p xnum
  disp="$(cat "$WORK/$name.disp" 2>/dev/null)"
  [ -n "$EPID" ] || {
    [ -n "$disp" ] && reclaim "$name" "$disp"
    return 0
  }
  kill -TERM "$EPID" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do
    kill -0 "$EPID" 2>/dev/null || break
    sleep 0.25
  done
  kill -0 "$EPID" 2>/dev/null && {
    kill -KILL "$EPID" 2>/dev/null
    bad "$name did not exit on SIGTERM"
  }

  EPID=""
  reclaim "$name" "$disp"
}

# Belt and braces: anything still attached to that display gets removed, and the
# lock/socket go with it, so the next scenario starts from a clean X number.
reclaim() {
  local name="$1" disp="$2" p xnum rdir kids="" alive="" st
  [ -n "$disp" ] || return 0
  xnum="${disp#:}"
  rdir="/tmp/x11-canvas/${xnum}"
  # The entrypoint records every child here, so this reclaims — and measures —
  # exactly what this case spawned. No pattern guessing, no other scenario.
  kids="$(cat "$rdir"/*.pid 2>/dev/null)"
  printf '%s\n' $kids >>"$WORK/all.kids"
  for p in $kids; do kill -KILL "$p" 2>/dev/null; done
  sleep 0.5
  for p in $kids; do
    st=$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')
    # a zombie (Z) is already dead and just unreaped; anything else is a leak
    case "$st" in '' | Z*) ;; *) alive="$alive $p($(ps -o comm= -p "$p" 2>/dev/null))" ;; esac
  done
  if [ -n "$alive" ]; then
    bad "$name: children outlived the entrypoint ->$alive"
  else
    ok "$name: no children leaked"
  fi
  rm -rf "$rdir"
  rm -f "/tmp/.X${xnum}-lock" "/tmp/.X11-unix/X${xnum}" 2>/dev/null
}

greplog() { grep -qE -- "$1" "$LOG" 2>/dev/null; }

printf 'x11-canvas selftest  (entry=%s)\n' "$ENTRY"

# ---------------------------------------------------------------- default mode
hdr "default: WM=openbox + xclock, full chain"
if start default 30 DISPLAY=:91 VNC_PORT=5991 WEB_PORT=6091 SCREEN=1600x900x24; then
  ok "reached ready state"
  DISPLAY=:91 VNC_PORT=5991 WEB_PORT=6091 SCREEN=1600x900x24 \
    SMOKE_REQUIRE_ANIMATION=true bash "$SMOKE" | sed 's/^/       /'
  ok "smoke ran (its own ok/FAIL lines are above)"
  greplog 'started wm \[openbox\]' && ok "window manager started" || bad "no openbox child"
  greplog 'x11vnc .*-forever -shared' && ok "x11vnc has -forever -shared" || bad "x11vnc missing -forever/-shared"
  greplog 'RFB is UNAUTHENTICATED' && ok "warned about open RFB (no password)" || bad "no open-RFB warning"
  greplog 'websockify --web /usr/share/novnc 0.0.0.0:6091 localhost:5991' &&
    ok "websockify: --web + listen + target in that order" || bad "websockify argv wrong: $(grep -o 'started web .*' "$LOG")"
  stop default
else
  bad "never became ready: $(tail -3 "$LOG" 2>/dev/null | tr '\n' ' ')"
  stop default
fi

# ------------------------------------------------------------------ no WM mode
hdr "WM=none: the literal 4-process chain (Xvfb -> x11vnc -> websockify -> canvas)"
if start nowm 30 DISPLAY=:92 VNC_PORT=5992 WEB_PORT=6092 WM=none APP="xclock -update 1"; then
  ok "reached ready with no window manager"
  greplog 'WM=none: no window manager' && ok "logged the no-WM notice" || bad "no WM=none notice"
  greplog 'started wm \[' && bad "started a WM despite WM=none" || ok "no WM child"
  stop nowm
else
  bad "WM=none failed to come up"
  stop nowm
fi

# ----------------------------------------------------------- port plumbing
hdr "WEB_PORT/VNC_PORT are honoured (the bug class)"
if start ports 30 DISPLAY=:93 VNC_PORT=5993 WEB_PORT=6099 ROOT_COLOR="#000000"; then
  greplog '0.0.0.0:6099 localhost:5993' && ok "listening on the requested 6099 -> 5993" || bad "ports not plumbed through"
  # The regression: a custom web port silently stayed on 6080.
  if bash -c 'exec 3<>/dev/tcp/127.0.0.1/6080' 2>/dev/null; then
    bad "6080 is also listening — WEB_PORT was ignored (novnc_proxy --listen bug)"
  else
    ok "6080 is NOT listening: the custom port replaced the default, it did not just add to it"
  fi
  stop ports
else
  bad "custom ports never came up"
  stop ports
fi

# ------------------------------------------------------------------ cropping
hdr "VNC_WINDOW: stream one window instead of the whole screen"
if start crop 40 DISPLAY=:94 VNC_PORT=5994 WEB_PORT=6094 VNC_WINDOW=xclock; then
  greplog 'cropping to window id [0-9]+' &&
    ok "resolved a window id and passed -id" ||
    bad "no crop: $(grep -ao 'no window matched.*' "$LOG" | head -1)"
  # Hard evidence that cropping is real: x11vnc's own framebuffer stride.
  # A 164px-wide xclock => 656 bytes/line; the 1600px screen would be 6400.
  if grep -qa 'fb_Bpl 24/32/656' "$LOG"; then
    ok "x11vnc framebuffer shrank to the window (stride 656 B/line, not 6400)"
  else
    bad "stride is not 656, crop did not take effect: $(grep -ao 'fb_Bpl [0-9/]*' "$LOG" | head -1)"
  fi
  stop crop
else
  bad "crop mode never came up"
  stop crop
fi

# ------------------------------------------------------------- app lifecycle
hdr "EXIT_ON_APP_EXIT=true: the app finishing ends the container (CI-shaped)"
# Run this case under `setsid -w` on purpose: it makes the entrypoint a process
# group leader exactly like PID 1 in a container, and lets us read its exit
# status (a plain backgrounded child gets reparented and is unwaitable here).
(env NOVNC_ROOT="$NOVNC_ROOT" DISPLAY=:95 VNC_PORT=5995 WEB_PORT=6095 \
  APP="sleep 6" EXIT_ON_APP_EXIT=true setsid -w bash "$ENTRY" \
  >"$WORK/appexit.log" 2>&1) &
APID=$!
ready=0
for _ in $(seq 1 120); do
  grep -qa "x11-canvas: ready:" "$WORK/appexit.log" 2>/dev/null && {
    ready=1
    break
  }
  kill -0 "$APID" 2>/dev/null || break
  sleep 0.25
done
[ "$ready" = 1 ] && ok "came up as a group leader (container-exact path)" || bad "appexit: never became ready"
for _ in $(seq 1 160); do
  kill -0 "$APID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$APID" 2>/dev/null; then
  bad "entrypoint outlived its app"
  kill -KILL "$APID" 2>/dev/null
else
  wait "$APID"
  app_rc=$?
  [ "$app_rc" = 0 ] && ok "container exit status is the app's 0, not the 143 of our own shutdown" ||
    bad "container exit status '$app_rc', expected the app's 0"
fi
grep -qE 'app exited \(status' "$WORK/appexit.log" && ok "logged the app's exit status" || bad "no app-exit line"
LOG="$WORK/appexit.log"
# this case bypasses start(), so record its display by hand for stop()/reclaim()
printf '%s\n' ":95" >"$WORK/appexit.disp"
stop appexit

hdr "EXIT_ON_APP_EXIT=false: keep the canvas up after the app goes (keep_alive, made explicit)"
if start keepalive 30 DISPLAY=:96 VNC_PORT=5996 WEB_PORT=6096 APP="xclock -update 1" EXIT_ON_APP_EXIT=false; then
  pkill -U "$(id -u)" -f '^xclock -update 1$' 2>/dev/null
  sleep 1.5
  if kill -0 "$EPID" 2>/dev/null; then
    ok "still alive with the app gone"
    bash -c 'exec 3<>/dev/tcp/127.0.0.1/6096' 2>/dev/null && ok "canvas still serving on 6096" || bad "web stopped serving"
  else
    bad "entrypoint died with the app despite EXIT_ON_APP_EXIT=false"
  fi
  stop keepalive
else
  bad "keepalive case never came up"
  stop keepalive
fi

# -------------------------------------------------------------------- authn
hdr "VNC_PASSWORD: x11vnc must advertise VNC auth, not 'None'"
if start pass 30 DISPLAY=:97 VNC_PORT=5997 WEB_PORT=6097 VNC_PASSWORD=sekret; then
  greplog '\-rfbauth ' && ok "used -rfbauth (not -nopw)" || bad "no -rfbauth in argv"
  sec=$(
    python3 - 5997 <<'PYEOF'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
banner = s.recv(12)                     # "RFB 003.008\n"
if not banner.startswith(b"RFB "):
    print("no-banner"); sys.exit(0)
s.sendall(b"RFB 003.008\n")             # 3.8: SecurityTypes only follow our version
n = s.recv(1)[0]
print(",".join(str(b) for b in s.recv(n)))
PYEOF
  )
  case "$sec" in
  *2*) ok "server offers security type 2 (VNC auth) — types: $sec" ;;
  *) bad "security types are '$sec'; 2 (VNC auth) expected" ;;
  esac
  stop pass
else
  bad "password mode never came up"
  stop pass
fi

# ------------------------------------------------------------------ recording
hdr "RECORD: websockify session recording (the flag never wired up)"
if start rec 30 DISPLAY=:98 VNC_PORT=5998 WEB_PORT=6098 RECORD="$WORK/session"; then
  greplog '\-\-record [^ ]*session' && ok "--record passed to websockify" || bad "--record missing: $(grep -o 'started web .*' "$LOG")"
  stop rec
else
  bad "recording mode never came up"
  stop rec
fi

# ------------------------------------------------------------- error paths
hdr "misconfiguration must fail loudly, not hang"
if start broken 15 DISPLAY=:90 VNC_PORT=5990 WEB_PORT=6090 NOVNC_ROOT=/nonexistent-no-such-dir; then
  bad "started with a bogus NOVNC_ROOT — should have died"
else
  greplog 'FATAL: no vnc\.html' && ok "died with a clear FATAL on bad NOVNC_ROOT" || bad "died, but not with the expected message: $(tail -2 "$LOG")"
fi
stop broken 2>/dev/null || true

hdr "SIGTERM leaves no stale X lock (so a restart can rebind :99)"
if start lock 30 DISPLAY=:89 VNC_PORT=5989 WEB_PORT=6089; then
  [ -e /tmp/.X89-lock ] && ok "lock exists while running" || bad "no lock while running"
  stop lock
  [ -e /tmp/.X89-lock ] && bad "stale /tmp/.X89-lock left behind" || ok "lock cleaned up on shutdown"
else
  bad "lock case never came up"
  stop lock
fi

printf '\n\033[1m# leak check\033[0m\n'
# The whole point of doing cleanup ourselves instead of with supervisor: if a
# child outlives the entrypoint, the container "restarts" into a display/port
# that is already taken. This is the assertion that caught that bug.
# Patterns are anchored on the exact display numbers this suite uses, so they
# cannot match the invoking shell's own command line (which a loose "websockify"
# pattern happily does).
# Every pid we ever recorded must be gone. Precise: unaffected by unrelated
# processes (or leftovers from a previous run) that merely look like ours.
leaked=""
still=""
for p in $(sort -u "$WORK/all.kids" 2>/dev/null); do
  st=$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')
  case "$st" in '' | Z*) ;; *)
    leaked="$leaked $p"
    still="$still $p:$(ps -o args= -p "$p" 2>/dev/null | cut -c1-60)"
    ;;
  esac
done
if [ -z "$leaked" ]; then
  ok "every pid the suite created is dead ($(sort -u "$WORK/all.kids" 2>/dev/null | wc -l) tracked)"
else
  bad "still alive after shutdown:$still"
fi
# and no X server should still hold a suite display
leaked=$(pgrep -f "Xvfb :(89|9[0-8]) " 2>/dev/null | wc -l)
[ "${leaked:-0}" -eq 0 ] && ok "no Xvfb left on any display this suite used" ||
  bad "$leaked Xvfb still alive on a suite display"

printf '\n\033[1mselftest: %d passed, %d failed across %d scenarios\033[0m\n' "$pass" "$fail" "$n"
[ "$fail" -eq 0 ]
