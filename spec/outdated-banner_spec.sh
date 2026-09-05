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
  _out_bg_job=0
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

It 'waits on the registered job before printing banners'
Data 'n'
run_it() {
  wait() { print "WAITING $1"; }
  print -l a >"$CACHE"
  _out_register_bg_job 99
  outdated_banner --cache "$CACHE" --message '%s thing' --defer --upgrade 'true'
  outdated_banner_prompt
}
When call run_it
The output should include 'WAITING 99'
End

It 'does not wait when nothing was collected, even with a job registered'
reset_accumulator
run_it() {
  wait() { print "WAITING $1"; }
  _out_register_bg_job 99
  outdated_banner_prompt
}
When call run_it
The output should equal ''
End
End
End
End
