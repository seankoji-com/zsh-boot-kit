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
      run_it() { print -l a b c > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s things'; }
      When call run_it
      The output should equal ''
    End
  End

  Describe 'counting'
    Before 'interactive'

    It 'counts lines by default'
      run_it() { print -l a b c > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s package(s) outdated'; }
      When call run_it
      The output should include '3 package(s) outdated'
    End

    It 'reads a pre-computed number under --count content'
      run_it() { print 47 > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s commit(s) behind' --count content; }
      When call run_it
      The output should include '47 commit(s) behind'
    End

    It 'omits the count under --count none'
      run_it() { print x > "$CACHE"; outdated_banner --cache "$CACHE" --message 'something is stale' --count none; }
      When call run_it
      The output should include 'something is stale'
    End

    It 'rejects an unknown count mode'
      run_it() { print x > "$CACHE"; outdated_banner --cache "$CACHE" --message 'x' --count sideways; }
      When call run_it
      The status should be failure
      The stderr should include "unknown --count mode"
    End
  End

  Describe 'the nothing-to-do cases'
    Before 'interactive'

    It 'stays silent on an empty cache file'
      run_it() { : > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s things'; }
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
      run_it() { print 0 > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s things' --count content; }
      When call run_it
      The output should equal ''
    End
  End

  Describe 'presentation'
    Before 'interactive'

    It 'prefixes the icon and appends the hint'
      run_it() { print -l a > "$CACHE"; outdated_banner --cache "$CACHE" --icon 'ICON' --message '%s thing'; }
      When call run_it
      The output should equal "ICON  1 thing (see $CACHE)"
    End

    It 'honours a custom hint'
      run_it() { print -l a > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s thing' --hint 'run brew upgrade'; }
      When call run_it
      The output should equal '1 thing (run brew upgrade)'
    End
  End

  Describe 'the upgrade prompt'
    Before 'interactive'

    It 'runs the upgrade command on y'
      Data 'y'
      run_it() { print -l a > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s thing' --upgrade 'print UPGRADED'; }
      When call run_it
      The output should include 'UPGRADED'
    End

    It 'skips the upgrade command on n'
      Data 'n'
      run_it() { print -l a > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s thing' --upgrade 'print UPGRADED'; }
      When call run_it
      The output should not include 'UPGRADED'
    End

    It 'does not prompt at all without --upgrade'
      run_it() { print -l a > "$CACHE"; outdated_banner --cache "$CACHE" --message '%s thing'; }
      When call run_it
      The output should not include 'Upgrade now?'
    End

    # Waiting on a human is not shell boot time. Counting it makes the startup
    # log useless on exactly the days you upgraded.
    It 'hands the elapsed block to boot_kit_exclude when it is available'
      Data 'n'
      run_it() {
        boot_kit_exclude() { print "EXCLUDED $#"; }
        print -l a > "$CACHE"
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
End
