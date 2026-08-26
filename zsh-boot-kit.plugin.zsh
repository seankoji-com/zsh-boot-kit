# zsh-boot-kit — four mechanisms for a shell that starts fast and stays current.
#
#   startup-log      per-phase timing, written on the first prompt
#   env-cache        cache an expensive env var in a 0600 file with a TTL
#   lazy-plugins     load an oh-my-zsh plugin the first time you use it
#   outdated-banner  "N things are out of date, upgrade now?" for free
#
# Source this yourself near the top of .zshrc. Do NOT add it to plugins=().
# oh-my-zsh sources plugins from inside oh-my-zsh.sh, which is far too late:
# lazy_plugins has to run before the eager plugin list is processed, and the
# banner should print before the shell spends time on anything else.
#
#     zmodload zsh/datetime
#     ZSH_BOOT_KIT_T0=$EPOCHREALTIME          # start the clock first
#     source ~/.oh-my-zsh_custom/plugins/zsh-boot-kit/zsh-boot-kit.plugin.zsh
#
# See README.md for the full wiring.

0=${(%):-%N}
ZSH_BOOT_KIT_DIR=${0:A:h}

source "$ZSH_BOOT_KIT_DIR/lib/startup-log.zsh"
source "$ZSH_BOOT_KIT_DIR/lib/env-cache.zsh"
source "$ZSH_BOOT_KIT_DIR/lib/lazy-plugins.zsh"
source "$ZSH_BOOT_KIT_DIR/lib/outdated-banner.zsh"

boot_kit_timer_start
