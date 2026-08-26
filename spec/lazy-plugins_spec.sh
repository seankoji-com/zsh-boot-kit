# shellcheck shell=bash disable=all
Describe 'lazy-plugins.zsh'
  Include lib/lazy-plugins.zsh

  setup() {
    TMPROOT="$(mktemp -d)"
    ZSH_CUSTOM="$TMPROOT/custom"
    ZSH="$TMPROOT/omz"
    mkdir -p "$ZSH_CUSTOM/plugins" "$ZSH/plugins"
    plugins=()
  }
  cleanup() { rm -rf "$TMPROOT"; }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A plugin whose value is a shell function, like oh-my-zsh's extract.
  make_fn_plugin() {
    mkdir -p "$ZSH_CUSTOM/plugins/$1"
    print "$1() { print \"$1 ran: \$*\" }" > "$ZSH_CUSTOM/plugins/$1/$1.plugin.zsh"
  }

  # A plugin that defines a function under a name other than its own, so a
  # trigger pointing at it actually resolves on re-dispatch.
  make_plugin_defining() {
    # $1 plugin name, $2 function it defines
    mkdir -p "$ZSH_CUSTOM/plugins/$1"
    print "$2() { print \"$1 ran: \$*\" }" > "$ZSH_CUSTOM/plugins/$1/$1.plugin.zsh"
  }

  # A plugin whose value is aliases, like the gemini CLI plugin.
  make_alias_plugin() {
    mkdir -p "$ZSH_CUSTOM/plugins/$1"
    print "alias $2='print aliased:'" > "$ZSH_CUSTOM/plugins/$1/$1.plugin.zsh"
  }

  Describe 'stub installation'
    It 'shadows the plugin name with a function'
      install() { make_fn_plugin demo; lazy_plugins demo; whence -w demo; }
      When call install
      The output should equal 'demo: function'
    End

    It 'shadows every named trigger'
      install() {
        make_alias_plugin tool tl
        lazy_plugins 'tool:tool,tl,tll'
        print "$(whence -w tl) $(whence -w tll)"
      }
      When call install
      The output should equal 'tl: function tll: function'
    End
  End

  Describe 'dispatch after loading'
    # The naive implementation re-invoked with `command $trigger`, which fails
    # for any plugin providing a shell function rather than a binary.
    # oh-my-zsh's extract exits 127 under that approach.
    It 'calls a function the plugin defined'
      run_it() { make_fn_plugin demo; lazy_plugins demo; demo hello; }
      When call run_it
      The output should equal 'demo ran: hello'
      The status should be success
    End

    It 'calls an alias the plugin defined, reached via its trigger'
      run_it() { make_alias_plugin tool tl; lazy_plugins 'tool:tl'; tl world; }
      When call run_it
      The output should equal 'aliased: world'
      The status should be success
    End

    It 'falls through to a real binary when the plugin defines no function'
      run_it() {
        mkdir -p "$ZSH_CUSTOM/plugins/justcomp"
        print '# completions only, no command' > "$ZSH_CUSTOM/plugins/justcomp/justcomp.plugin.zsh"
        lazy_plugins 'justcomp:true'
        true && print dispatched
      }
      When call run_it
      The output should equal 'dispatched'
    End

    It 'reports a trigger that never materialised'
      run_it() {
        mkdir -p "$ZSH_CUSTOM/plugins/empty"
        : > "$ZSH_CUSTOM/plugins/empty/empty.plugin.zsh"
        lazy_plugins 'empty:nosuchthing'
        nosuchthing
      }
      When call run_it
      The status should equal 127
      The stderr should include 'still undefined after loading'
    End
  End

  Describe 'stub cleanup'
    It 'removes every stub for the plugin on first use, not just the one called'
      run_it() {
        make_fn_plugin demo
        lazy_plugins 'demo:demo,alt'
        demo once >/dev/null
        # 'alt' was a stub for the same plugin and must be gone, otherwise a
        # later `alt` would re-source the plugin.
        whence -w alt
      }
      When call run_it
      The status should be failure
      The output should equal 'alt: none'
    End

    It 'does not re-source the plugin on the second call'
      run_it() {
        mkdir -p "$ZSH_CUSTOM/plugins/counter"
        cat > "$ZSH_CUSTOM/plugins/counter/counter.plugin.zsh" <<'EOF'
(( COUNTER_SOURCED++ ))
counter() { print "sourced $COUNTER_SOURCED time(s)" }
EOF
        COUNTER_SOURCED=0
        lazy_plugins counter
        counter >/dev/null
        counter
      }
      When call run_it
      The output should equal 'sourced 1 time(s)'
    End
  End

  Describe 'trigger collisions'
    # A command like `docker` is both an oh-my-zsh plugin in its own right and
    # one of the 73 commands grc wraps, so claiming it twice is easy to do by
    # accident. Silently letting the second registration win means one plugin
    # never loads and nothing says why.
    It 'refuses to reassign a trigger another plugin already claimed'
      run_it() {
        make_plugin_defining first shared
        make_plugin_defining second shared
        lazy_plugins 'first:shared'
        lazy_plugins 'second:shared'
      }
      When call run_it
      The stderr should include "already a trigger for 'first'"
    End

    It 'leaves the original owner dispatching'
      run_it() {
        make_plugin_defining first shared
        make_plugin_defining second shared
        lazy_plugins 'first:shared'
        lazy_plugins 'second:shared' 2>/dev/null
        shared x
      }
      When call run_it
      The output should equal 'first ran: x'
    End

    # The skipped trigger still belongs to the first plugin. If it were
    # recorded against the second, that plugin's dispatch cleanup would
    # unfunction it and steal it.
    It 'does not let the loser steal the trigger on its own dispatch'
      run_it() {
        make_plugin_defining first shared
        make_fn_plugin second
        lazy_plugins 'first:shared'
        lazy_plugins 'second:second,shared' 2>/dev/null
        second y >/dev/null
        shared x
      }
      When call run_it
      The output should equal 'first ran: x'
    End

    It 'allows the same plugin to re-register its own trigger'
      run_it() {
        make_fn_plugin demo
        lazy_plugins 'demo:demo'
        lazy_plugins 'demo:demo'
        demo x
      }
      When call run_it
      The output should equal 'demo ran: x'
      The stderr should equal ''
    End
  End

  Describe 'the post-load hook'
    # oh-my-zsh's grc plugin wraps 73 commands including ls, so it silently
    # replaces an eza wrapper and breaks aliases passing eza-only flags.
    It 'runs _lazy_after_<plugin> after sourcing'
      run_it() {
        make_fn_plugin demo
        _lazy_after_demo() { print 'AFTER RAN'; }
        lazy_plugins demo
        demo x
      }
      When call run_it
      The line 1 of output should equal 'AFTER RAN'
      The line 2 of output should equal 'demo ran: x'
    End

    It 'lets the hook undo a definition the plugin clobbered'
      run_it() {
        mkdir -p "$ZSH_CUSTOM/plugins/stomper"
        cat > "$ZSH_CUSTOM/plugins/stomper/stomper.plugin.zsh" <<'EOF'
ls() { print 'clobbered' }
stomper() { print 'stomper ran' }
EOF
        ls() { print 'my ls' }
        _lazy_after_stomper() { ls() { print 'my ls' } }
        lazy_plugins stomper
        stomper >/dev/null
        ls
      }
      When call run_it
      The output should equal 'my ls'
    End

    It 'is optional'
      run_it() { make_fn_plugin demo; lazy_plugins demo; demo x; }
      When call run_it
      The output should equal 'demo ran: x'
      The status should be success
    End
  End

  Describe 'plugin resolution'
    It 'prefers $ZSH_CUSTOM over $ZSH, matching oh-my-zsh'
      run_it() {
        mkdir -p "$ZSH_CUSTOM/plugins/dup" "$ZSH/plugins/dup"
        print 'dup() { print custom }' > "$ZSH_CUSTOM/plugins/dup/dup.plugin.zsh"
        print 'dup() { print builtin }' > "$ZSH/plugins/dup/dup.plugin.zsh"
        lazy_plugins dup
        dup
      }
      When call run_it
      The output should equal 'custom'
    End
  End

  Describe 'the double-load guard'
    # An eagerly-loaded plugin that is also lazy-listed loads at startup AND
    # gets re-sourced by the stub on every invocation.
    It 'refuses a plugin already present in $plugins'
      run_it() { plugins=(demo); lazy_plugins demo; }
      When call run_it
      The stderr should include 'already in $plugins'
    End

    It 'leaves the command unshadowed when it refuses'
      run_it() {
        plugins=(demo)
        lazy_plugins demo 2>/dev/null
        (( $+functions[demo] )) && print SHADOWED || print CLEAN
      }
      When call run_it
      The output should equal 'CLEAN'
    End
  End
End
