# shellcheck shell=bash disable=all
# env-cache uses zsh-only syntax (${(P)var}, zstat, 8#600 octal literals),
# which is why this suite runs under shellspec's zsh mode rather than bats.
Describe 'env-cache.zsh'
  Include lib/env-cache.zsh

  setup() {
    TMPROOT="$(mktemp -d)"
    CACHE="$TMPROOT/tok"
  }
  cleanup() { rm -rf "$TMPROOT"; }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  Describe 'on a cold cache'
    It 'runs the command, exports the value, and writes the file'
      When call env_cache MYTOK --ttl 3600 --command 'print -r -- tok_abc' --file "$CACHE"
      The status should be success
      The variable MYTOK should equal 'tok_abc'
      The path "$CACHE" should be file
    End

    It 'creates the cache file mode 0600'
      writes_then_stats() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_abc' --file "$CACHE"
        zmodload -F zsh/stat b:zstat
        local -A st; zstat -H st "$CACHE"
        print $(( st[mode] & 8#777 ))
      }
      When call writes_then_stats
      The output should equal "$(( 8#600 ))"
    End
  End

  Describe 'on a warm cache'
    It 'reads the file instead of re-running the command'
      warm_then_read() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_abc' --file "$CACHE"
        unset MYTOK
        env_cache MYTOK --ttl 3600 --command 'print -r -- SHOULD_NOT_RUN' --file "$CACHE"
        print -r -- "$MYTOK"
      }
      When call warm_then_read
      The output should equal 'tok_abc'
    End

    It 'refetches once the TTL has expired'
      expire_then_read() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_old' --file "$CACHE"
        unset MYTOK
        env_cache MYTOK --ttl 0 --command 'print -r -- tok_new' --file "$CACHE"
        print -r -- "$MYTOK"
      }
      When call expire_then_read
      The output should equal 'tok_new'
    End
  End

  Describe 'cache file safety'
    # A cache file that is world-readable, or not owned by us, could have been
    # planted. Ignore it and refetch rather than trusting it.
    It 'rejects a cache file that is not mode 0600'
      loosen_then_read() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_old' --file "$CACHE"
        chmod 644 "$CACHE"
        unset MYTOK
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_refetched' --file "$CACHE"
        print -r -- "$MYTOK"
      }
      When call loosen_then_read
      The output should equal 'tok_refetched'
    End

    It 'rejects a symlink standing in for the cache file'
      symlink_then_read() {
        print -r -- tok_planted > "$TMPROOT/planted"
        chmod 600 "$TMPROOT/planted"
        ln -s "$TMPROOT/planted" "$CACHE"
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_real' --file "$CACHE"
        print -r -- "$MYTOK"
      }
      When call symlink_then_read
      The output should equal 'tok_real'
    End
  End

  Describe 'validation'
    # A --timeout can truncate the command mid-output. Caching half a token for
    # the full TTL is worse than not caching at all.
    It 'exports a value that fails validation but does not cache it'
      invalid() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- garbage' \
          --file "$CACHE" --validate 'tok_*' 2>/dev/null
        print -r -- "$MYTOK"
        [[ -f "$CACHE" ]] && print CACHED || print NOTCACHED
      }
      When call invalid
      The line 1 of output should equal 'garbage'
      The line 2 of output should equal 'NOTCACHED'
    End

    It 'caches a value that passes validation'
      valid() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_ok' \
          --file "$CACHE" --validate 'tok_*|ghp_*'
        [[ -f "$CACHE" ]] && print CACHED || print NOTCACHED
      }
      When call valid
      The output should equal 'CACHED'
    End
  End

  Describe 'failure handling'
    It 'warns and returns non-zero when the command produces nothing'
      When call env_cache MYTOK --ttl 3600 --command 'true' --file "$CACHE"
      The status should be failure
      The stderr should include 'produced nothing'
    End

    It 'stays silent under --quiet'
      When call env_cache MYTOK --ttl 3600 --command 'true' --file "$CACHE" --quiet
      The status should be failure
      The stderr should equal ''
    End

    It 'rejects an unknown option'
      When call env_cache MYTOK --nonsense
      The status should be failure
      The stderr should include "unknown option"
    End

    It 'requires --command'
      When call env_cache MYTOK --ttl 10
      The status should be failure
      The stderr should include '--command is required'
    End
  End

  Describe 'env_cache_invalidate'
    It 'removes the cache file'
      make_then_drop() {
        env_cache MYTOK --ttl 3600 --command 'print -r -- tok_abc' --file "$CACHE"
        env_cache_invalidate MYTOK --file "$CACHE"
        [[ -f "$CACHE" ]] && print PRESENT || print GONE
      }
      When call make_then_drop
      The output should equal 'GONE'
    End
  End

  Describe 'an already-set variable'
    It 'is left alone without running the command'
      preset() {
        MYTOK=already
        env_cache MYTOK --ttl 3600 --command 'print -r -- SHOULD_NOT_RUN' --file "$CACHE"
        print -r -- "$MYTOK"
      }
      When call preset
      The output should equal 'already'
    End
  End
End
