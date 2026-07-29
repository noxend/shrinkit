#!/bin/zsh
# Pull the latest version and re-install it. Your settings and recordings are untouched.
set -eu
cd "${0:A:h}"
echo "==> Fetching the latest version..."
git pull --ff-only
echo "==> Re-installing..."
./install.sh
echo "==> Up to date."
