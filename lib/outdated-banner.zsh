# outdated-banner — "N things are out of date, upgrade now?" on shell start,
# without paying for the check.
#
# The check itself never runs in your shell. A background job (launchd, cron,
# systemd timer) writes a small cache file on its own schedule; the shell only
# reads that file. Startup cost is one stat and one read regardless of how slow
# `brew update` or a `git fetch` happens to be.
#
# API
#   outdated_banner --cache PATH --message FMT [options]
#     --icon TEXT      prefix, usually an emoji
#     --count MODE     lines   count of lines in the cache file (default)
#                      content the file's contents, for a pre-computed number
#                      none    no count; FMT is used as-is
#     --upgrade CMD    offer an upgrade prompt and run CMD when chosen
#     --label TEXT     short name for CMD used by the progress view, e.g.
#                      "Homebrew packages". Defaults to the banner line.
#     --progress       CMD emits the structured progress protocol on stdout
#                      (@total/@done/@skip/@fail — see _out_run_upgrade_progress)
#                      under ZSH_BOOT_KIT_PROGRESS=1, so the UI can list each
#                      item as it lands instead of spinning blindly
#     --hint TEXT      trailing parenthetical (defaults to "see <cache>")
#     --defer          collect the banner instead of prompting immediately;
#                      show it and prompt once via outdated_banner_prompt
#
#   outdated_banner_prompt
#     Print every banner collected with --defer, then offer to run the
#     collected upgrade commands. With gum(1) on PATH and a terminal, the
#     banners render in a styled box and a single confirm asks whether to run
#     every collected upgrade (default is No, so a bare Enter skips). Each then
#     runs under its own spinner, or — for --progress entries — prints a line
#     per item as it lands, followed by a summary. Without gum the original y/N
#     prompt is used. Before either, it waits (when a background welcome
#     process was registered via _out_bg_job_start — typically fastfetch) so
#     that process's output finishes drawing before the banners, and reaps it
#     so zsh never prints a stray "[n] done" job line at the prompt.
#
#   _out_bg_job_start CMD [ARGS...]
#     Launch a background, not-disowned welcome process (e.g. fastfetch) with
#     job-control chatter suppressed: no "[n] pid" line on spawn, no immediate
#     "done" line on completion. The deferred prompt waits for it to finish
#     drawing before showing banners, then reaps it and restores the caller's
#     NOTIFY setting. Call it in place of `fastfetch &` so the PID is recorded:
#         _out_bg_job_start fastfetch
#
#   ZSH_BOOT_KIT_UI
#     "auto" (default) uses gum when installed on a terminal, "gum" forces it
#     (and falls back if absent), "plain" forces the y/N UI. Useful in tests
#     and when a wrapper around gum misbehaves.
#
# FMT is a printf format taking the count, e.g. '%s package(s) outdated'.
#
# Only fires in an interactive shell on a real TTY. Sourcing .zshrc from a
# script to pick up env vars must never block on a prompt.
#
# The prompt wait and the upgrade run are excluded from the startup timer via
# boot_kit_exclude. Waiting on a human is not shell boot time, and counting it
# makes the startup log useless on exactly the days you upgraded.
#
# Deferring several upgrades to one prompt
#   Wiring each --upgrade banner as its own call prompts once per system on
#   boot — a queue of [y/N] keystrokes. Instead pass --defer to every repeated
#   outdated_banner and call outdated_banner_prompt once at the end of
#   .zshrc: the banners accumulate silently, then one prompt covers every
#   upgrade command at once. Because the prompt is deferred it can sit after
#   env setup (fnm, pyenv, ...) that an upgrade command needs on PATH, even
#   though the banners themselves are cheap enough to run early.

zmodload zsh/datetime

# Whether this shell is one a human is watching. Split out so the test suite
# can stub it: shellspec runs non-interactively with no controlling terminal,
# which would otherwise make the entire render path untestable.
_outdated_banner_interactive() {
  [[ -o interactive ]] && [[ -t 0 ]]
}

# Accumulator for --defer. Between the outdated_banner collection calls and the
# leftover outdated_banner_prompt flush these hold the rendered lines, their
# upgrade commands, and a short label for each. All three are per-shell, so a
# fresh zsh never inherits them.
typeset -ga _out_banners_line _out_banners_upgrade _out_banners_label _out_banners_progress

# Backgrounded, not-disowned welcome process (fastfetch) whose output should
# finish drawing before the deferred prompt shows. 0 means none registered.
typeset -gi _out_bg_job=0
# Whether NOTIFY was on when that process was launched, so the reap restores it.
typeset -gi _out_bg_notify=0

# Prefer gum for the deferred UI when it is installed and stdout is a terminal.
# ZSH_BOOT_KIT_UI forces a backend: "gum" (falling back if absent) or "plain".
_out_use_gum() {
  case ${ZSH_BOOT_KIT_UI:-auto} in
    plain) return 1 ;;
    gum)   command -v gum >/dev/null 2>&1; return ;;
  esac
  [[ -t 1 ]] || return 1
  command -v gum >/dev/null 2>&1
}

# Launch a background welcome process with the job-control noise removed.
#
# A plain `fastfetch &` prints "[n] pid" when it starts and "[n] + done" when
# it finishes. Both are the interactive job table talking, not anything the
# user asked to see. MONITOR is turned off just for the launch (which suppresses
# the spawn line and still leaves the job waitable), and NOTIFY is suspended
# until the deferred prompt reaps the job — so a completion that lands during
# the rest of .zshrc is never announced.
_out_bg_job_start() {
  (( $# )) || return 0
  # MONITOR is restored immediately after the launch (the spawn line is emitted
  # during it); NOTIFY stays off until _out_reap_bg_job restores it, so a
  # completion during the rest of .zshrc is never announced. NOTIFY deliberately
  # outlives the function, which rules out `setopt local_options`.
  local had_monitor=0
  [[ -o monitor ]] && had_monitor=1
  unsetopt monitor
  if [[ -o notify ]]; then
    _out_bg_notify=1
    unsetopt notify
  else
    _out_bg_notify=0
  fi
  "$@" &
  _out_bg_job=$!
  (( had_monitor )) && setopt monitor
  return 0
}

# Record an already-running background job's PID for the deferred prompt to
# wait on. Low-level companion to _out_bg_job_start for callers that manage
# their own launch; accepts only an unsigned integer PID. Always returns
# success so callers under `set -e` are never aborted.
_out_register_bg_job() {
  # `<->` is a numeric glob that only exists under extendedglob; scope it
  # locally so validation never depends on the caller's option state, and it
  # restores the caller's setting on return.
  setopt local_options extendedglob
  if (( $# )) && [[ $1 == <-> ]]; then
    _out_bg_job=$1
  else
    _out_bg_job=0
  fi
  return 0
}

# Wait for a registered welcome process to finish drawing, then clear it so a
# later PID reuse can't make a future prompt block on an unrelated child.
#
# zsh's `wait` acts only on the shell's own child jobs: a PID for a process
# already reaped, or one reused by an unrelated process, is not a child and
# returns immediately (127) rather than blocking. `|| true` makes that a no-op
# so a reaped greeting can't abort the shell under `set -e`.
_out_reap_bg_job() {
  if (( _out_bg_job > 0 )); then
    # MONITOR is off around `wait` so reaping does not print the job-status
    # line ("[n] + done ...") zsh would otherwise emit; restored afterwards.
    local had_monitor=0
    [[ -o monitor ]] && had_monitor=1
    unsetopt monitor
    wait "$_out_bg_job" 2>/dev/null || true
    (( had_monitor )) && setopt monitor
    _out_bg_job=0
  fi
  # Restore NOTIFY if _out_bg_job_start suspended it. Done here rather than in
  # the prompt body so it happens even when there is nothing to update.
  if (( _out_bg_notify )); then
    setopt notify
    _out_bg_notify=0
  fi
  return 0
}

outdated_banner() {
  local cache='' message='' icon='' upgrade='' hint='' label='' count_mode=lines defer=0 progress=0

  while (( $# )); do
    case $1 in
      --cache)   cache=$2;      shift 2 ;;
      --message) message=$2;    shift 2 ;;
      --icon)    icon=$2;       shift 2 ;;
      --upgrade) upgrade=$2;    shift 2 ;;
      --label)   label=$2;      shift 2 ;;
      --hint)    hint=$2;       shift 2 ;;
      --count)   count_mode=$2; shift 2 ;;
      --defer)   defer=1;       shift ;;
      --progress) progress=1;   shift ;;
      *) print -u2 "outdated_banner: unknown option '$1'"; return 1 ;;
    esac
  done

  [[ -n "$cache" && -n "$message" ]] || {
    print -u2 "outdated_banner: --cache and --message are required"
    return 1
  }

  _outdated_banner_interactive || return 0
  [[ -s "$cache" ]] || return 0

  local count=''
  case $count_mode in
    lines)   count=$(( $(wc -l < "$cache" 2>/dev/null || print 0) )) ;;
    content) count=${$(<"$cache")//[[:space:]]/} ;;
    none)    ;;
    *) print -u2 "outdated_banner: unknown --count mode '$count_mode'"; return 1 ;;
  esac

  # A cache file holding a literal zero means "checked, nothing to do".
  [[ "$count" == 0 ]] && return 0

  : ${hint:=see $cache}

  local text=$message
  [[ $count_mode == none ]] || text=$(printf -- "$message" "$count")
  local line="${icon:+$icon  }${text} (${hint})"

  if (( defer )); then
    _out_banners_line+=("$line")
    _out_banners_upgrade+=("$upgrade")
    : ${label:=$text}
    _out_banners_label+=("$label")
    _out_banners_progress+=("$progress")
    return 0
  fi

  print -- "$line"

  [[ -n "$upgrade" ]] || return 0

  # When attached to a terminal, `read -k 1` puts the tty into cbreak mode so
  # single keypresses (y/n) work without pressing Enter. When stdin is a pipe
  # (such as under shellspec), read from fd 0 (-u 0) to avoid failing on the
  # absence of a controlling terminal.
  local began=$EPOCHREALTIME reply=''
  print -n "  Upgrade now? [y/N] "
  if [[ -t 0 ]]; then
    read -k 1 reply
  else
    read -k 1 -u 0 reply
  fi
  print
  if [[ $reply == [yY] ]]; then
    eval "$upgrade"
  fi
  (( $+functions[boot_kit_exclude] )) && boot_kit_exclude $began
  return 0
}

# Print the collected banners in the plain (non-gum) style: one line each.
_out_print_banners_plain() {
  local i
  for i in {1..${#_out_banners_line}}; do
    print -- "${_out_banners_line[$i]}"
  done
}

# Print the collected banners as a rounded gum box: a title, a blank line, then
# each banner.
_out_print_banners_gum() {
  {
    print -- 'Updates available'
    print
    local i
    for i in {1..${#_out_banners_line}}; do
      print -- "  ${_out_banners_line[$i]}"
    done
  } | gum style --border rounded --border-foreground 99 --padding '0 1' --margin '1 0 0 0'
}

# The original single y/N path, kept verbatim for hosts without gum.
_out_prompt_plain() {
  local reply=''
  print -n "  Update all of the above? [y/N] "
  if [[ -t 0 ]]; then
    read -k 1 reply
  else
    read -k 1 -u 0 reply
  fi
  print
  if [[ $reply == [yY] ]]; then
    local i
    for i in {1..${#_out_banners_upgrade}}; do
      [[ -n "${_out_banners_upgrade[$i]}" ]] && eval "${_out_banners_upgrade[$i]}"
    done
  fi
  return 0
}

# Run one upgrade command under a gum spinner, capturing its output to a log so
# the progress view stays clean. On failure the log path is printed for
# inspection.
_out_run_upgrade_gum() {
  local idx=$1 label=$2 log=$3 rc=0
  # `exec >log 2>&1` redirects the whole command, not just its last element: a
  # `a && b` upgrade would otherwise leak a's output onto the spinner view.
  gum spin --spinner dot --spinner.foreground 212 \
    --title "Updating ${label}…" \
    -- sh -c "exec >$(printf '%q' "$log") 2>&1; ${_out_banners_upgrade[$idx]}" || rc=$?
  if (( rc == 0 )); then
    gum style --foreground 42 "  ✔ ${label}"
  else
    gum style --foreground 196 "  ✘ ${label} (exit ${rc}) — log: ${log}"
  fi
  return 0
}

# Run an upgrade marked --progress, reading its structured progress protocol
# from stdout while everything else (and stderr) goes to the log:
#
#   @total N       how many items the run will process
#   @done  NAME    one item succeeded
#   @skip  NAME    one item was left alone (e.g. local changes)
#   @fail  NAME    one item failed
#
# Each item prints as it lands, so a long install shows a growing list instead
# of a silent spinner. The protocol is emitted by the dotfiles `*-outdated-cache`
# scripts when ZSH_BOOT_KIT_PROGRESS=1; any upgrade command can opt in.
_out_run_upgrade_progress() {
  local idx=$1 label=$2 log=$3
  local total=0 done=0 skipped=0 failed=0 line rc=1
  local rcfile="$log.rc"
  : >"$log"
  : >"$rcfile"

  while IFS= read -r line; do
    case $line in
      '@total '*) total=${line#@total } ;;
      '@done '*)  done=$((done + 1));  gum style --foreground 42  "  ✔ ${line#@done }" ;;
      '@skip '*)  skipped=$((skipped + 1)); gum style --foreground 214 "  ○ ${line#@skip } (skipped)" ;;
      '@fail '*)  failed=$((failed + 1)); gum style --foreground 196 "  ✘ ${line#@fail }" ;;
      *) print -r -- "$line" >>"$log" ;;
    esac
  done < <(_out_progress_stream "${_out_banners_upgrade[$idx]}" "$log" "$rcfile")

  [[ -s "$rcfile" ]] && rc=$(<"$rcfile")

  if (( failed > 0 || rc != 0 )); then
    local why="exit ${rc}"
    (( failed > 0 )) && why="${failed} failed"
    gum style --foreground 196 "  ✘ ${label} (${done}/${total} updated, ${why}) — log: ${log}"
  else
    (( total == 0 )) && total=$done
    local suffix=''
    (( skipped > 0 )) && suffix=", ${skipped} skipped"
    gum style --foreground 42 "  ✔ ${label} (${done}/${total} updated${suffix})"
  fi
  return 0
}

# Run the upgrade command as a child whose stdout the caller reads line by line.
# ZSH_BOOT_KIT_PROGRESS tells the dotfiles cache scripts to emit the protocol
# above instead of their human-readable list. The child's exit status is written
# to a file because process substitution hides it from the caller.
_out_progress_stream() {
  local cmd=$1 log=$2 rcfile=$3
  ZSH_BOOT_KIT_PROGRESS=1 sh -c "$cmd" 2>>"$log"
  print -r -- $? >"$rcfile"
}

# The gum path: one binary confirm (default is No, so a bare Enter skips), then
# a sequential spinner (or progress list, for --progress entries) per collected
# upgrade command.
_out_prompt_gum() {
  local -a idxs=()
  local i
  for i in {1..${#_out_banners_upgrade}}; do
    [[ -n "${_out_banners_upgrade[$i]}" ]] && idxs+=("$i")
  done

  # No banner carries an upgrade command: nothing to offer, banners already shown.
  (( ${#idxs} )) || return 0

  # --default=false makes "Skip" the selection a bare Enter commits to; a
  # negative answer (or Ctrl-C) runs nothing.
  gum confirm 'Update all of the above?' \
    --affirmative 'Update' --negative 'Skip' --default=false || return 0

  local logdir="${TMPDIR:-/tmp}/zsh-boot-kit-updates-$$"
  mkdir -p "$logdir" 2>/dev/null

  local idx name log
  for idx in "${idxs[@]}"; do
    name=${_out_banners_label[$idx]:-${_out_banners_line[$idx]}}
    log="$logdir/${idx}.log"
    if [[ ${_out_banners_progress[$idx]:-0} == 1 ]]; then
      _out_run_upgrade_progress "$idx" "$name" "$log"
    else
      _out_run_upgrade_gum "$idx" "$name" "$log"
    fi
  done
  return 0
}

# Flush banners collected with --defer: print them all, then offer to run the
# collected upgrade commands.
outdated_banner_prompt() {
  _outdated_banner_interactive || return 0

  # Reap a registered welcome process even when there is nothing to update, so
  # its job-completion line never surfaces at the prompt and a suspended NOTIFY
  # is always restored.
  _out_reap_bg_job

  (( ${#_out_banners_line} )) || return 0

  local began=$EPOCHREALTIME

  if _out_use_gum; then
    _out_print_banners_gum
    _out_prompt_gum
  else
    _out_print_banners_plain
    _out_prompt_plain
  fi

  (( $+functions[boot_kit_exclude] )) && boot_kit_exclude $began
  return 0
}
