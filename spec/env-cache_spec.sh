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
        local -A st; zstat -H st "$CACHE"
        print $(( st[mode] & 8#777 ))
      }
      When call loosen_then_read
      The line 1 of output should equal 'tok_refetched'
      The line 2 of output should equal "$(( 8#600 ))"
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
      The contents of file "$TMPROOT/planted" should equal 'tok_planted'
      The path "$CACHE" should not be symlink
      The contents of file "$CACHE" should equal 'tok_real'
    End

    It 'replaces a stale hard-linked cache without changing its other name'
      hardlink_then_read() {
        print -r -- tok_old > "$TMPROOT/original"
        chmod 600 "$TMPROOT/original"
        ln "$TMPROOT/original" "$CACHE"
        env_cache MYTOK --ttl 0 --command 'print -r -- tok_real' --file "$CACHE"
      }
      When call hardlink_then_read
      The status should be success
      The contents of file "$TMPROOT/original" should equal 'tok_old'
      The contents of file "$CACHE" should equal 'tok_real'
    End

    It 'keeps the previous cache and removes temporary files if replacement fails'
      failed_replace() {
        print -r -- tok_old > "$CACHE"
        chmod 600 "$CACHE"
        mv() { return 1; }
        env_cache MYTOK --ttl 0 --command 'print -r -- tok_real' --file "$CACHE"
        local -a leftovers=("$CACHE".*(N))
        print -r -- "${#leftovers}"
      }
      When call failed_replace
      The status should be success
      The output should equal 0
      The stderr should include 'cache write failed'
      The variable MYTOK should equal 'tok_real'
      The contents of file "$CACHE" should equal 'tok_old'
    End
  End

  Describe 'writer cleanup'
    It 'refreshes with NO_CLOBBER while preserving the caller option'
      noclobber_refresh() {
        setopt LOCAL_OPTIONS
        setopt NO_CLOBBER
        env_cache MYTOK --ttl 0 --command 'print tok_old' --file "$CACHE"
        unset MYTOK
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE"
        [[ -o NO_CLOBBER ]] && print preserved
      }
      When call noclobber_refresh
      The output should equal preserved
      The contents of file "$CACHE" should equal tok_new
    End

    It 'keeps quiet on write failure when requested'
      quiet_failure() {
        mv() { return 1; }
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE" --quiet
      }
      When call quiet_failure
      The status should be success
      The stderr should equal ''
      The variable MYTOK should equal tok_new
    End

    It "cleans this writer's temporary file on HUP"
      interrupted_write() {
        local signal=$1
        print old > "$CACHE"
        chmod 600 "$CACHE"
        print sibling > "$CACHE.keep"
        mv() {
          zmodload zsh/system
          kill -s "$signal" "$sysparams[pid]"
          return 1
        }
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE"
        local -a leftovers=("$CACHE".*(N))
        print ${#leftovers}
      }
      When call interrupted_write HUP
      The status should be success
      The output should equal 1
      The stderr should include 'cache write failed'
      The contents of file "$CACHE" should equal old
      The contents of file "$CACHE.keep" should equal sibling
    End

    It "cleans this writer's temporary file on INT"
      interrupted_write() {
        local signal=$1
        print old > "$CACHE"
        chmod 600 "$CACHE"
        print sibling > "$CACHE.keep"
        mv() {
          zmodload zsh/system
          kill -s "$signal" "$sysparams[pid]"
          return 1
        }
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE"
        local -a leftovers=("$CACHE".*(N))
        print ${#leftovers}
      }
      When call interrupted_write INT
      The status should be success
      The output should equal 1
      The stderr should include 'cache write failed'
      The contents of file "$CACHE" should equal old
      The contents of file "$CACHE.keep" should equal sibling
    End

    It "cleans this writer's temporary file on TERM"
      interrupted_write() {
        local signal=$1
        print old > "$CACHE"
        chmod 600 "$CACHE"
        print sibling > "$CACHE.keep"
        mv() {
          zmodload zsh/system
          kill -s "$signal" "$sysparams[pid]"
          return 1
        }
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE"
        local -a leftovers=("$CACHE".*(N))
        print ${#leftovers}
      }
      When call interrupted_write TERM
      The status should be success
      The output should equal 1
      The stderr should include 'cache write failed'
      The contents of file "$CACHE" should equal old
      The contents of file "$CACHE.keep" should equal sibling
    End

    It 'warns when directory creation fails without losing the exported value'
      failed_write() {
        mkdir() { return 1; }
        env_cache MYTOK --ttl 0 --command 'builtin print tok_new' --file "$CACHE"
      }
      When call failed_write
      The status should be success
      The variable MYTOK should equal tok_new
      The stderr should include 'cache write failed'
      The path "$CACHE" should not be exist
    End

    It 'warns when temporary creation fails without losing the exported value'
      failed_write() {
        mktemp() { return 1; }
        env_cache MYTOK --ttl 0 --command 'builtin print tok_new' --file "$CACHE"
      }
      When call failed_write
      The status should be success
      The variable MYTOK should equal tok_new
      The stderr should include 'cache write failed'
      The path "$CACHE" should not be exist
    End

    It 'warns when writing fails without losing the exported value'
      failed_write() {
        print() { [[ "$*" == "-r -- tok_new" ]] && return 1; builtin print "$@"; }
        env_cache MYTOK --ttl 0 --command 'builtin print tok_new' --file "$CACHE"
      }
      When call failed_write
      The status should be success
      The variable MYTOK should equal tok_new
      The stderr should include 'cache write failed'
      The path "$CACHE" should not be exist
    End

    It 'preserves caller signal traps'
      caller_traps() {
        setopt LOCAL_TRAPS
        trap 'print caller' INT TERM HUP
        local before=$(trap)
        env_cache MYTOK --ttl 0 --command 'print tok_new' --file "$CACHE"
        [[ "$(trap)" == "$before" ]] && print preserved
      }
      When call caller_traps
      The status should be success
      The output should equal preserved
    End

    It 'invalidates only the exact cache file'
      invalidate_safely() {
        print cache > "$CACHE"
        print sibling > "$CACHE.keep"
        env_cache_invalidate MYTOK --file "$CACHE"
      }
      When call invalidate_safely
      The status should be success
      The path "$CACHE" should not be exist
      The contents of file "$CACHE.keep" should equal sibling
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
