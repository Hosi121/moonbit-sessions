#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -sm)" != "Linux x86_64" ]]; then
  echo 'This checksum-pinned installer supports Linux x86_64. Install MoonBit 0.10.14+7d59c7ec9 for your platform using the official installer.' >&2
  exit 1
fi
moon_version='0.10.14%2B7d59c7ec9'
moon_local="$PWD/.tools/moon"
if [[ -x "$moon_local/bin/moonc" ]] && [[ "$("$moon_local/bin/moonc" -v)" == *'v0.10.14+7d59c7ec9'* ]]; then
  echo 'Pinned MoonBit compiler is already installed.'
  exit 0
fi
mkdir -p .tools/downloads "$moon_local/lib"
curl -fsSL "https://cli.moonbitlang.com/binaries/$moon_version/moonbit-linux-x86_64.tar.gz" -o .tools/downloads/moon.tar.gz
curl -fsSL "https://cli.moonbitlang.com/cores/core-$moon_version.tar.gz" -o .tools/downloads/core.tar.gz
echo '9226694de9ff978db1ecf820b7710c4224e84ec7a76b19a222d96f0cd4e31b6a  .tools/downloads/moon.tar.gz' | sha256sum -c -
echo '6f18b8fdea18f85e628a75e4a1bd3977c5a5c9c6a836fd8824192b0e6bd91b14  .tools/downloads/core.tar.gz' | sha256sum -c -
tar xf .tools/downloads/moon.tar.gz -C "$moon_local"
tar xf .tools/downloads/core.tar.gz -C "$moon_local/lib"
chmod +x "$moon_local"/bin/moon "$moon_local"/bin/moonc "$moon_local"/bin/moonfmt "$moon_local"/bin/mooninfo "$moon_local"/bin/moon-ide "$moon_local"/bin/moonrun "$moon_local"/bin/internal/tcc
node scripts/moon.mjs -C .tools/moon/lib/core bundle --warn-list -a --all
node scripts/moon.mjs version
