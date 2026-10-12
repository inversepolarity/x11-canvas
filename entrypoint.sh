#!/usr/bin/env bash
#
# x11-canvas entrypoint — the bare chain:  Xvfb → [wm] → [app] → x11vnc → websockify → browser
#
# Everything below is driven by env vars (see README). There is no supervisor and
# no Android; PID 1 is this script, which supervises up to 5 children itself.
#
# Contract with the caller:
#   - if a FATAL child dies, we exit (and the container exits) with that status
#   - if the APP dies, we either exit (default) or keep the desktop serving
#   - on TERM/INT we take the whole process group down with us, no orphans
#
set -uo pipefail

# ---------- configuration ----------------------------------------------------
# DISPLAY is the standard X variable and the one you should set; DISPLAY_NUM is
# accepted as an override for callers that prefer to be explicit. (Getting this
# wrong is the single most common way to mis-configure an X stack: the entrypoint
# used to read only DISPLAY_NUM, so a caller setting DISPLAY silently got :99.)
: "${DISPLAY:=:99}"
: "${DISPLAY_NUM:=$DISPLAY}"
: "${SCREEN:=1600x900x24}"                 # WxHxDEPTH — this IS the browser viewport
: "${WM:=openbox}"                         # openbox | none (none => 4-process minimal chain)
: "${APP:=xclock -update 1}"               # shell command line to display, or "none"
                                           # (-update 1 so the canvas visibly ticks:
                                           #  it makes the frame-diff liveness check meaningful)
: "${VNC_PORT:=5900}"
: "${WEB_PORT:=6080}"
: "${WEB_BIND:=0.0.0.0}"                   # "" => bind all (websockify default)
: "${NOVNC_ROOT:=/usr/share/novnc}"         # dir containing vnc.html
: "${VNC_PASSWORD:=}"                       # empty => -nopw (open RFB, no auth)
: "${VNC_WINDOW:=}"                         # WM_CLASS/name regex => stream only that window
: "${VNC_EXTRA:=}"                          # raw passthrough, e.g. "-ncache 10 -defer 40"
: "${ROOT_COLOR:=}"                         # e.g. "#111111"; uses xsetroot if set
: "${XVFB_EXTRA:=}"
: "${RECORD:=}"                             # FILE => websockify --record (VNC session replay)
: "${EXIT_ON_APP_EXIT:=true}"
: "${READY_TIMEOUT:=30}"                    # seconds to wait for each stage
: "${CROP_TIMEOUT:=10}"                     # separate, shorter: a missing window
                                            # must not stall the whole chain

# Parse "WxHxD" once; used for the crop's bytes/frame comparison and by websockify.
SCREEN_W="${SCREEN%%x*}"
_screen_rest="${SCREEN#*x}"
SCREEN_H="${_screen_rest%%x*}"
case "$SCREEN_W$SCREEN_H" in
  ''|*[!0-9]*) SCREEN_FULL_BYTES="?" ;;
  *)           SCREEN_FULL_BYTES=$(( SCREEN_W * SCREEN_H * 4 )) ;;
esac

XNUM="${DISPLAY_NUM#:}"
XSOCK="/tmp/.X11-unix/X${XNUM}"
# Scoped by display number, NOT fixed: with a shared directory, two instances on
# one host overwrite each other's <name>.pid files, and then cleanup can only
# kill the most recent instance's children — the older one leaks (websockify in
# particular, since it is not on the Xvfb/x11vnc command line that a pattern
# based kill would catch). Set RUN_DIR to override.
RUN_DIR="${RUN_DIR:-/tmp/x11-canvas/${XNUM}}"
export DISPLAY="$DISPLAY_NUM"

# Split the raw passthrough flag strings once, up front. `read -a` (rather than
# an unquoted $VAR) means a glob char inside them can't expand against $PWD.
IFS=' ' read -ra XVFB_EXTRA_ARR <<<"${XVFB_EXTRA:-}"
IFS=' ' read -ra VNC_EXTRA_ARR  <<<"${VNC_EXTRA:-}"

mkdir -p "$RUN_DIR"

log() { printf 'x11-canvas: %s\n' "$*"; }
die() { log "FATAL: $*"; kill -TERM "$$" 2>/dev/null || true; exit 1; }

# ---------- process supervision (deliberately ~20 lines, not supervisor) ----
# Each child is wrapped in a subshell that waits on it and reports its status,
# because a plain `wait` in the main shell can't tell WHICH child exited.
#
# Children are put in their own process group (setsid) so that cleanup can
# signal a whole subtree with `kill -- -PID` — which reaches grandchildren such
# as `bash -c "a && b"` — without touching this script. `kill 0` is NOT usable
# here: when this script is the group leader (PID 1 in a container) that signal
# includes itself, and it then dies mid-cleanup before escalating to SIGKILL.
SETSID=""
command -v setsid >/dev/null 2>&1 && SETSID=setsid

spawn() {                       # spawn <name> <fatal|nonfatal> <cmd...>
  local name="$1" fatal="$2"; shift 2
  (
    # shellcheck disable=SC2086  # SETSID is intentionally one word or none
    $SETSID "$@" &
    local pid=$!
    printf '%s\n' "$pid" > "$RUN_DIR/$name.pid"
    wait "$pid"
    local rc=$?
    printf '%s\n' "$rc" > "$RUN_DIR/$name.exit"
    log "$name exited (status $rc)"
    # $$ in a subshell is still the main script's PID — that's what we want.
    [ "$fatal" = fatal ] && kill -TERM "$$" 2>/dev/null
  ) &
  log "started $name [$*]"
}

kill_tree() {                   # kill_tree <sig>
  local sig="$1" f p
  for f in "$RUN_DIR"/*.pid; do
    [ -e "$f" ] || continue
    p=$(cat "$f" 2>/dev/null) || continue
    [ -n "$p" ] || continue
    kill "-$sig" -- "-$p" 2>/dev/null || kill "-$sig" "$p" 2>/dev/null || true
  done
}

SHUTTING_DOWN=0
cleanup() {
  # Re-entrancy matters: every fatal child sends us SIGTERM, and cleanup() itself
  # signals the rest, so a second TERM will arrive while we are in here. `trap -`
  # would restore the DEFAULT action and kill us mid-cleanup (exit 143, leaking
  # websockify) — so disarm by IGNORING the signals, and guard the body.
  [ "$SHUTTING_DOWN" = 1 ] && return 0
  SHUTTING_DOWN=1
  trap '' TERM INT HUP
  log "shutting down"
  kill_tree TERM
  sleep 1
  # websockify does not exit on SIGTERM, so escalation is not optional.
  kill_tree KILL
  rm -f "/tmp/.X${XNUM}-lock" "$XSOCK" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

wait_until() {                  # wait_until <what> <cmd...>
  local what="$1"; shift
  local i
  for ((i = 0; i < READY_TIMEOUT * 4; i++)); do
    if "$@"; then return 0; fi
    sleep 0.25
  done
  die "timed out (${READY_TIMEOUT}s) waiting for $what"
}

have_tcp() { bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# ---------- 1. Xvfb: the display --------------------------------------------
# Two different situations, opposite handling, and worth telling apart:
#   live server on this display  => die loudly. Starting a second one just makes
#                                  Xvfb refuse, and everything then silently shares
#                                  the first server (and shares its apps).
#   lock/socket with no server   => leftovers from an unclean shutdown; clear them
#                                  or Xvfb refuses to start ("already active").
if DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1; then
  die "display $DISPLAY_NUM is already live; run this container with a different DISPLAY"
fi
if [ -e "/tmp/.X${XNUM}-lock" ] || [ -e "$XSOCK" ]; then
  log "clearing stale X lock/socket for $DISPLAY_NUM"
  rm -f "/tmp/.X${XNUM}-lock" "$XSOCK"
fi
spawn xvfb fatal Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp "${XVFB_EXTRA_ARR[@]}"
wait_until "X socket $XSOCK" test -e "$XSOCK"

# ---------- 2. root window ---------------------------------------------------
if [ -n "$ROOT_COLOR" ]; then
  xsetroot -display "$DISPLAY" -solid "$ROOT_COLOR" 2>/dev/null \
    || log "xsetroot unavailable; ignoring ROOT_COLOR"
fi

# ---------- 3. window manager ------------------------------------------------
if [ "$WM" != none ]; then
  spawn wm fatal "$WM"
else
  log "WM=none: no window manager (apps will be undecorated and unmanaged)"
fi

# ---------- 4. the payload ---------------------------------------------------
if [ "$APP" != none ]; then
  # `bash -c` so callers can write pipelines/args; for a simple command bash
  # exec's it, so the PID we supervise *is* the app's.
  case "$EXIT_ON_APP_EXIT" in
    true|1|yes) spawn app fatal bash -c "$APP" ;;
    *)          spawn app nonfatal bash -c "$APP" ;;
  esac
fi

# ---------- 5. x11vnc: X → RFB -----------------------------------------------
# -forever: survive client disconnects (a container must not exit on logout)
# -shared : let a second viewer attach while the first is connected
vnc_args=(-display "$DISPLAY" -forever -shared -rfbport "$VNC_PORT")
if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -storepasswd "$VNC_PASSWORD" "$RUN_DIR/.vncpass" >/dev/null 2>&1 \
    || die "x11vnc -storepasswd failed"
  vnc_args+=(-rfbauth "$RUN_DIR/.vncpass")
else
  vnc_args+=(-nopw)
  log "VNC_PASSWORD unset: RFB is UNAUTHENTICATED on :$VNC_PORT"
fi

# Optional crop: stream one window instead of the whole screen. Removes the
# dead space around a small app AND shrinks every frame that gets encoded.
if [ -n "$VNC_WINDOW" ]; then
  log "waiting for a window matching /$VNC_WINDOW/ to crop to"
  win="" best="" bestarea=0
  for ((i = 0; i < CROP_TIMEOUT * 4; i++)); do
    best="" bestarea=0
    # Match on class then name; prefer the biggest hit.
    # NB: do NOT gate on visibility here. `xdotool --onlyvisible` and
    # `xwininfo -id <client> -> Map State` both report the *client* window of a
    # reparented app as unmapped even though it is on screen, so either gate
    # silently disables cropping. Geometry area is the reliable signal, and
    # x11vnc -id on that client window does crop (verified: fb bytes-per-line
    # drops from 6400 to 656 for a 164px xclock).
    for cand in $(xdotool search --class "$VNC_WINDOW" 2>/dev/null) \
                 $(xdotool search --name  "$VNC_WINDOW" 2>/dev/null); do
      g=$(xdotool getwindowgeometry "$cand" 2>/dev/null \
          | sed -n 's/^[[:space:]]*Geometry: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p')
      [ -n "$g" ] || continue
      read -r w h <<<"$g"
      area=$(( w * h ))
      if [ "$area" -gt "$bestarea" ]; then bestarea=$area; best="$cand"; fi
    done
    [ "$bestarea" -gt 1 ] && { win="$best"; break; }
    sleep 0.25
  done
  if [ -n "$win" ]; then
    vnc_args+=(-id "$win")
    log "cropping to window id $win: ${w}x${h} = $(( w * h * 4 )) bytes/frame (full screen would be ${SCREEN_FULL_BYTES})"
  else
    log "no window matched VNC_WINDOW=$VNC_WINDOW; streaming full $SCREEN"
  fi
fi

[ ${#VNC_EXTRA_ARR[@]} -gt 0 ] && vnc_args+=("${VNC_EXTRA_ARR[@]}")
spawn vnc fatal x11vnc "${vnc_args[@]}"
wait_until "VNC port $VNC_PORT" have_tcp "$VNC_PORT"

# ---------- 6. websockify: RFB → WebSocket + static noVNC JS -----------------
# Called directly rather than via noVNC's novnc_proxy wrapper: the wrapper's
# argument parser only honours `--listen`, which is a known footgun (see README).
web_args=(--web "$NOVNC_ROOT")
[ -n "$RECORD" ] && web_args+=(--record "$RECORD")
[ -n "$WEB_BIND" ] && listen="${WEB_BIND}:${WEB_PORT}" || listen="$WEB_PORT"
web_args+=("$listen" "localhost:${VNC_PORT}")

[ -e "$NOVNC_ROOT/vnc.html" ] || die "no vnc.html in NOVNC_ROOT=$NOVNC_ROOT"
# Bare http://host:PORT/ should land in the viewer, not a landing page.
[ -e "$NOVNC_ROOT/index.html" ] || ln -s vnc.html "$NOVNC_ROOT/index.html" 2>/dev/null || true

spawn web fatal websockify "${web_args[@]}"
wait_until "web port $WEB_PORT" have_tcp "$WEB_PORT"

log "ready:  http://localhost:${WEB_PORT}/vnc.html?autoconnect=true"
log "        raw VNC on :${VNC_PORT}   |   screen ${SCREEN} on ${DISPLAY}"

# Block until a child exits; the fatal ones do this via kill -TERM $$.
rc=0
wait || rc=$?
# If our own shutdown signal ended the wait, report what the *payload* did
# instead: a CI job wants the container's exit code to be the app's, not 143.
# Real infrastructure failures still surface, because we only substitute when
# the wait was interrupted by a signal (>=128) and the app recorded a status.
if [ "$rc" -ge 128 ] && [ -f "$RUN_DIR/app.exit" ]; then
  apprc=$(cat "$RUN_DIR/app.exit" 2>/dev/null || echo "")
  [ -n "$apprc" ] && rc="$apprc"
fi
exit "$rc"
