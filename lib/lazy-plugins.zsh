# lazy-plugins — load an oh-my-zsh plugin the first time you use it.
#
# Most plugins cost 10-200ms at startup and earn their keep in maybe one shell
# in ten. This replaces each plugin's entry points with a stub. The stub loads
# the plugin, removes itself, and re-runs what you actually typed.
#
# API
#   lazy_plugins <spec>...
#
#     <spec> is either a plugin name:
#         lazy_plugins docker gh uv
#     or a plugin name with the triggers that should load it:
#         lazy_plugins 'gemini:gemini,gm,gmm,gme'
#
# Why triggers matter: a plugin whose value is aliases cannot be lazy-loaded by
# its own name. The `gemini` plugin exists to give you `gm`. Shadowing only
# `gemini` means `gm` does not exist until you have already typed `gemini`
# once, which defeats the point. Name the aliases as triggers instead.
#
# Do not lazy-load a plugin that is also in $plugins. The eager copy loads at
# startup and the stub still shadows the command afterwards, so you pay for the
# plugin twice and re-source it on every invocation. lazy_plugins refuses and
# warns rather than letting that happen silently.

typeset -gA _lazy_plugin_of     # trigger -> plugin
typeset -gA _lazy_triggers_of   # plugin  -> space-separated triggers

lazy_plugins() {
  local spec plugin trigger
  local -a triggers

  for spec in "$@"; do
    plugin=${spec%%:*}
    if [[ $spec == *:* ]]; then
      triggers=(${(s:,:)${spec#*:}})
    else
      triggers=($plugin)
    fi

    if (( ${plugins[(Ie)$plugin]} )); then
      print -u2 "lazy_plugins: '$plugin' is already in \$plugins — skipping (it would load twice)"
      continue
    fi

    # Record only the triggers actually claimed. A trigger skipped below still
    # belongs to the plugin that claimed it first, and listing it here would
    # make this plugin's dispatch cleanup unfunction and steal it.
    local -a claimed
    claimed=()
    for trigger in $triggers; do
      # Two plugins claiming the same trigger is a silent footgun: the second
      # registration overwrites the first, so one plugin simply never loads and
      # nothing says so. Easy to hit, since a command like `docker` is both an
      # oh-my-zsh plugin in its own right and one of the 73 commands grc wraps.
      if [[ -n "${_lazy_plugin_of[$trigger]}" && "${_lazy_plugin_of[$trigger]}" != "$plugin" ]]; then
        print -u2 "lazy_plugins: '$trigger' is already a trigger for '${_lazy_plugin_of[$trigger]}' — not reassigning it to '$plugin'"
        continue
      fi
      _lazy_plugin_of[$trigger]=$plugin
      functions[$trigger]="_lazy_plugin_dispatch ${(q)trigger} \"\$@\""
      claimed+=($trigger)
    done
    (( ${#claimed} )) && _lazy_triggers_of[$plugin]="${claimed[*]}"
  done
  return 0
}

_lazy_plugin_dispatch() {
  local trigger=$1; shift
  local plugin=${_lazy_plugin_of[$trigger]}

  if [[ -z "$plugin" ]]; then
    print -u2 "lazy_plugins: no plugin registered for '$trigger'"
    return 127
  fi

  # Drop every stub for this plugin before sourcing it. If a stub survived, the
  # plugin's own definition would be shadowed and the re-dispatch below would
  # call the stub again forever.
  local t
  for t in ${=_lazy_triggers_of[$plugin]}; do
    unfunction $t 2>/dev/null
    unset "_lazy_plugin_of[$t]"
  done
  unset "_lazy_triggers_of[$plugin]"

  # Custom before built-in, matching how oh-my-zsh resolves plugins itself.
  local candidate
  for candidate in \
    "$ZSH_CUSTOM/plugins/$plugin/$plugin.plugin.zsh" \
    "$ZSH/plugins/$plugin/$plugin.plugin.zsh"
  do
    if [[ -r "$candidate" ]]; then
      source "$candidate"
      break
    fi
  done

  # Post-load hook. Some plugins redefine things you set up earlier: the
  # oh-my-zsh `grc` plugin wraps 73 commands, `ls` among them, so it silently
  # replaces an eza or exa wrapper and breaks any alias passing flags the real
  # ls does not accept. Define _lazy_after_<plugin> to put things back.
  if (( $+functions[_lazy_after_$plugin] )); then
    "_lazy_after_$plugin"
  fi

  # Re-run what the user typed. The old version of this always used
  # `command $trigger`, which breaks for every plugin that provides a shell
  # function rather than a binary: `extract` exits 127 because there is no
  # extract(1) to find. Check what the plugin actually defined.
  if (( $+functions[$trigger] )); then
    $trigger "$@"
  elif (( $+aliases[$trigger] )); then
    eval "${aliases[$trigger]} ${(q)@}"
  elif (( $+commands[$trigger] )); then
    command $trigger "$@"
  else
    print -u2 "lazy_plugins: '$trigger' still undefined after loading '$plugin'"
    return 127
  fi
}
