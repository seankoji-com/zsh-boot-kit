# env-cache — cache an expensive environment variable in a 0600 file with a TTL.
#
# Some env vars cost a subprocess to produce, and that subprocess can stall.
# `gh auth token` blocks on a locked Keychain. `vault read` blocks on network.
# Paying that on every shell start is the wrong trade when the value is stable
# for hours. This caches the value in a mode-0600 file and re-runs the command
# only when the file is missing, stale, or fails validation.
#
# API
#   env_cache VAR --ttl SECONDS --command 'shell command' [options]
#     --file PATH        cache location (default ~/.cache/zsh/<var lowercased>)
#     --validate PATTERN glob alternation the value must match to be cached,
#                        e.g. 'gho_*|ghp_*|github_pat_*'
#     --timeout SECONDS  give up on the command after this long
#     --quiet            do not warn on failure
#
#   env_cache_invalidate VAR [--file PATH]
#     Remove the cache file so the next shell refetches. Call this after
#     rotating the underlying credential.
#
# The cache file is plaintext. That is a deliberate trade: 0600 in a
# user-owned directory, in exchange for skipping a subprocess per shell. If
# the value is sensitive enough that plaintext-at-rest is unacceptable, do not
# use this.
#
# Before reading a cache file, env_cache checks that it is a regular file (not
# a symlink someone planted), that you own it, and that it is mode 0600. A
# file failing any of those is ignored and refetched rather than trusted.

zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

_env_cache_path() {
  print -r -- "${HOME}/.cache/zsh/${1:l}"
}

# Returns 0 if the file is safe to read and younger than the TTL.
_env_cache_usable() {
  local file=$1 ttl=$2
  # -L before -f: the -f, -s and -O tests all follow symlinks, so a symlink
  # pointing at any well-permissioned file of the attacker's choosing would
  # pass all three. Reject the link itself.
  [[ ! -L "$file" ]] || return 1
  [[ -s "$file" && -f "$file" && -O "$file" ]] || return 1

  # zstat, not stat(1): on macOS with coreutils on PATH the BSD/GNU flag
  # detection is unreliable, and the two disagree about what -f means. The
  # builtin behaves the same everywhere.
  local -A st
  zstat -H st "$file" 2>/dev/null || return 1
  (( (st[mode] & 8#777) == 8#600 )) || return 1
  (( EPOCHSECONDS - st[mtime] < ttl )) || return 1
}

env_cache() {
  local var=$1; shift
  [[ -n "$var" ]] || { print -u2 "env_cache: missing variable name"; return 1 }

  local ttl=0 cmd='' file='' validate='' timeout='' quiet=0
  while (( $# )); do
    case $1 in
      --ttl)      ttl=$2;      shift 2 ;;
      --command)  cmd=$2;      shift 2 ;;
      --file)     file=$2;     shift 2 ;;
      --validate) validate=$2; shift 2 ;;
      --timeout)  timeout=$2;  shift 2 ;;
      --quiet)    quiet=1;     shift   ;;
      *) print -u2 "env_cache: unknown option '$1'"; return 1 ;;
    esac
  done
  [[ -n "$cmd" ]] || { print -u2 "env_cache: --command is required"; return 1 }
  : ${file:=$(_env_cache_path $var)}

  # Already set in the environment (exported by a parent, or by the user).
  [[ -n "${(P)var}" ]] && return 0

  if _env_cache_usable "$file" "$ttl"; then
    typeset -gx $var="$(<$file)"
    return 0
  fi

  local value
  if [[ -n "$timeout" ]] && (( $+commands[timeout] )); then
    value=$(timeout "$timeout" ${SHELL:-zsh} -c "$cmd" 2>/dev/null)
  else
    value=$(eval "$cmd" 2>/dev/null)
  fi

  if [[ -z "$value" ]]; then
    (( quiet )) || print -u2 "env_cache: '$cmd' produced nothing — $var not set"
    return 1
  fi

  typeset -gx $var="$value"

  # Only cache a value that looks right. A timeout can truncate mid-output,
  # and caching a half-written token for the full TTL is worse than not
  # caching at all.
  if [[ -n "$validate" ]] && [[ "$value" != (${~validate}) ]]; then
    (( quiet )) || print -u2 "env_cache: $var failed validation — set but not cached"
    return 0
  fi

  mkdir -p "${file:h}" 2>/dev/null || return 0
  # umask, not a chmod afterwards: there is no window where the file exists
  # world-readable.
  ( umask 077; print -r -- "$value" > "$file" )
}

env_cache_invalidate() {
  local var=$1 file=''
  [[ -n "$var" ]] || { print -u2 "env_cache_invalidate: missing variable name"; return 1 }
  shift
  [[ $1 == --file ]] && file=$2
  : ${file:=$(_env_cache_path $var)}
  rm -f -- "$file"
}
