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
