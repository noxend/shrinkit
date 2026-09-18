#!/bin/zsh
# Kept so every link and instruction that points here still works. The installer lives in the tool
# itself now, as "shrinkit setup", which is also how a Homebrew install registers its agent.
exec "${0:A:h}/shrinkit.sh" setup "$@"
