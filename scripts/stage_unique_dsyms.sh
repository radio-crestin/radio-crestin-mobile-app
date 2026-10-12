#!/usr/bin/env bash
# Copies the dSYM bundles in <src> to <dst>, one bundle per debug-info UUID.
#
# Xcode archives can hold byte-identical copies such as
# "FirebaseCore.framework 1.dSYM" next to "FirebaseCore.framework.dSYM".
# They share a UUID, and PostHog rejects an upload batch that repeats one
# ("Duplicate chunk IDs"), so only the first bundle per UUID is kept —
# preferring the name without the " N" copy suffix.
#
#   scripts/stage_unique_dsyms.sh <src-dir> <dst-dir>

set -euo pipefail

src="$1"
dst="$2"
rm -rf "$dst"
mkdir -p "$dst"

shopt -s nullglob
all=("$src"/*.dSYM)
copy_suffix=' [0-9]+\.dSYM$'
ordered=()
for d in "${all[@]}"; do [[ "$d" =~ $copy_suffix ]] || ordered+=("$d"); done
for d in "${all[@]}"; do [[ "$d" =~ $copy_suffix ]] && ordered+=("$d"); done

seen=" "
kept=0
skipped=0
for d in "${ordered[@]}"; do
  uuids="$(dwarfdump --uuid "$d" 2>/dev/null | awk '{print $2}' | sort | tr '\n' ',')"
  if [ -n "$uuids" ]; then
    if [[ "$seen" == *" $uuids "* ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    seen="$seen$uuids "
  fi
  # APFS clone: instant and takes no extra space; plain copy elsewhere.
  cp -cR "$d" "$dst/" 2>/dev/null || cp -R "$d" "$dst/"
  kept=$((kept + 1))
done

echo "Staged $kept dSYMs in $dst ($skipped duplicate copies skipped)"
