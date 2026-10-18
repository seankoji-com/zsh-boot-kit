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

  Describe 'ZSH_BOOT_KIT_LOG_AFTER'
    # Deferred loading (zinit Turbo) finishes after the first prompt. The first
    # prompt becomes its own phase and the line waits for the named mark.
    It 'writes the line when the deferred phase is marked after the prompt'
      run_it() {
        ZSH_BOOT_KIT_LOG_AFTER=ready
        boot_kit_timer_start
        boot_kit_mark pre
        boot_kit_log_on_first_prompt
        _boot_kit_first_prompt
        [[ -s "$ZSH_BOOT_KIT_LOG" ]] && print EARLY
        boot_kit_mark ready
        print -r -- "$(<$ZSH_BOOT_KIT_LOG)"
      }
      When call run_it
      The output should match pattern '*pre=*prompt=*ready=*'
      The output should not include 'EARLY'
    End

    # Provisioning and tests load everything eagerly, so the mark lands before
    # the prompt; the first prompt still writes the line.
    It 'writes at the first prompt when the phase was marked before it'
      run_it() {
        ZSH_BOOT_KIT_LOG_AFTER=ready
        boot_kit_timer_start
        boot_kit_mark pre
        boot_kit_mark ready
        boot_kit_log_on_first_prompt
        _boot_kit_first_prompt
        print -r -- "$(<$ZSH_BOOT_KIT_LOG)"
      }
      When call run_it
      The output should match pattern '*pre=*ready=*prompt=*'
    End

    It 'falls back to the second prompt when the phase never arrives'
      run_it() {
        ZSH_BOOT_KIT_LOG_AFTER=ready
        boot_kit_timer_start
        boot_kit_mark pre
        boot_kit_log_on_first_prompt
        _boot_kit_first_prompt
        [[ -s "$ZSH_BOOT_KIT_LOG" ]] && print EARLY
        _boot_kit_write_log
        print -r -- "$(<$ZSH_BOOT_KIT_LOG)"
      }
      When call run_it
      The output should match pattern '*pre=*prompt=*'
      The output should not include 'EARLY'
      The output should not include 'ready='
    End

    It 'ignores marks that arrive after the line was written'
      run_it() {
        ZSH_BOOT_KIT_LOG_AFTER=ready
        boot_kit_timer_start
        boot_kit_mark pre
        boot_kit_log_on_first_prompt
        _boot_kit_first_prompt
        _boot_kit_write_log
        boot_kit_mark ready
        wc -l < "$ZSH_BOOT_KIT_LOG" | tr -d ' '
      }
      When call run_it
      The output should equal '1'
    End
  End

  Describe 'boot_kit_exclude'
    # Each deterministic case runs in a subshell so replacing the clock cannot
    # affect other examples. Exercise the public mark/exclude API and log output.
    fixture_clock() {
      zmodload -u zsh/datetime
      typeset -gF EPOCHREALTIME=100
      ZSH_BOOT_KIT_T0=100
      boot_kit_timer_start
    }
    print_timing() {
      _boot_kit_write_log
      local line="$(<$ZSH_BOOT_KIT_LOG)"
      print -r -- "${line[(w)3]} ${line#*ms  }"
    }

    It 'keeps ordinary phase durations without exclusions'
      run_it() (
        fixture_clock
        EPOCHREALTIME=101; boot_kit_mark pre
        EPOCHREALTIME=107; boot_kit_mark post
        EPOCHREALTIME=108; print_timing
      )
      When call run_it
      The output should equal '8000ms pre=1000 post=6000 prompt=1000'
    End

    It 'removes a wait after an earlier mark without making that phase negative'
      run_it() (
        fixture_clock
        EPOCHREALTIME=101; boot_kit_mark pre
        EPOCHREALTIME=106; boot_kit_exclude 101
        EPOCHREALTIME=107; boot_kit_mark post
        EPOCHREALTIME=108; print_timing
      )
      When call run_it
      The output should equal '3000ms pre=1000 post=1000 prompt=1000'
    End

    It 'removes only the excluded portion of a phase marked inside a wait'
      run_it() (
        fixture_clock
        EPOCHREALTIME=101; boot_kit_mark pre
        EPOCHREALTIME=104; boot_kit_mark during
        EPOCHREALTIME=106; boot_kit_exclude 102
        EPOCHREALTIME=107; boot_kit_mark post
        EPOCHREALTIME=108; print_timing
      )
      When call run_it
      The output should equal '4000ms pre=1000 during=1000 post=1000 prompt=1000'
    End

    It 'handles separate waits before and after the first mark'
      run_it() (
        fixture_clock
        EPOCHREALTIME=103; boot_kit_exclude 101
        EPOCHREALTIME=104; boot_kit_mark pre
        EPOCHREALTIME=108; boot_kit_exclude 105
        EPOCHREALTIME=109; boot_kit_mark post
        EPOCHREALTIME=110; print_timing
      )
      When call run_it
      The output should equal '5000ms pre=2000 post=2000 prompt=1000'
    End

    It 'preserves the first prompt duration while excluding deferred work waits'
      run_it() (
        fixture_clock
        ZSH_BOOT_KIT_LOG_AFTER=ready
        EPOCHREALTIME=101; boot_kit_mark pre
        EPOCHREALTIME=102; _boot_kit_first_prompt
        EPOCHREALTIME=107; boot_kit_exclude 103
        EPOCHREALTIME=108; boot_kit_mark ready
        local line="$(<$ZSH_BOOT_KIT_LOG)"
        print -r -- "${line[(w)3]} ${line#*ms  }"
      )
      When call run_it
      The output should equal '4000ms pre=1000 prompt=1000 ready=2000'
    End

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
