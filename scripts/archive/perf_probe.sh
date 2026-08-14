#!/bin/bash
# perf_probe.sh — bounded render-performance baseline for the already-running
# Voiceour console. CPU proxy rows are always retained; Animation Hitches is
# fail-closed and is never reported unless capture and XML export fully validate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="$SCRIPT_DIR/perf_probe_helper.swift"
OUT="${PERF_PROBE_OUT:-/tmp/voiceour_perf_baseline.txt}"
DUR_IDLE="${DUR_IDLE:-6}"
DUR_HOVER="${DUR_HOVER:-10}"
DUR_SCROLL="${DUR_SCROLL:-10}"
XCTRACE_SECS="${XCTRACE_SECS:-8}"
MAX_DURATION=3600

validate_duration() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) printf 'ERROR: %s must be a non-negative base-10 integer.\n' "$name" >&2; return 2 ;;
  esac
  if [ "${#value}" -gt 6 ]; then
    printf 'ERROR: %s exceeds the %ss safety bound.\n' "$name" "$MAX_DURATION" >&2
    return 2
  fi
  value=$((10#$value))
  if [ "$value" -gt "$MAX_DURATION" ]; then
    printf 'ERROR: %s exceeds the %ss safety bound.\n' "$name" "$MAX_DURATION" >&2
    return 2
  fi
  printf '%s' "$value"
}

# Validate before creating files, compiling, activating the app, or moving input.
DUR_IDLE="$(validate_duration DUR_IDLE "$DUR_IDLE")" || exit $?
DUR_HOVER="$(validate_duration DUR_HOVER "$DUR_HOVER")" || exit $?
DUR_SCROLL="$(validate_duration DUR_SCROLL "$DUR_SCROLL")" || exit $?
XCTRACE_SECS="$(validate_duration XCTRACE_SECS "$XCTRACE_SECS")" || exit $?

WORKDIR="$(/usr/bin/mktemp -d /tmp/voiceour_perf.XXXXXX)" || exit 1
BIN="$WORKDIR/perf_helper"
JOB_SEQUENCE=0
PENDING_PID=""
PENDING_CONTROL=""
PENDING_STATE=""
PENDING_TOKEN=""
BOUNDED_PID=""
BOUNDED_CONTROL=""
BOUNDED_STATE=""
BOUNDED_TOKEN=""
NOTIFY_PID=""
NOTIFY_CONTROL=""
NOTIFY_STATE=""
NOTIFY_JOB_TOKEN=""
SWEEP_PID=""
SWEEP_CONTROL=""
SWEEP_STATE=""
SWEEP_TOKEN=""
CURSOR_SAVED=""
CLEANED=0

log() { printf '%s\n' "$*" >&2; }

# The supervisor remains the shell's child until we acknowledge its terminal
# state. It alone owns and signals the command's process group while the command
# PID is still its unreaped child, so neither a command PID nor PGID can be
# recycled underneath cleanup. The token-bound state/control files are the
# parent/supervisor ownership capability; callers never signal a bare PID/PGID.
start_group() {
  local stdout="$1" stderr="$2" base launch_signal phase state_token i
  shift 2
  JOB_SEQUENCE=$((JOB_SEQUENCE + 1))
  base="$WORKDIR/job.$$.${JOB_SEQUENCE}.${RANDOM}"
  START_CONTROL="${base}.control"
  START_STATE="${base}.state"
  START_TOKEN="voiceour-perf-job.$$.${JOB_SEQUENCE}.${RANDOM}"
  : >"$START_CONTROL" || return 1
  : >"$START_STATE" || return 1

  # A signal may arrive between fork and $! assignment. During that tiny
  # section record it instead of exiting; ownership becomes cleanup-visible
  # immediately after the asynchronous command is created.
  launch_signal=0
  trap 'launch_signal=129' HUP
  trap 'launch_signal=130' INT
  trap 'launch_signal=143' TERM
  /usr/bin/perl -MPOSIX -e '
    use strict;
    use warnings;
    use POSIX qw(setsid WNOHANG);
    my ($control, $state, $token, $owner, @command) = @ARGV;
    my ($stop_requested, $int_grace, $term_grace) = (0, 5, 2);
    local $SIG{HUP} = sub { $stop_requested = 1 };
    local $SIG{INT} = sub { $stop_requested = 1 };
    local $SIG{TERM} = sub { $stop_requested = 1 };

    pipe(my $ready_read, my $ready_write) or die "pipe: $!";
    my $child = fork();
    defined $child or die "fork: $!";
    if ($child == 0) {
      close $ready_read;
      setsid() >= 0 or exit 126;
      print {$ready_write} "ready\n";
      close $ready_write;
      exec { $command[0] } @command;
      exit 127;
    }
    close $ready_write;
    my $ready = <$ready_read>;
    close $ready_read;

    my $publish = sub {
      my ($phase, $rc) = @_;
      my $temporary = "$state.tmp";
      open(my $output, ">", $temporary) or die "open $temporary: $!";
      print {$output} "$phase $token $rc\n";
      close($output) or die "close $temporary: $!";
      rename($temporary, $state) or die "rename $temporary: $!";
    };
    my $request_from_file = sub {
      open(my $input, "<", $control) or return "";
      my $line = <$input>;
      close($input);
      return defined($line) ? $line : "";
    };

    $publish->(defined($ready) ? "ready" : "starting", 0);
    my ($stage, $deadline) = (0, 0);
    my $status;
    while (1) {
      my $request = $request_from_file->();
      if ($request =~ /^stop\s+(\d+)\s+(\d+)/) {
        ($stop_requested, $int_grace, $term_grace) = (1, $1, $2);
      }
      $stop_requested = 1 if getppid() != $owner;

      if (!$stop_requested) {
        my $waited = waitpid($child, WNOHANG);
        if ($waited == $child) {
          $status = $?;
          last;
        }
      } elsif ($stage == 0) {
        kill "INT", $child;
        ($stage, $deadline) = (1, time() + $int_grace);
      } elsif ($stage == 1 && time() >= $deadline) {
        # The group leader is deliberately not reaped yet. Even if it exited
        # after INT, its unreaped PID pins the original PGID while descendants
        # receive TERM, preventing PGID reuse before this signal.
        kill "TERM", -$child;
        ($stage, $deadline) = (2, time() + $term_grace);
      } elsif ($stage == 2 && time() >= $deadline) {
        kill "KILL", -$child;
        waitpid($child, 0);
        $status = $?;
        last;
      }
      select(undef, undef, undef, 0.05);
    }
    my $rc = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);
    $publish->("done", $rc);

    # Do not release this supervisor PID for reuse until the owning shell has
    # observed the token-bound result and explicitly acknowledged it.
    while (getppid() == $owner) {
      last if $request_from_file->() =~ /^ack\s+\Q$token\E/;
      select(undef, undef, undef, 0.05);
    }
    exit 0;
  ' "$START_CONTROL" "$START_STATE" "$START_TOKEN" "$$" "$@" >"$stdout" 2>"$stderr" &
  PENDING_PID=$!
  PENDING_CONTROL="$START_CONTROL"
  PENDING_STATE="$START_STATE"
  PENDING_TOKEN="$START_TOKEN"
  START_PID="$PENDING_PID"
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "$launch_signal" -ne 0 ]; then exit "$launch_signal"; fi

  # Wait only for the token-bound supervisor handshake, never for a numeric
  # PID/PGID observation. PENDING_* remains owned throughout this polling.
  phase=""
  state_token=""
  i=0
  while [ "$i" -lt 20 ]; do
    if read -r phase state_token _ <"$START_STATE" 2>/dev/null &&
       [ "$state_token" = "$START_TOKEN" ]; then
      case "$phase" in ready|done) return 0 ;; esac
    fi
    /bin/sleep 0.05
    i=$((i + 1))
  done
  return 1
}

clear_pending() {
  PENDING_PID=""
  PENDING_CONTROL=""
  PENDING_STATE=""
  PENDING_TOKEN=""
}

job_running() {
  local state="$1" token="$2" phase state_token
  if read -r phase state_token _ <"$state" 2>/dev/null &&
     [ "$state_token" = "$token" ] && [ "$phase" = done ]; then
    return 1
  fi
  return 0
}

# WAIT_RC and WAIT_TIMEOUT are outputs. A completed supervisor is acknowledged
# and reaped here; until then its PID cannot be released for reuse.
wait_bounded_job() {
  local pid="$1" control="$2" state="$3" token="$4" seconds="$5"
  local deadline now phase state_token rc
  WAIT_RC=0
  WAIT_TIMEOUT=0
  deadline=$(( $(/bin/date +%s) + seconds ))
  while true; do
    if read -r phase state_token rc <"$state" 2>/dev/null &&
       [ "$state_token" = "$token" ] && [ "$phase" = done ]; then
      WAIT_RC="$rc"
      printf 'ack %s\n' "$token" >"$control" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    now="$(/bin/date +%s)"
    if [ "$now" -ge "$deadline" ]; then WAIT_TIMEOUT=1; return 124; fi
    /bin/sleep 0.1
  done
}

# Ask the still-owning supervisor to perform INT -> group TERM -> group KILL.
# If its token-bound result does not arrive in time, fail closed: do not signal
# a numeric PID whose ownership cannot be proven.
stop_and_reap() {
  local pid="$1" control="$2" state="$3" token="$4"
  local int_grace="${5:-5}" term_grace="${6:-2}"
  [ -n "$pid" ] || return 0
  printf 'stop %s %s\n' "$int_grace" "$term_grace" >"$control" 2>/dev/null || true
  if wait_bounded_job "$pid" "$control" "$state" "$token" $((int_grace + term_grace + 3)); then
    return 0
  fi
  log "ERROR: token-bound job $token did not stop within its safety bound; refusing to signal bare pid $pid"
  return 1
}

# run_bounded OUT ERR SECONDS COMMAND...; RUN_RC/RUN_TIMEOUT are outputs.
run_bounded() {
  local stdout="$1" stderr="$2" seconds="$3"
  shift 3
  RUN_RC=1
  RUN_TIMEOUT=0
  if ! start_group "$stdout" "$stderr" "$@"; then
    stop_and_reap "$START_PID" "$START_CONTROL" "$START_STATE" "$START_TOKEN" 1 1
    clear_pending
    return 1
  fi
  BOUNDED_PID="$START_PID"
  BOUNDED_CONTROL="$START_CONTROL"
  BOUNDED_STATE="$START_STATE"
  BOUNDED_TOKEN="$START_TOKEN"
  clear_pending
  if wait_bounded_job "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" "$seconds"; then
    RUN_RC="$WAIT_RC"
  else
    RUN_TIMEOUT=1
    stop_and_reap "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 5 2
    RUN_RC=124
  fi
  BOUNDED_PID=""
  BOUNDED_CONTROL=""
  BOUNDED_STATE=""
  BOUNDED_TOKEN=""
  return 0
}

restore_cursor() {
  local x y
  [ -n "$CURSOR_SAVED" ] || return 0
  read -r x y <<EOF
$CURSOR_SAVED
EOF
  if [ -n "${x:-}" ] && [ -n "${y:-}" ] && [ -x "${BIN:-}" ]; then
    "$BIN" move "$x" "$y" >/dev/null 2>&1 || true
  fi
  CURSOR_SAVED=""
}

terminate_trace_sweep() {
  if [ -n "$SWEEP_PID" ]; then
    if stop_and_reap "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" 1 1; then
      SWEEP_RC="$WAIT_RC"
    else
      SWEEP_RC=124
    fi
  fi
  SWEEP_PID=""; SWEEP_CONTROL=""; SWEEP_STATE=""; SWEEP_TOKEN=""
  restore_cursor
}

await_trace_sweep() {
  if [ -n "$SWEEP_PID" ]; then
    if wait_bounded_job "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" $((XCTRACE_SECS + 5)); then
      SWEEP_RC="$WAIT_RC"
    else
      SWEEP_RC=124
      stop_and_reap "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" 1 1
    fi
  fi
  SWEEP_PID=""; SWEEP_CONTROL=""; SWEEP_STATE=""; SWEEP_TOKEN=""
  restore_cursor
}

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  trap - EXIT HUP INT TERM
  [ -n "$PENDING_PID" ] &&
    stop_and_reap "$PENDING_PID" "$PENDING_CONTROL" "$PENDING_STATE" "$PENDING_TOKEN" 1 1
  clear_pending
  [ -n "$SWEEP_PID" ] &&
    stop_and_reap "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" 1 1
  SWEEP_PID=""; SWEEP_CONTROL=""; SWEEP_STATE=""; SWEEP_TOKEN=""
  restore_cursor
  [ -n "$NOTIFY_PID" ] &&
    stop_and_reap "$NOTIFY_PID" "$NOTIFY_CONTROL" "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN" 1 1
  NOTIFY_PID=""; NOTIFY_CONTROL=""; NOTIFY_STATE=""; NOTIFY_JOB_TOKEN=""
  [ -n "$BOUNDED_PID" ] &&
    stop_and_reap "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 5 2
  BOUNDED_PID=""; BOUNDED_CONTROL=""; BOUNDED_STATE=""; BOUNDED_TOKEN=""
  /bin/rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

APP_PID="${PERF_PROBE_APP_PID:-$(/usr/bin/pgrep -f 'Voiceour.app/Contents/MacOS/Voiceour' | /usr/bin/sed -n '1p')}"
WS_PID="${PERF_PROBE_WS_PID:-$(/usr/bin/pgrep -x WindowServer | /usr/bin/sed -n '1p')}"
case "$APP_PID" in ''|*[!0-9]*) log 'ERROR: Voiceour is not running.'; exit 1 ;; esac
case "$WS_PID" in ''|*[!0-9]*) log 'ERROR: WindowServer pid not found.'; exit 1 ;; esac
APP_IDENTITY="$(/bin/ps -o lstart= -p "$APP_PID" 2>/dev/null)"
[ -n "$APP_IDENTITY" ] || { log 'ERROR: Voiceour pid is not alive.'; exit 1; }
app_alive() {
  local identity
  /bin/kill -0 "$APP_PID" 2>/dev/null || return 1
  identity="$(/bin/ps -o lstart= -p "$APP_PID" 2>/dev/null)"
  [ -n "$identity" ] && [ "$identity" = "$APP_IDENTITY" ]
}
app_alive || { log 'ERROR: Voiceour pid is not alive.'; exit 1; }
log "app pid=$APP_PID  WindowServer pid=$WS_PID"

if [ -n "${PERF_PROBE_HELPER_BIN:-}" ]; then
  BIN="$PERF_PROBE_HELPER_BIN"
  [ -x "$BIN" ] || { log 'ERROR: PERF_PROBE_HELPER_BIN is not executable.'; exit 1; }
else
  log "compiling helper -> $BIN"
  if ! /usr/bin/swiftc -O "$HELPER_SRC" -o "$BIN" 2>"$WORKDIR/swiftc.log"; then
    log 'ERROR: swiftc failed:'; /bin/cat "$WORKDIR/swiftc.log" >&2; exit 1
  fi
fi

if ! WIN="$("$BIN" window 2>"$WORKDIR/win.err")"; then
  log "ERROR: could not locate console window: $(/bin/cat "$WORKDIR/win.err")"; exit 1
fi
read -r WX WY WW WH <<EOF
$WIN
EOF
if /usr/bin/awk "BEGIN{exit !($WW>100 && $WH>100)}"; then
  log "console window bounds: x=$WX y=$WY w=$WW h=$WH"
else
  log "ERROR: window bounds look wrong: '$WIN'"; exit 1
fi
CX="$(/usr/bin/awk "BEGIN{printf \"%.0f\", $WX + $WW/2}")"
CY="$(/usr/bin/awk "BEGIN{printf \"%.0f\", $WY + $WH/2}")"

INJECT=0
INJECTION_STATUS='NOT REQUESTED'
NEEDS_INPUT=0
if [ "$DUR_HOVER" -gt 0 ] || [ "$DUR_SCROLL" -gt 0 ] || [ "$XCTRACE_SECS" -gt 0 ]; then NEEDS_INPUT=1; fi
if [ "$NEEDS_INPUT" -eq 1 ]; then
  if [ "${PERF_PROBE_SKIP_ACTIVATE:-0}" -ne 1 ]; then
    /usr/bin/osascript -e 'tell application "Voiceour" to activate' >/dev/null 2>&1 || true
    /bin/sleep 0.6
  fi
  PRE_OUT="$("$BIN" preflight 2>/dev/null)"; PRE_RC=$?
  if [ "$PRE_RC" -eq 0 ]; then
    INJECT=1; INJECTION_STATUS="PERMITTED ($PRE_OUT)"; log "event injection: $INJECTION_STATUS"
  else
    INJECTION_STATUS="NOT PERMITTED ($PRE_OUT)"; log "event injection: $INJECTION_STATUS"
  fi
fi

sample_into() {
  local out="$1" secs="$2" n i a w
  SAMPLE_EXPECTED=$((secs * 4))
  : >"$out"
  i=0
  while [ "$i" -lt "$SAMPLE_EXPECTED" ]; do
    a="$(/bin/ps -o %cpu= -p "$APP_PID" 2>/dev/null | /usr/bin/tr -d ' ')"
    w="$(/bin/ps -o %cpu= -p "$WS_PID" 2>/dev/null | /usr/bin/tr -d ' ')"
    [ -n "$a" ] && [ -n "$w" ] && printf '%s %s\n' "$a" "$w" >>"$out"
    /bin/sleep 0.25
    i=$((i + 1))
  done
  SAMPLE_COUNT="$(/usr/bin/wc -l <"$out" | /usr/bin/tr -d ' ')"
  [ "$SAMPLE_COUNT" -eq "$SAMPLE_EXPECTED" ]
}
stat_file() {
  /usr/bin/awk -v c="$1" '{s+=$c; if($c>m)m=$c; n++} END{if(n>0) printf "%.1f %.1f",s/n,m; else printf "NA NA"}' "$2"
}

if [ "$DUR_IDLE" -eq 0 ]; then IDLE_STATUS='not run (duration zero)'; else IDLE_STATUS='ok'; fi
HOVER_STATUS='not run (duration zero)'
SCROLL_STATUS='not run (duration zero)'
log "scenario idle: sampling ${DUR_IDLE}s ..."
if ! sample_into "$WORKDIR/idle.txt" "$DUR_IDLE"; then
  IDLE_STATUS="incomplete samples ($SAMPLE_COUNT/$SAMPLE_EXPECTED)"
fi

run_input_scenario() {
  local label="$1" duration="$2"
  shift 2
  SCENARIO_STATUS='ok'
  CURSOR_SAVED="$("$BIN" cursor 2>/dev/null)"
  if ! start_group "$WORKDIR/${label}.helper.out" "$WORKDIR/${label}.helper.err" "$BIN" "$@"; then
    stop_and_reap "$START_PID" "$START_CONTROL" "$START_STATE" "$START_TOKEN" 1 1
    clear_pending
    SCENARIO_STATUS='helper launch failed'
    : >"$WORKDIR/${label}.txt"
    restore_cursor
    return
  fi
  SWEEP_PID="$START_PID"
  SWEEP_CONTROL="$START_CONTROL"
  SWEEP_STATE="$START_STATE"
  SWEEP_TOKEN="$START_TOKEN"
  clear_pending
  if ! sample_into "$WORKDIR/${label}.txt" "$duration"; then
    SCENARIO_STATUS="incomplete samples ($SAMPLE_COUNT/$SAMPLE_EXPECTED)"
  fi
  if wait_bounded_job "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" 5; then
    [ "$WAIT_RC" -eq 0 ] || SCENARIO_STATUS="helper failed (rc=$WAIT_RC)"
  else
    SCENARIO_STATUS='helper timeout'
    stop_and_reap "$SWEEP_PID" "$SWEEP_CONTROL" "$SWEEP_STATE" "$SWEEP_TOKEN" 1 1
  fi
  SWEEP_PID=""; SWEEP_CONTROL=""; SWEEP_STATE=""; SWEEP_TOKEN=""
  restore_cursor
}

: >"$WORKDIR/hover.txt"; : >"$WORKDIR/scroll.txt"
if [ "$DUR_HOVER" -gt 0 ]; then
  if [ "$INJECT" -eq 1 ]; then
    log "scenario hover: sweeping tile area for ${DUR_HOVER}s ..."
    run_input_scenario hover "$DUR_HOVER" sweep "$WX" "$WY" "$WW" "$WH" "$DUR_HOVER"
    HOVER_STATUS="$SCENARIO_STATUS"
  else HOVER_STATUS='not run (injection unavailable)'; fi
fi
if [ "$DUR_SCROLL" -gt 0 ]; then
  if [ "$INJECT" -eq 1 ]; then
    log "scenario scroll: scroll churn at ($CX,$CY) for ${DUR_SCROLL}s ..."
    run_input_scenario scroll "$DUR_SCROLL" scroll "$CX" "$CY" "$DUR_SCROLL"
    SCROLL_STATUS="$SCENARIO_STATUS"
  else SCROLL_STATUS='not run (injection unavailable)'; fi
fi

HITCHES='n/a'
XCTRACE_STATUS='disabled'
XCTRACE_PATH='n/a'
XCODE_BUILD='n/a'
XCTRACE_TEMPLATE='Animation Hitches'
XCTRACE_SCHEMA='n/a'
OBSERVED_TRACE_SECS='n/a'
TRACE="$WORKDIR/hitches.trace"

if [ "$XCTRACE_SECS" -gt 0 ]; then
  if [ "$INJECT" -ne 1 ]; then
    XCTRACE_STATUS='injection unavailable'
  else
    XCRUN="${PERF_PROBE_XCRUN:-/usr/bin/xcrun}"
    NOTIFYUTIL="${PERF_PROBE_NOTIFYUTIL:-/usr/bin/notifyutil}"
    XMLLINT="${PERF_PROBE_XMLLINT:-/usr/bin/xmllint}"
    if [ ! -x "$XCRUN" ] || [ ! -x "$NOTIFYUTIL" ] || [ ! -x "$XMLLINT" ]; then
      XCTRACE_STATUS='xctrace unavailable (required stock tool missing)'
    else
      run_bounded "$WORKDIR/find.out" "$WORKDIR/find.err" 15 "$XCRUN" --find xctrace
      if [ "$RUN_RC" -ne 0 ] || [ "$RUN_TIMEOUT" -ne 0 ]; then
        XCTRACE_STATUS='xctrace unavailable (discovery failed)'
      else
        XCTRACE_PATH="$(/usr/bin/sed -n '1p' "$WORKDIR/find.out")"
        if [ ! -x "$XCTRACE_PATH" ]; then
          XCTRACE_STATUS='xctrace unavailable (invalid resolved path)'
        else
          run_bounded "$WORKDIR/xcode.out" "$WORKDIR/xcode.err" 15 "$XCRUN" xcodebuild -version
          if [ "$RUN_RC" -eq 0 ]; then XCODE_BUILD="$(/usr/bin/tr '\n' ' ' <"$WORKDIR/xcode.out" | /usr/bin/sed 's/[[:space:]]*$//')"; else XCODE_BUILD='unknown'; fi
          run_bounded "$WORKDIR/templates.out" "$WORKDIR/templates.err" 15 "$XCTRACE_PATH" list templates
          if [ "$RUN_TIMEOUT" -ne 0 ]; then
            XCTRACE_STATUS='list templates timeout'
          elif [ "$RUN_RC" -ne 0 ]; then
            XCTRACE_STATUS="list templates failed (rc=$RUN_RC)"
          elif ! /usr/bin/awk '{$1=$1; if($0=="Animation Hitches") found=1} END{exit !found}' "$WORKDIR/templates.out"; then
            XCTRACE_STATUS='template missing: Animation Hitches'
          else
            # Activate and settle before tracing, then revalidate process/window. Never
            # activate inside the trace window, so a valid count is hover-only injection.
            if [ "${PERF_PROBE_SKIP_ACTIVATE:-0}" -ne 1 ]; then
              /usr/bin/osascript -e 'tell application "Voiceour" to activate' >/dev/null 2>&1 || true
              /bin/sleep 0.6
            fi
            TRACE_WIN="$("$BIN" window 2>/dev/null)"; TRACE_WIN_RC=$?
            if ! app_alive || [ "$TRACE_WIN_RC" -ne 0 ]; then
              XCTRACE_STATUS='app/window unavailable before record'
            else
              read -r WX WY WW WH <<EOF
$TRACE_WIN
EOF
              if ! /usr/bin/awk "BEGIN{exit !($WW>100 && $WH>100)}"; then
                XCTRACE_STATUS='app/window invalid before record'
              else
                NOTIFY_KEY="com.voiceour.perf.trace.$$.${RANDOM}"
                NOTIFY_TOKEN=$((100000 + RANDOM))
                if ! start_group "$WORKDIR/notify.out" "$WORKDIR/notify.err" "$NOTIFYUTIL" -1 "$NOTIFY_KEY"; then
                  stop_and_reap "$START_PID" "$START_CONTROL" "$START_STATE" "$START_TOKEN" 1 1
                  clear_pending
                  XCTRACE_STATUS='notify registration launch failed'
                else
                  NOTIFY_PID="$START_PID"
                  NOTIFY_CONTROL="$START_CONTROL"
                  NOTIFY_STATE="$START_STATE"
                  NOTIFY_JOB_TOKEN="$START_TOKEN"
                  clear_pending
                  HANDSHAKE=0; HANDSHAKE_DEADLINE=$(( $(/bin/date +%s) + 3 ))
                  while job_running "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN" &&
                        [ "$(/bin/date +%s)" -lt "$HANDSHAKE_DEADLINE" ]; do
                    run_bounded "$WORKDIR/state.out" "$WORKDIR/state.err" 2 "$NOTIFYUTIL" -s "$NOTIFY_KEY" "$NOTIFY_TOKEN" -g "$NOTIFY_KEY"
                    if [ "$RUN_RC" -eq 0 ] && /usr/bin/awk -v k="$NOTIFY_KEY" -v v="$NOTIFY_TOKEN" '$1==k && $2==v {ok=1} END{exit !ok}' "$WORKDIR/state.out"; then HANDSHAKE=1; break; fi
                    /bin/sleep 0.1
                  done
                  if [ "$HANDSHAKE" -ne 1 ]; then
                    XCTRACE_STATUS='notify registration failed'
                    stop_and_reap "$NOTIFY_PID" "$NOTIFY_CONTROL" "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN" 1 1
                    NOTIFY_PID=''; NOTIFY_CONTROL=''; NOTIFY_STATE=''; NOTIFY_JOB_TOKEN=''
                  else
                    log "xctrace: recording '$XCTRACE_TEMPLATE' for ${XCTRACE_SECS}s ..."
                    if ! start_group "$WORKDIR/xctrace.out" "$WORKDIR/xctrace.err" "$XCTRACE_PATH" record --template "$XCTRACE_TEMPLATE" --attach "$APP_PID" --time-limit "${XCTRACE_SECS}s" --output "$TRACE" --no-prompt --notify-tracing-started "$NOTIFY_KEY"; then
                      stop_and_reap "$START_PID" "$START_CONTROL" "$START_STATE" "$START_TOKEN" 1 1
                      clear_pending
                      XCTRACE_STATUS='record launch failed'
                    else
                      BOUNDED_PID="$START_PID"
                      BOUNDED_CONTROL="$START_CONTROL"
                      BOUNDED_STATE="$START_STATE"
                      BOUNDED_TOKEN="$START_TOKEN"
                      clear_pending
                      READY=0; STARTUP_DEADLINE=$(( $(/bin/date +%s) + 15 ))
                      while [ "$(/bin/date +%s)" -lt "$STARTUP_DEADLINE" ]; do
                        if ! job_running "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN"; then
                          wait_bounded_job "$NOTIFY_PID" "$NOTIFY_CONTROL" "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN" 1
                          NOTIFY_RC="$WAIT_RC"
                          NOTIFY_PID=''; NOTIFY_CONTROL=''; NOTIFY_STATE=''; NOTIFY_JOB_TOKEN=''
                          NOTIFY_LINE="$(/usr/bin/sed -n '1p' "$WORKDIR/notify.out")"
                          if [ "$NOTIFY_RC" -eq 0 ] && [ "$NOTIFY_LINE" = "$NOTIFY_KEY" ]; then READY=1; fi
                          break
                        fi
                        if ! job_running "$BOUNDED_STATE" "$BOUNDED_TOKEN" || ! app_alive; then break; fi
                        /bin/sleep 0.1
                      done
                      if [ "$READY" -ne 1 ]; then
                        if ! app_alive; then XCTRACE_STATUS='app exited during startup'
                        elif job_running "$BOUNDED_STATE" "$BOUNDED_TOKEN" &&
                             [ "$(/bin/date +%s)" -ge "$STARTUP_DEADLINE" ]; then XCTRACE_STATUS='startup timeout'
                        else XCTRACE_STATUS='tracing-start notification failed'
                        fi
                        [ -n "$NOTIFY_PID" ] &&
                          stop_and_reap "$NOTIFY_PID" "$NOTIFY_CONTROL" "$NOTIFY_STATE" "$NOTIFY_JOB_TOKEN" 1 1
                        NOTIFY_PID=''; NOTIFY_CONTROL=''; NOTIFY_STATE=''; NOTIFY_JOB_TOKEN=''
                        stop_and_reap "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 5 2
                        BOUNDED_PID=''; BOUNDED_CONTROL=''; BOUNDED_STATE=''; BOUNDED_TOKEN=''
                      else
                        TRACE_STARTED_AT="$(/bin/date +%s)"
                        CURSOR_SAVED="$("$BIN" cursor 2>/dev/null)"
                        if ! start_group "$WORKDIR/trace-sweep.out" "$WORKDIR/trace-sweep.err" "$BIN" sweep "$WX" "$WY" "$WW" "$WH" "$XCTRACE_SECS"; then
                          stop_and_reap "$START_PID" "$START_CONTROL" "$START_STATE" "$START_TOKEN" 1 1
                          clear_pending
                          SWEEP_RC=1
                        else
                          SWEEP_PID="$START_PID"
                          SWEEP_CONTROL="$START_CONTROL"
                          SWEEP_STATE="$START_STATE"
                          SWEEP_TOKEN="$START_TOKEN"
                          clear_pending
                          SWEEP_RC=0
                        fi
                        RECORD_DEADLINE=$(( TRACE_STARTED_AT + XCTRACE_SECS + 30 ))
                        RECORD_TIMEOUT=0; APP_DIED=0
                        while job_running "$BOUNDED_STATE" "$BOUNDED_TOKEN"; do
                          if ! app_alive; then APP_DIED=1; break; fi
                          if [ "$(/bin/date +%s)" -ge "$RECORD_DEADLINE" ]; then RECORD_TIMEOUT=1; break; fi
                          /bin/sleep 0.1
                        done
                        if [ "$APP_DIED" -eq 1 ]; then
                          XCTRACE_STATUS='app exited during record'
                          terminate_trace_sweep
                          stop_and_reap "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 5 2
                        elif [ "$RECORD_TIMEOUT" -eq 1 ]; then
                          XCTRACE_STATUS='record timeout'
                          terminate_trace_sweep
                          stop_and_reap "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 5 2
                        else
                          wait_bounded_job "$BOUNDED_PID" "$BOUNDED_CONTROL" "$BOUNDED_STATE" "$BOUNDED_TOKEN" 1
                          RECORD_RC="$WAIT_RC"
                          TRACE_ENDED_AT="$(/bin/date +%s)"
                          OBSERVED_TRACE_SECS=$((TRACE_ENDED_AT - TRACE_STARTED_AT))
                          if [ "$RECORD_RC" -ne 0 ]; then XCTRACE_STATUS="record failed (rc=$RECORD_RC)"
                          elif [ $((OBSERVED_TRACE_SECS + 1)) -lt "$XCTRACE_SECS" ]; then XCTRACE_STATUS='record ended before requested duration'
                          else XCTRACE_STATUS='recorded; validating export'
                          fi
                          if [ "$XCTRACE_STATUS" != 'recorded; validating export' ]; then
                            terminate_trace_sweep
                          fi
                        fi
                        BOUNDED_PID=''; BOUNDED_CONTROL=''; BOUNDED_STATE=''; BOUNDED_TOKEN=''

                        if [ "$XCTRACE_STATUS" = 'recorded; validating export' ]; then
                          await_trace_sweep
                          if [ "$SWEEP_RC" -ne 0 ]; then XCTRACE_STATUS="sweep failed (rc=$SWEEP_RC)"; fi
                        fi

                    if [ "$XCTRACE_STATUS" = 'recorded; validating export' ]; then
                      if [ ! -d "$TRACE" ]; then
                        XCTRACE_STATUS='record produced no trace bundle'
                      else
                        run_bounded "$WORKDIR/toc-export.out" "$WORKDIR/toc-export.err" 30 "$XCTRACE_PATH" export --input "$TRACE" --toc --output "$WORKDIR/toc.xml"
                        if [ "$RUN_TIMEOUT" -ne 0 ]; then XCTRACE_STATUS='TOC export timeout'
                        elif [ "$RUN_RC" -ne 0 ]; then XCTRACE_STATUS="TOC export failed (rc=$RUN_RC)"
                        else
                          run_bounded "$WORKDIR/xmlcheck.out" "$WORKDIR/xmlcheck.err" 10 "$XMLLINT" --noout "$WORKDIR/toc.xml"
                          if [ "$RUN_RC" -ne 0 ] || [ "$RUN_TIMEOUT" -ne 0 ]; then XCTRACE_STATUS='TOC XML malformed'
                          else
                            run_bounded "$WORKDIR/schema-hitches.out" "$WORKDIR/schema-hitches.err" 10 "$XMLLINT" --xpath 'count(/trace-toc/run[@number="1"]/data/table[@schema="hitches"])' "$WORKDIR/toc.xml"
                            HITCHES_SCHEMA_COUNT="$(/usr/bin/tr -d '[:space:]' <"$WORKDIR/schema-hitches.out")"
                            HITCHES_SCHEMA_QUERY_OK=0
                            if [ "$RUN_RC" -eq 0 ] && [ "$RUN_TIMEOUT" -eq 0 ]; then HITCHES_SCHEMA_QUERY_OK=1; fi
                            run_bounded "$WORKDIR/schema-summary.out" "$WORKDIR/schema-summary.err" 10 "$XMLLINT" --xpath 'count(/trace-toc/run[@number="1"]/data/table[@schema="hitches-summary"])' "$WORKDIR/toc.xml"
                            SUMMARY_SCHEMA_COUNT="$(/usr/bin/tr -d '[:space:]' <"$WORKDIR/schema-summary.out")"
                            SUMMARY_SCHEMA_QUERY_OK=0
                            if [ "$RUN_RC" -eq 0 ] && [ "$RUN_TIMEOUT" -eq 0 ]; then SUMMARY_SCHEMA_QUERY_OK=1; fi
                            if [ "$HITCHES_SCHEMA_QUERY_OK" -ne 1 ] || [ "$SUMMARY_SCHEMA_QUERY_OK" -ne 1 ]; then
                              XCTRACE_STATUS='hitch schema discovery failed'
                            elif [ "$HITCHES_SCHEMA_COUNT" = '1' ]; then
                              XCTRACE_SCHEMA='hitches'
                            elif [ "$SUMMARY_SCHEMA_COUNT" = '1' ]; then
                              XCTRACE_SCHEMA='hitches-summary'
                            else
                              XCTRACE_STATUS="no unique hitch schema (hitches=${HITCHES_SCHEMA_COUNT:-n/a}, hitches-summary=${SUMMARY_SCHEMA_COUNT:-n/a})"
                            fi
                            if [ "$XCTRACE_SCHEMA" != 'n/a' ]; then
                              HITCH_XPATH="/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$XCTRACE_SCHEMA\"]"
                              run_bounded "$WORKDIR/hitches-export.out" "$WORKDIR/hitches-export.err" 30 "$XCTRACE_PATH" export --input "$TRACE" --xpath "$HITCH_XPATH" --output "$WORKDIR/hitches.xml"
                              if [ "$RUN_TIMEOUT" -ne 0 ]; then XCTRACE_STATUS="$XCTRACE_SCHEMA export timeout"
                              elif [ "$RUN_RC" -ne 0 ]; then XCTRACE_STATUS="$XCTRACE_SCHEMA export failed (rc=$RUN_RC)"
                              else
                                run_bounded "$WORKDIR/hitches-check.out" "$WORKDIR/hitches-check.err" 10 "$XMLLINT" --noout "$WORKDIR/hitches.xml"
                                if [ "$RUN_RC" -ne 0 ] || [ "$RUN_TIMEOUT" -ne 0 ]; then XCTRACE_STATUS="$XCTRACE_SCHEMA XML malformed"
                                else
                                  run_bounded "$WORKDIR/row-count.out" "$WORKDIR/row-count.err" 10 "$XMLLINT" --xpath 'count(//row)' "$WORKDIR/hitches.xml"
                                  ROW_COUNT="$(/usr/bin/tr -d '[:space:]' <"$WORKDIR/row-count.out")"
                                  case "$ROW_COUNT" in
                                    ''|*[!0-9]*) XCTRACE_STATUS="invalid $XCTRACE_SCHEMA row count" ;;
                                    *) if [ "$RUN_RC" -eq 0 ] && [ "$RUN_TIMEOUT" -eq 0 ]; then HITCHES="$ROW_COUNT"; XCTRACE_STATUS='ok (validated hover injection)'; else XCTRACE_STATUS="$XCTRACE_SCHEMA row count failed"; fi ;;
                                  esac
                                fi
                              fi
                            fi
                          fi
                        fi
                      fi
                    fi
                  fi
                    fi
                  fi
                fi
              fi
            fi
          fi
        fi
      fi
    fi
  fi
fi

row() {
  local label="$1" file="$2" status="$3" app_stats ws_stats am ax wm wx samples
  app_stats="$(stat_file 1 "$file")"; ws_stats="$(stat_file 2 "$file")"
  read -r am ax <<EOF
$app_stats
EOF
  read -r wm wx <<EOF
$ws_stats
EOF
  samples="$(/usr/bin/wc -l <"$file" | /usr/bin/tr -d ' ')"
  printf '  %-8s  app: mean %5s%%  max %5s%%   |   WindowServer: mean %5s%%  max %5s%%   (n=%s; %s)\n' "$label" "$am" "$ax" "$wm" "$wx" "$samples" "$status"
}

if [ "$OBSERVED_TRACE_SECS" = 'n/a' ]; then
  OBSERVED_TRACE_DISPLAY='n/a'
else
  OBSERVED_TRACE_DISPLAY="${OBSERVED_TRACE_SECS}s"
fi

if ! {
  echo 'Voiceour render-perf baseline'
  echo "date            : $(/bin/date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "app pid         : $APP_PID    WindowServer pid: $WS_PID"
  echo "console window  : x=$WX y=$WY w=$WW h=$WH"
  echo "event injection : $INJECTION_STATUS"
  echo "xctrace status  : $XCTRACE_STATUS"
  echo "xctrace path    : $XCTRACE_PATH"
  echo "Xcode build     : $XCODE_BUILD"
  echo "trace contract  : template=$XCTRACE_TEMPLATE schema=$XCTRACE_SCHEMA requested=${XCTRACE_SECS}s observed=$OBSERVED_TRACE_DISPLAY"
  echo "durations       : idle=${DUR_IDLE}s hover=${DUR_HOVER}s scroll=${DUR_SCROLL}s xctrace=${XCTRACE_SECS}s"
  echo 'cpu source      : ps -o %cpu= (per-process, sampled ~4Hz; % is macOS ps weighted avg)'
  echo
  echo 'scenario -> CPU%:'
  row idle "$WORKDIR/idle.txt" "$IDLE_STATUS"
  row hover "$WORKDIR/hover.txt" "$HOVER_STATUS"
  row scroll "$WORKDIR/scroll.txt" "$SCROLL_STATUS"
  echo
  if [ "$HITCHES" = 'n/a' ]; then
    echo "animation hitches: n/a ($XCTRACE_STATUS)"
  else
    echo "animation hitches (validated hover injection, ${XCTRACE_SECS}s requested): $HITCHES"
  fi
} | /usr/bin/tee "$OUT"; then
  log "ERROR: failed to write baseline to $OUT"
  exit 1
fi

log "baseline written to $OUT"
exit 0
