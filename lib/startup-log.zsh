# startup-log — per-phase shell startup timing, written on the first prompt.
#
# Records how long each phase of .zshrc took and appends one line per shell to
# a log file. The measurement ends at the first prompt, not at the end of
# .zshrc, so theme initialisation is included.
#
# API
#   boot_kit_timer_start          start the clock (idempotent; see note below)
#   boot_kit_mark <phase>         stamp a phase boundary
#   boot_kit_exclude <t0>         subtract elapsed-since-t0 from the total
#   boot_kit_log_on_first_prompt  register the precmd hook that writes the log
#
# Deferred loading. A plugin manager that loads some plugins after the first
# prompt (zinit Turbo) makes the first prompt an incomplete measure. Set
# ZSH_BOOT_KIT_LOG_AFTER to the name of a phase you mark once that deferred
# work is done, e.g. from the last plugin's atload:
#
#     ZSH_BOOT_KIT_LOG_AFTER=ready
#     boot_kit_log_on_first_prompt
#     ...
#     zinit ... atload'boot_kit_mark ready' the/last-plugin
#
# The first prompt is then recorded as its own "prompt=" phase, "ready=" is
# the deferred work, and the total runs to the ready mark. If that mark never
# arrives, the line is written on the second prompt instead so nothing is lost.
#
# Accuracy note: the clock should start before anything else in .zshrc,
# including sourcing this file. Set ZSH_BOOT_KIT_T0 yourself at the very top:
#
#     zmodload zsh/datetime
#     ZSH_BOOT_KIT_T0=$EPOCHREALTIME
#
# boot_kit_timer_start honours an already-set ZSH_BOOT_KIT_T0 and only falls
# back to "now" when it is unset, which undercounts by however long the
# preceding lines took.

zmodload zsh/datetime
autoload -Uz add-zsh-hook

: ${ZSH_BOOT_KIT_LOG:=${HOME}/.local/state/zsh/startup.log}

typeset -gA _boot_kit_marks
typeset -ga _boot_kit_order
typeset -gi _boot_kit_prompt_seen=0 _boot_kit_logged=0

_boot_kit_reset() {
  # unset then re-declare, rather than `_boot_kit_marks=()`. Assigning an empty
  # literal to an associative array converts it to a normal array, and the next
  # boot_kit_mark then fails with "assignment to invalid subscript range".
  unset _boot_kit_marks _boot_kit_order
  typeset -gA _boot_kit_marks
  typeset -ga _boot_kit_order
  _boot_kit_prompt_seen=0
  _boot_kit_logged=0
}

boot_kit_timer_start() {
  : ${ZSH_BOOT_KIT_T0:=$EPOCHREALTIME}
  _boot_kit_reset
}

# Stamp a phase boundary. Phases are reported in the order they were marked.
# Marking the ZSH_BOOT_KIT_LOG_AFTER phase after the first prompt writes the
# log line; marking it before the prompt just records it, and the first-prompt
# hook writes the line as usual.
boot_kit_mark() {
  [[ -n "$1" ]] || return 1
  (( _boot_kit_logged )) && return 0
  _boot_kit_marks[$1]=$EPOCHREALTIME
  _boot_kit_order+=("$1")
  if [[ -n "$ZSH_BOOT_KIT_LOG_AFTER" && "$1" == "$ZSH_BOOT_KIT_LOG_AFTER" ]] && (( _boot_kit_prompt_seen )); then
    _boot_kit_write_log
  fi
  return 0
}

# Advance the start time so a blocking stretch does not count as boot time.
# Pass the EPOCHREALTIME value captured when the blocking section began.
# Used by outdated-banner: waiting on a y/N prompt is user time, and running
# an upgrade is network time. Neither is the shell's fault.
boot_kit_exclude() {
  local began=$1
  [[ -n "$began" ]] || return 1
  ZSH_BOOT_KIT_T0=$(( ZSH_BOOT_KIT_T0 + (EPOCHREALTIME - began) ))
}

_boot_kit_write_log() {
  local log=$ZSH_BOOT_KIT_LOG
  add-zsh-hook -d precmd _boot_kit_first_prompt
  add-zsh-hook -d precmd _boot_kit_write_log
  _boot_kit_logged=1
  mkdir -p "${log:h}" 2>/dev/null || return

  # Called directly, or as the second-prompt fallback, there may be no prompt
  # mark yet; stamp one now so the line always ends in a prompt phase.
  if (( ! ${+_boot_kit_marks[prompt]} )); then
    _boot_kit_marks[prompt]=$EPOCHREALTIME
    _boot_kit_order+=(prompt)
  fi

  # Build "phase=NNN" pairs from the marks, each measured from the previous
  # mark (or from T0 for the first one). The total runs to the last mark.
  local -a parts
  local phase prev=$ZSH_BOOT_KIT_T0
  for phase in $_boot_kit_order; do
    parts+=("${phase}=$(printf '%.0f' $(( (_boot_kit_marks[$phase] - prev) * 1000 )))")
    prev=$_boot_kit_marks[$phase]
  done

  # Total stays field 3 formatted as "NNNNms" so `startup-stats` can parse it.
  printf '%s  %4.0fms  %s\n' \
    "$(date '+%F %T')" \
    $(( (prev - ZSH_BOOT_KIT_T0) * 1000 )) \
    "${parts[*]}" >> "$log"

  unset ZSH_BOOT_KIT_T0
}

_boot_kit_first_prompt() {
  add-zsh-hook -d precmd _boot_kit_first_prompt
  _boot_kit_marks[prompt]=$EPOCHREALTIME
  _boot_kit_order+=(prompt)
  _boot_kit_prompt_seen=1
  if [[ -z "$ZSH_BOOT_KIT_LOG_AFTER" ]] || (( ${+_boot_kit_marks[$ZSH_BOOT_KIT_LOG_AFTER]} )); then
    _boot_kit_write_log
  else
    # Deferred work still pending: its mark writes the line, or the next
    # prompt does if the mark never comes.
    add-zsh-hook precmd _boot_kit_write_log
  fi
}

boot_kit_log_on_first_prompt() {
  add-zsh-hook precmd _boot_kit_first_prompt
}

# Convenience commands for reading the log back.
startup-log() { tail -${1:-20} "$ZSH_BOOT_KIT_LOG"; }

startup-stats() {
  [[ -s "$ZSH_BOOT_KIT_LOG" ]] || { print -u2 "startup-stats: no log at $ZSH_BOOT_KIT_LOG"; return 1 }
  awk '{gsub(/ms/,"",$3); ms=$3+0; sum+=ms; n++; if(ms>mx) mx=ms; if(mn==""||ms<mn) mn=ms}
       END {if(n) printf "n=%d  avg=%dms  min=%dms  max=%dms\n", n, sum/n, mn, mx}' "$ZSH_BOOT_KIT_LOG"
}
