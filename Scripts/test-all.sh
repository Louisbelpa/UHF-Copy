#!/usr/bin/env bash
# Lance l'ensemble des suites testables sur la plateforme courante.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
LINKER_FLAGS=()

if [[ "$(uname)" == "Linux" ]]; then
  # Voir Scripts/build-sqlite-linux.sh : contournement propre à Linux.
  if [[ -d /opt/sqlite/lib ]]; then
    export LD_LIBRARY_PATH="/opt/sqlite/lib:${LD_LIBRARY_PATH:-}"
    LINKER_FLAGS=(-Xlinker -L/opt/sqlite/lib)
  else
    echo "⚠︎  /opt/sqlite absent : lancez d'abord Scripts/build-sqlite-linux.sh"
    echo "    (UHFStore et UHFSync ne pourront pas se lier)"
  fi
fi

for package in Packages/UHFCore Packages/UHFSources Packages/UHFStore Packages/UHFSync Packages/UHFViewModels; do
  echo ""
  echo "════ $package ($CONFIG)"
  swift test -c "$CONFIG" --package-path "$package" "${LINKER_FLAGS[@]}"
done

echo ""
echo "════ Tools/uhf-probe (compilation)"
swift build -c "$CONFIG" --package-path Tools/uhf-probe

if [[ "$(uname)" == "Darwin" ]]; then
  echo ""
  echo "════ Packages/UHFPlayback (compilation, Apple uniquement)"
  swift build -c "$CONFIG" --package-path Packages/UHFPlayback
fi
