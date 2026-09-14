# shellcheck shell=bash disable=all
Describe 'outdated-banner.zsh'
Include lib/outdated-banner.zsh

setup() {
  TMPROOT="$(mktemp -d)"
  CACHE="$TMPROOT/outdated"
}
cleanup() { rm -rf "$TMPROOT"; }

BeforeEach 'setup'
AfterEach 'cleanup'

# shellspec runs with no controlling terminal, so stand in for the guard.
interactive() { _outdated_banner_interactive() { return 0; }; }

Describe 'the TTY guard'
# Sourcing .zshrc from a script to pick up env vars must never block on a
# prompt, so a non-interactive shell prints nothing at all.
It 'stays silent in a non-interactive shell'
run_it() {
  print -l a b c >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s things'
}
When call run_it
The output should equal ''
End
End

Describe 'counting'
Before 'interactive'

It 'counts lines by default'
run_it() {
  print -l a b c >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s package(s) outdated'
}
When call run_it
The output should include '3 package(s) outdated'
End

It 'reads a pre-computed number under --count content'
run_it() {
  print 47 >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s commit(s) behind' --count content
}
When call run_it
The output should include '47 commit(s) behind'
End

It 'omits the count under --count none'
run_it() {
  print x >"$CACHE"
  outdated_banner --cache "$CACHE" --message 'something is stale' --count none
}
When call run_it
The output should include 'something is stale'
End

It 'rejects an unknown count mode'
run_it() {
  print x >"$CACHE"
  outdated_banner --cache "$CACHE" --message 'x' --count sideways
}
When call run_it
The status should be failure
The stderr should include "unknown --count mode"
End
End

Describe 'the nothing-to-do cases'
Before 'interactive'

It 'stays silent on an empty cache file'
run_it() {
  : >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s things'
}
When call run_it
The output should equal ''
End

It 'stays silent on a missing cache file'
When call outdated_banner --cache "$TMPROOT/nope" --message '%s things'
The output should equal ''
End

# A background job that ran and found nothing writes a literal 0 rather
# than truncating, so the banner must treat that as "checked, all clear".
It 'stays silent when the cache holds a literal zero'
run_it() {
  print 0 >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s things' --count content
}
When call run_it
The output should equal ''
End
End

Describe 'presentation'
Before 'interactive'

It 'prefixes the icon and appends the hint'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --icon 'ICON' --message '%s thing'
}
When call run_it
The output should equal "ICON  1 thing (see $CACHE)"
End

It 'honours a custom hint'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --hint 'run brew upgrade'
}
When call run_it
The output should equal '1 thing (run brew upgrade)'
End
End

Describe 'the upgrade prompt'
Before 'interactive'

It 'runs the upgrade command on y'
Data 'y'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --upgrade 'print UPGRADED'
}
When call run_it
The output should include 'UPGRADED'
End

It 'skips the upgrade command on n'
Data 'n'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --upgrade 'print UPGRADED'
}
When call run_it
The output should not include 'UPGRADED'
End

It 'does not prompt at all without --upgrade'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing'
}
When call run_it
The output should not include 'Upgrade now?'
End

# Waiting on a human is not shell boot time. Counting it makes the startup
# log useless on exactly the days you upgraded.
It 'hands the elapsed block to boot_kit_exclude when it is available'
Data 'n'
run_it() {
  boot_kit_exclude() { print "EXCLUDED $#"; }
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --upgrade 'true'
}
When call run_it
The output should include 'EXCLUDED 1'
End
End

Describe 'argument validation'
It 'requires --cache and --message'
When call outdated_banner --cache /nope
The status should be failure
The stderr should include 'are required'
End

It 'rejects an unknown option'
When call outdated_banner --sideways
The status should be failure
The stderr should include "unknown option"
End
End

Describe 'the deferred single-prompt mode (--defer + outdated_banner_prompt)'
Before 'interactive'

# The accumulator is shell-global, so reset it for each example or banners
# leak across examples that share the same sourced file.
Before 'reset_accumulator'
reset_accumulator() {
  _out_banners_line=()
  _out_banners_upgrade=()
  _out_banners_label=()
  _out_banners_progress=()
  _out_bg_job=0
  _out_bg_notify=0
}

It 'collects banners silently, then prints them and prompts once on flush'
Data 'n'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --icon 'ONE' --message '%s brew thing' --hint b --defer --upgrade 'print RUN1'
  print -l x y >"$CACHE2"
  outdated_banner --cache "$CACHE2" --icon 'TWO' --message '%s npm thing' --hint n --defer --upgrade 'print RUN2'
  outdated_banner_prompt
}
CACHE2="$TMPROOT/outdated2"
When call run_it
# Both lines show, followed by exactly one prompt; n triggers no upgrade.
The entire output should equal $'ONE  1 brew thing (b)\nTWO  2 npm thing (n)\n  Update all of the above? [y/N] \n'
End

It 'runs every upgrade command in order on y'
Data 'y'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --defer --upgrade 'print RUN1'
  print -l a >"$CACHE2"
  outdated_banner --cache "$CACHE2" --message '%s thing' --defer --upgrade 'print RUN2'
  outdated_banner_prompt
}
CACHE2="$TMPROOT/outdated2"
When call run_it
The output should include 'RUN1'
The output should include 'RUN2'
End

It 'does not prompt when nothing was collected'
reset_accumulator
run_it() { outdated_banner_prompt; }
When call run_it
The output should equal ''
End

It 'skips an entry that had no upgrade command on y'
Data 'y'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s shown' --defer
  outdated_banner_prompt
}
When call run_it
The output should include '1 shown'
End

Describe '_out_register_bg_job and the background-greeting wait'
# fastfetch runs backgrounded during omz load, so its ASCII art can land on top
# of the deferred y/N. The prompt therefore waits for a registered welcome
# process to finish drawing first — but only when there are banners to flush.

It 'records the registered job PID'
When call _out_register_bg_job 12345
The variable _out_bg_job should equal 12345
End

It 'clears the registration on a non-numeric argument'
run_it() { _out_register_bg_job 'not-a-pid'; }
When call run_it
The status should be success
The variable _out_bg_job should equal 0
End

It 'parses a PID even when the caller has extendedglob disabled'
run_it() {
  setopt noextendedglob
  _out_register_bg_job 4321
}
When call run_it
The variable _out_bg_job should equal 4321
End

It 'waits on the registered job before printing banners'
Data 'n'
Mock 'wait'
print "WAITING $1"
End
run_it() {
  print -l a >"$CACHE"
  _out_register_bg_job 99
  outdated_banner --cache "$CACHE" --message '%s thing' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
# The wait must happen BEFORE the banner appears, so the wait line is first.
The line 1 of output should equal 'WAITING 99'
The output should include '1 thing'
# The PID is cleared after the wait so a later recycled PID can't block again.
The variable _out_bg_job should equal 0
End

It 'reaps a registered job even when nothing was collected'
reset_accumulator
Mock 'wait'
print "WAITING $1"
End
run_it() {
  _out_register_bg_job 99
  outdated_banner_prompt
}
When call run_it
# The welcome job is reaped so zsh never prints "[n] done" at the prompt, but
# with no banners there is nothing to show.
The output should equal 'WAITING 99'
The variable _out_bg_job should equal 0
End
End
End

Describe '_out_bg_job_start'
It 'ignores an empty command'
run_it() { _out_bg_job_start; }
When call run_it
The status should be success
The variable _out_bg_job should equal 0
End

It 'runs the launched command'
run_it() {
  MARK="$TMPROOT/bg-ran"
  _out_bg_job_start touch "$MARK"
  _out_reap_bg_job
  print "RAN=$([[ -f $MARK ]] && print yes || print no)"
}
When call run_it
The output should include 'RAN=yes'
End

# MONITOR cannot be enabled in shellspec (no job control), so this asserts the
# setting is left as found rather than toggled on and stranded. The launch and
# reap both scope MONITOR off with local_options, which zsh restores on return —
# there is no manual save/restore branch left to regress.
It 'leaves MONITOR as it found it across launch and reap'
run_it() {
  print "BEFORE=$([[ -o monitor ]] && print on || print off)"
  _out_bg_job_start true
  print "LAUNCH=$([[ -o monitor ]] && print on || print off)"
  _out_reap_bg_job
  print "REAP=$([[ -o monitor ]] && print on || print off)"
}
When call run_it
The output should include 'LAUNCH=off'
The output should include 'REAP=off'
End

It 'suspends NOTIFY for the launch and restores it on reap'
run_it() {
  setopt notify
  _out_bg_job_start true
  print "START=$([[ -o notify ]] && print on || print off)"
  _out_reap_bg_job
  print "REAP=$([[ -o notify ]] && print on || print off)"
}
When call run_it
The output should include 'START=off'
The output should include 'REAP=on'
End

It 'leaves NOTIFY off if it was already off'
run_it() {
  unsetopt notify
  _out_bg_job_start true
  _out_reap_bg_job
  print "AFTER=$([[ -o notify ]] && print on || print off)"
}
When call run_it
The output should include 'AFTER=off'
End

# A second launch used to see NOTIFY already off and zero the pending
# suspension, so the reap never restored it and the shell lost job-completion
# notices for good.
It 'keeps a pending NOTIFY suspension across a second launch'
run_it() {
  setopt notify
  _out_bg_job_start true
  _out_bg_job_start true
  _out_reap_bg_job
  print "AFTER=$([[ -o notify ]] && print on || print off)"
}
When call run_it
The output should include 'AFTER=on'
End
End

Describe 'the gum deferred UI'
Before 'interactive'
Before 'reset_accumulator'
Before 'gum_env'
reset_accumulator() {
  _out_banners_line=()
  _out_banners_upgrade=()
  _out_banners_label=()
  _out_banners_progress=()
  _out_bg_job=0
  _out_bg_notify=0
}

# A fake gum(1) so the gum path is exercised without a terminal. It parses the
# flags this module actually passes and rejects anything else, so a typo'd or
# unsupported flag fails the suite instead of being swallowed. `confirm` exits
# with FAKE_GUM_CONFIRM (0 by default), `spin` runs the command after `--`, and
# `style` prints its trailing text argument or copies stdin.
gum_env() {
  FAKEBIN="$TMPROOT/bin"
  FAKE_GUM_LOG="$TMPROOT/gum.log"
  unset FAKE_GUM_CONFIRM
  mkdir -p "$FAKEBIN"
  cat >"$FAKEBIN/gum" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$1" "$*" >> "$FAKE_GUM_LOG"
cmd=$1; shift
case "$cmd" in
  confirm)
    case " $* " in
      *' --default=false '*) ;;
      *) echo "gum-stub: unexpected confirm flags: $*" >&2; exit 2 ;;
    esac
    exit "${FAKE_GUM_CONFIRM:-0}"
    ;;
  spin)
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in
        --spinner | --spinner.foreground | --title) shift 2 ;;
        *) echo "gum-stub: unexpected spin flag: $1" >&2; exit 2 ;;
      esac
    done
    [ "$1" = "--" ] && shift
    "$@"
    ;;
  style)
    text=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --padding | --margin | --border | --border-foreground | --foreground | --background | --border-background | --align | --width | --height) shift 2 ;;
        -*) shift ;;
        *) text=$1; shift ;;
      esac
    done
    if [ -n "$text" ]; then printf '%s\n' "$text"; else cat; fi
    ;;
  *)
    echo "gum-stub: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$FAKEBIN/gum"
  export FAKE_GUM_LOG
  export PATH="$FAKEBIN:$PATH"
  export ZSH_BOOT_KIT_UI=gum
}

It 'shows a styled summary and runs every upgrade when confirmed'
run_it() {
  MARK1="$TMPROOT/run1"
  MARK2="$TMPROOT/run2"
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --icon ONE --message '%s brew thing' --label 'Homebrew' --defer --upgrade "touch $MARK1"
  print -l a b >"$CACHE2"
  outdated_banner --cache "$CACHE2" --icon TWO --message '%s npm thing' --label 'npm globals' --defer --upgrade "touch $MARK2"
  outdated_banner_prompt
}
CACHE2="$TMPROOT/outdated2"
When call run_it
The output should include 'Updates available'
The path "$MARK1" should be exist
The path "$MARK2" should be exist
The output should include '✔ Homebrew'
The output should include '✔ npm globals'
End

It 'runs nothing when the confirm is declined (a bare Enter, the default)'
run_it() {
  MARK1="$TMPROOT/run1"
  MARK2="$TMPROOT/run2"
  export FAKE_GUM_CONFIRM=1
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s brew thing' --label 'Homebrew' --defer --upgrade "touch $MARK1"
  print -l a >"$CACHE2"
  outdated_banner --cache "$CACHE2" --message '%s npm thing' --label 'npm globals' --defer --upgrade "touch $MARK2"
  outdated_banner_prompt
}
CACHE2="$TMPROOT/outdated2"
When call run_it
The path "$MARK1" should not be exist
The path "$MARK2" should not be exist
The output should include 'Updates available'
The output should not include '✔'
End

It 'asks one binary confirm, defaulting to No'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s brew thing' --label 'Homebrew' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
The output should include '✔ Homebrew'
The contents of file "$FAKE_GUM_LOG" should include 'confirm'
The contents of file "$FAKE_GUM_LOG" should include '--default=false'
The contents of file "$FAKE_GUM_LOG" should not include 'choose'
End

It 'reports a failed upgrade with its exit code'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s brew thing' --label 'Homebrew' --defer --upgrade 'exit 3'
  outdated_banner_prompt
}
When call run_it
The output should include '✘ Homebrew'
The output should include 'exit 3'
End

It 'falls back to the banner text when no --label is given'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s brew thing' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
The output should include '✔ 1 brew thing'
The contents of file "$FAKE_GUM_LOG" should include '1 brew thing'
End

It 'lists each item as it lands when the upgrade speaks --progress'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --label 'Widgets' --progress --defer \
    --upgrade 'printf "@total 2\n@done alpha\n@done beta\n"'
  outdated_banner_prompt
}
When call run_it
The output should include '✔ alpha'
The output should include '✔ beta'
The output should include '✔ Widgets (2/2 updated)'
The output should not include '@total'
End

It 'reports skipped and failed items, and flags the system in the summary'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --label 'Widgets' --progress --defer \
    --upgrade 'printf "@total 3\n@done alpha\n@skip beta\n@fail gamma\n"; true'
  outdated_banner_prompt
}
When call run_it
The output should include '✔ alpha'
The output should include '○ beta (skipped)'
The output should include '✘ gamma'
The output should include '✘ Widgets (1/3 updated, 1 failed)'
End

It 'treats a non-zero exit with no item failures as a failure'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --label 'Widgets' --progress --defer \
    --upgrade 'exit 4'
  outdated_banner_prompt
}
When call run_it
The output should include '✘ Widgets (0/0 updated, exit 4)'
End

# Only banners with an --upgrade are runnable; a gap between them must not
# shift which command an index resolves to.
It 'runs the upgradable banners and skips a gap in the middle'
run_it() {
  MARK1="$TMPROOT/run1"
  MARK3="$TMPROOT/run3"
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s one' --label 'One' --defer --upgrade "touch $MARK1"
  print -l a >"$CACHE2"
  outdated_banner --cache "$CACHE2" --message '%s two' --label 'Two' --defer
  print -l a >"$CACHE3"
  outdated_banner --cache "$CACHE3" --message '%s three' --label 'Three' --defer --upgrade "touch $MARK3"
  outdated_banner_prompt
}
CACHE2="$TMPROOT/outdated2"
CACHE3="$TMPROOT/outdated3"
When call run_it
The path "$MARK1" should be exist
The path "$MARK3" should be exist
The output should include '✔ One'
The output should include '✔ Three'
The output should not include '✔ Two'
End

It 'shows the box but asks nothing when no banner can be upgraded'
run_it() {
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --defer
  outdated_banner_prompt
}
When call run_it
The output should include 'Updates available'
The contents of file "$FAKE_GUM_LOG" should not include 'confirm'
End
End

Describe 'backend selection'
Before 'interactive'
Before 'reset_accumulator'
reset_accumulator() {
  _out_banners_line=()
  _out_banners_upgrade=()
  _out_banners_label=()
  _out_banners_progress=()
  _out_bg_job=0
  _out_bg_notify=0
}

It 'stays plain under auto when gum is present but stdout is not a terminal'
run_it() {
  FAKEBIN="$TMPROOT/bin"
  mkdir -p "$FAKEBIN"
  printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/gum"
  chmod +x "$FAKEBIN/gum"
  export PATH="$FAKEBIN:$PATH"
  unset ZSH_BOOT_KIT_UI
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
The output should include '[y/N]'
End

It 'stays plain when gum is forced but absent'
run_it() {
  ZSH_BOOT_KIT_UI=gum
  PATH=/usr/bin:/bin
  print -l a >"$CACHE"
  outdated_banner --cache "$CACHE" --message '%s thing' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
The output should include '[y/N]'
End
End
End
