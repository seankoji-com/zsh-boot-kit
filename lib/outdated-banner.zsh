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
#
# FMT is a printf format taking the count, e.g. '%s package(s) outdated'.
#
# Only fires in an interactive shell on a real TTY. Sourcing .zshrc from a
# script to pick up env vars must never block on a prompt.
#
# The prompt wait and the upgrade run are excluded from the startup timer via
# boot_kit_exclude. Waiting on a human is not shell boot time, and counting it
# makes the startup log useless on exactly the days you upgraded.

zmodload zsh/datetime

# Whether this shell is one a human is watching. Split out so the test suite
# can stub it: shellspec runs non-interactively with no controlling terminal,
# which would otherwise make the entire render path untestable.
_outdated_banner_interactive() {
  [[ -o interactive ]] && [[ -t 0 ]]
}

outdated_banner() {
  local cache='' message='' icon='' upgrade='' hint='' count_mode=lines

  while (( $# )); do
    case $1 in
      --cache)   cache=$2;      shift 2 ;;
      --message) message=$2;    shift 2 ;;
      --icon)    icon=$2;       shift 2 ;;
      --upgrade) upgrade=$2;    shift 2 ;;
      --hint)    hint=$2;       shift 2 ;;
      --count)   count_mode=$2; shift 2 ;;
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
  print -- "${icon:+$icon  }${text} (${hint})"

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
