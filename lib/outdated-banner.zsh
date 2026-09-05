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
#     --upgrade CMD    offer a y/N prompt and run CMD on yes
#     --hint TEXT      trailing parenthetical (defaults to "see <cache>")
#     --defer          collect the banner instead of prompting immediately;
#                      show it and prompt once via outdated_banner_prompt
#
#   outdated_banner_prompt
#     Print every banner collected with --defer, then ask a single y/N whether
#     to run each collected upgrade command (in the order collected).
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
#   .zshrc: the banners accumulate silently, then a single prompt asks whether
#   to run every upgrade command at once. Because the prompt is deferred it can
#   sit after env setup (fnm, pyenv, ...) that an upgrade command needs on
#   PATH, even though the banners themselves are cheap enough to run early.

zmodload zsh/datetime

# Whether this shell is one a human is watching. Split out so the test suite
# can stub it: shellspec runs non-interactively with no controlling terminal,
# which would otherwise make the entire render path untestable.
_outdated_banner_interactive() {
  [[ -o interactive ]] && [[ -t 0 ]]
}

# Accumulator for --defer. Between the outdated_banner collection calls and the
# leftover outdated_banner_prompt flush these hold the rendered lines and their
# upgrade commands. Both are per-shell, so a fresh zsh never inherits them.
typeset -ga _out_banners_line _out_banners_upgrade

outdated_banner() {
  local cache='' message='' icon='' upgrade='' hint='' count_mode=lines defer=0

  while (( $# )); do
    case $1 in
      --cache)   cache=$2;      shift 2 ;;
      --message) message=$2;    shift 2 ;;
      --icon)    icon=$2;       shift 2 ;;
      --upgrade) upgrade=$2;    shift 2 ;;
      --hint)    hint=$2;       shift 2 ;;
      --count)   count_mode=$2; shift 2 ;;
      --defer)   defer=1;       shift ;;
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

# Flush banners collected with --defer: print them all, then ask a single y/N
# whether to run every collected upgrade command (skipping any that had none).
outdated_banner_prompt() {
  _outdated_banner_interactive || return 0
  (( ${#_out_banners_line} )) || return 0

  local i
  for i in {1..${#_out_banners_line}}; do
    print -- "${_out_banners_line[$i]}"
  done

  local began=$EPOCHREALTIME reply=''
  print -n "  Update all of the above? [y/N] "
  if [[ -t 0 ]]; then
    read -k 1 reply
  else
    read -k 1 -u 0 reply
  fi
  print
  if [[ $reply == [yY] ]]; then
    for i in {1..${#_out_banners_upgrade}}; do
      [[ -n "${_out_banners_upgrade[$i]}" ]] && eval "${_out_banners_upgrade[$i]}"
    done
  fi
  (( $+functions[boot_kit_exclude] )) && boot_kit_exclude $began
  return 0
}
