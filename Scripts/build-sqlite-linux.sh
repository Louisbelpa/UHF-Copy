#!/usr/bin/env bash
# Compile un SQLite utilisable par GRDB sous Linux.
#
# Pourquoi : GRDB s'appuie sur `sqlite3_snapshot_*`, que la libsqlite3 livrée par
# Ubuntu n'expose pas (elle est compilée sans SQLITE_ENABLE_SNAPSHOT). La SQLite
# d'Apple, elle, l'active — le problème n'existe donc **que** sous Linux, et n'affecte
# ni l'app iOS/tvOS ni un développement sur Mac. Ce script n'existe que pour permettre
# à la CI Linux de tester UHFStore et UHFSync.
set -euo pipefail

VERSION="${SQLITE_VERSION:-3460100}"
PREFIX="${SQLITE_PREFIX:-/opt/sqlite}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ SQLite $VERSION vers $PREFIX"
curl -sSL -o "$WORK/sqlite.zip" \
  "https://www.sqlite.org/2024/sqlite-amalgamation-${VERSION}.zip"
unzip -oq "$WORK/sqlite.zip" -d "$WORK"

cd "$WORK/sqlite-amalgamation-${VERSION}"
gcc -O2 -fPIC -shared -o libsqlite3.so sqlite3.c \
  -DSQLITE_ENABLE_SNAPSHOT \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_ENABLE_FTS4 \
  -DSQLITE_ENABLE_RTREE \
  -DSQLITE_ENABLE_COLUMN_METADATA \
  -DSQLITE_ENABLE_PREUPDATE_HOOK \
  -DSQLITE_ENABLE_SESSION \
  -DSQLITE_ENABLE_JSON1 \
  -DSQLITE_THREADSAFE=1 \
  -DHAVE_USLEEP \
  -lpthread -lm

mkdir -p "$PREFIX/lib"
cp libsqlite3.so "$PREFIX/lib/libsqlite3.so.0"
ln -sf "$PREFIX/lib/libsqlite3.so.0" "$PREFIX/lib/libsqlite3.so"

echo "→ OK. Utiliser ensuite :"
echo "   export LD_LIBRARY_PATH=$PREFIX/lib:\$LD_LIBRARY_PATH"
echo "   swift test -Xlinker -L$PREFIX/lib"
