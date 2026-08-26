# shellcheck shell=bash disable=all
Describe 'startup-log.zsh'
  Include lib/startup-log.zsh

  setup() {
    TMPROOT="$(mktemp -d)"
    ZSH_BOOT_KIT_LOG="$TMPROOT/startup.log"
    zmodload zsh/datetime
  }
  cleanup() { rm -rf "$TMPROOT"; }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'boot_kit_timer_start'
    It 'honours a T0 the caller set before sourcing'
      run_it() {
        ZSH_BOOT_KIT_T0=1234.5
        boot_kit_timer_start
        print -r -- "$ZSH_BOOT_KIT_T0"
      }
      When call run_it
      The output should equal '1234.5'
    End

    It 'falls back to now when T0 is unset'
      run_it() { unset ZSH_BOOT_KIT_T0; boot_kit_timer_start; [[ -n "$ZSH_BOOT_KIT_T0" ]] && print SET; }
      When call run_it
      The output should equal 'SET'
    End
  End

  Describe 'the log line'
    It 'reports phases in the order they were marked'
      run_it() {
        boot_kit_timer_start
        boot_kit_mark pre
        boot_kit_mark omz
        boot_kit_mark post
        _boot_kit_write_log
        print -r -- "$(<$ZSH_BOOT_KIT_LOG)"
      }
      When call run_it
      The output should match pattern '*pre=*omz=*post=*prompt=*'
    End

    # The `startup-stats` awk parser reads field 3, so the total's position and
    # NNNms shape are load-bearing.
    It 'keeps the total in field 3 formatted as NNNms'
      run_it() {
        boot_kit_timer_start
        boot_kit_mark pre
        _boot_kit_write_log
        line="$(<$ZSH_BOOT_KIT_LOG)"
        print -r -- "${line[(w)3]}"
      }
      When call run_it
      The output should match pattern '*ms'
    End

    It 'appends rather than overwriting'
      run_it() {
        boot_kit_timer_start; boot_kit_mark a; _boot_kit_write_log
        boot_kit_timer_start; boot_kit_mark a; _boot_kit_write_log
        wc -l < "$ZSH_BOOT_KIT_LOG" | tr -d ' '
      }
      When call run_it
      The output should equal '2'
    End

    It 'creates the log directory when it is missing'
      run_it() {
        ZSH_BOOT_KIT_LOG="$TMPROOT/deep/nested/startup.log"
        boot_kit_timer_start; boot_kit_mark a; _boot_kit_write_log
        [[ -s "$ZSH_BOOT_KIT_LOG" ]] && print WRITTEN
      }
      When call run_it
      The output should equal 'WRITTEN'
    End
  End

  Describe 'boot_kit_mark'
    It 'rejects an empty phase name'
      When call boot_kit_mark
      The status should be failure
    End
  End

  Describe 'boot_kit_exclude'
    # Subtracting a blocking stretch means advancing T0, so the measured total
    # shrinks by however long the block lasted.
    It 'advances T0 by the elapsed time'
      run_it() {
        ZSH_BOOT_KIT_T0=$EPOCHREALTIME
        before=$ZSH_BOOT_KIT_T0
        began=$(( EPOCHREALTIME - 5 ))
        boot_kit_exclude $began
        (( ZSH_BOOT_KIT_T0 - before >= 4.9 )) && print ADVANCED || print "NOT ($(( ZSH_BOOT_KIT_T0 - before )))"
      }
      When call run_it
      The output should equal 'ADVANCED'
    End

    It 'rejects a missing timestamp'
      When call boot_kit_exclude
      The status should be failure
    End
  End

  Describe 'startup-stats'
    It 'summarises n, avg, min and max'
      run_it() {
        printf '%s\n' \
          '2026-01-01 00:00:00   100ms  pre=1' \
          '2026-01-01 00:00:01   300ms  pre=1' > "$ZSH_BOOT_KIT_LOG"
        startup-stats
      }
      When call run_it
      The output should equal 'n=2  avg=200ms  min=100ms  max=300ms'
    End

    It 'errors when there is no log yet'
      When call startup-stats
      The status should be failure
      The stderr should include 'no log at'
    End
  End
End
