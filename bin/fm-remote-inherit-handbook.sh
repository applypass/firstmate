#!/usr/bin/env bash
# Fork-only: apply one inherited data-directory item inside the selected remote home.
#
# Usage (reached through bin/fm-remote-inherit.sh, which hands over every
# data/<declared-dir>/<file> and data/<declared-dir> request unchanged):
#   fm-remote-inherit-handbook.sh put    data/<dir>/<file> <bytes> <sha256> <generation> < file bytes
#   fm-remote-inherit-handbook.sh absent data/<dir>/<file> 0 <empty-sha256> <generation>
#   fm-remote-inherit-handbook.sh prune  data/<dir> <bytes> <sha256> <generation> < kept names
#
# <dir> must be declared in FM_INHERITABLE_DATA_DIRS (bin/fm-handbook-inherit-lib.sh)
# and <file> one safe name: no '/', no '..', no leading '.'. Files are written
# read-only (444) through a temp file and mv, with the same 4-line generation
# record the single-file receiver keeps. prune removes the files this receiver
# published (a put generation record exists) whose names are not in the kept list,
# so a file a mate wrote into the directory is never touched.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
MAX_BYTES=$FM_HANDBOOK_INHERIT_MAX_BYTES

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

[ "$#" -eq 5 ] || usage
COMMAND=$1
REL=$2
EXPECTED_BYTES=$3
EXPECTED_HASH=$4
GENERATION=$5
case "$COMMAND" in
  put|absent) fm_handbook_inherit_rel_file_ok "$REL" || die "path is not inherited material: $REL" ;;
  prune) fm_handbook_inherit_rel_dir_ok "$REL" || die "path is not inherited material: $REL" ;;
  *) usage ;;
esac
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes exceed the byte bound"
[ "$EXPECTED_BYTES" -le "$MAX_BYTES" ] || die "expected bytes exceed the byte bound"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"

HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
[ ! -L "$HOME_REAL/data" ] || die "inherited destination parent is a symlink"
case "$COMMAND" in
  prune) DIR_REL=$REL; BASE= ;;
  *) DIR_REL=$(dirname "$REL"); BASE=$(basename "$REL") ;;
esac
PARENT="$HOME_REAL/$DIR_REL"
[ ! -L "$PARENT" ] || die "inherited destination parent is a symlink"
mkdir -p "$PARENT" || die "cannot create inherited destination parent"
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" && pwd -P)
[ "$PARENT_REAL" = "$HOME_REAL/$DIR_REL" ] || die "inherited destination escapes FM_HOME"

LOCK="$PARENT_REAL/.fm-inherit-${BASE:-.dir}.lock"
fm_lock_acquire_wait "$LOCK" || die "cannot lock inherited destination"
TMP=
GENERATION_TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ -z "$GENERATION_TMP" ] || rm -f -- "$GENERATION_TMP"
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT

# generation_state <name> sets REC_GENERATION and REC_COMMAND from the record.
REC_GENERATION=
REC_COMMAND=
REC_BYTES=
REC_HASH=
read_generation() {
  local file="$PARENT_REAL/.fm-inherit-$1.generation"
  REC_GENERATION=; REC_COMMAND=; REC_BYTES=; REC_HASH=
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || die "inheritance generation record is unsafe"
    {
      IFS= read -r REC_GENERATION \
        && IFS= read -r REC_BYTES \
        && IFS= read -r REC_HASH \
        && IFS= read -r REC_COMMAND \
        && ! IFS= read -r
    } < "$file" || die "inheritance generation record is malformed"
    case "$REC_GENERATION" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
    [ "${#REC_GENERATION}" -le 18 ] || die "inheritance generation record is malformed"
    case "$REC_BYTES" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
    case "$REC_HASH" in ''|*[!A-Fa-f0-9]*) die "inheritance generation record is malformed" ;; esac
    [ "${#REC_HASH}" -eq 64 ] || die "inheritance generation record is malformed"
    case "$REC_COMMAND" in put|absent) ;; *) die "inheritance generation record is malformed" ;; esac
  fi
}

write_generation() {  # <name> <generation> <bytes> <hash> <command>
  GENERATION_TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit-generation.XXXXXX") \
    || die "cannot stage inheritance generation"
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" > "$GENERATION_TMP" \
    || die "cannot write inheritance generation"
  chmod 600 "$GENERATION_TMP" || die "cannot secure inheritance generation"
  mv -f -- "$GENERATION_TMP" "$PARENT_REAL/.fm-inherit-$1.generation" || die "cannot publish inheritance generation"
  GENERATION_TMP=
}

# commit_generation returns 1 when this exact payload was already committed.
commit_generation() {
  read_generation "$BASE"
  if [ -n "$REC_GENERATION" ]; then
    if [ "$REC_GENERATION" -gt "$GENERATION" ]; then
      die "inheritance write generation is superseded"
    fi
    if [ "$REC_GENERATION" -eq "$GENERATION" ]; then
      [ "$REC_BYTES" = "$EXPECTED_BYTES" ] \
        && [ "$REC_HASH" = "$EXPECTED_HASH" ] \
        && [ "$REC_COMMAND" = "$COMMAND" ] \
        || die "inheritance generation conflicts with its committed payload"
      return 0
    fi
  fi
  write_generation "$BASE" "$GENERATION" "$EXPECTED_BYTES" "$EXPECTED_HASH" "$COMMAND"
}

dest_safe() {  # <path>
  [ ! -L "$1" ] || die "inherited destination is a symlink"
  if [ -e "$1" ]; then
    [ -f "$1" ] || die "inherited destination is not a regular file"
    [ "$(fm_inherit_file_link_count "$1")" = 1 ] || die "inherited destination is hardlinked"
  fi
}

case "$COMMAND" in
  put)
    DEST="$PARENT_REAL/$BASE"
    dest_safe "$DEST"
    TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit.XXXXXX") || die "cannot stage inherited material"
    head -c "$((MAX_BYTES + 1))" > "$TMP" || die "cannot read inherited material"
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    [ "$BYTES" -le "$MAX_BYTES" ] || die "inherited material exceeds the byte bound"
    [ "$BYTES" -eq "$EXPECTED_BYTES" ] || die "inherited material length does not match its commitment"
    ACTUAL_HASH=$(sha256_file "$TMP") || die "cannot hash inherited material"
    [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "inherited material digest does not match its commitment"
    commit_generation
    if [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
      chmod "$FM_HANDBOOK_INHERIT_MODE" "$DEST" || die "cannot restore read-only mode"
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    chmod "$FM_HANDBOOK_INHERIT_MODE" "$TMP" || die "cannot secure inherited material"
    mv -f -- "$TMP" "$DEST" || die "cannot publish inherited material"
    TMP=
    printf 'pushed: %s\n' "$REL"
    ;;
  absent)
    DEST="$PARENT_REAL/$BASE"
    dest_safe "$DEST"
    [ "$EXPECTED_BYTES" -eq 0 ] || die "absent inheritance has a nonzero payload commitment"
    commit_generation
    if [ ! -e "$DEST" ]; then
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    rm -f -- "$DEST" || die "cannot remove absent inherited material"
    printf 'removed: %s\n' "$REL"
    ;;
  prune)
    TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit.XXXXXX") || die "cannot stage kept-name list"
    head -c "$((MAX_BYTES + 1))" > "$TMP" || die "cannot read kept-name list"
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    [ "$BYTES" -eq "$EXPECTED_BYTES" ] || die "kept-name list length does not match its commitment"
    ACTUAL_HASH=$(sha256_file "$TMP") || die "cannot hash kept-name list"
    [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "kept-name list digest does not match its commitment"
    KEPT="
"
    while IFS= read -r name || [ -n "$name" ]; do
      [ -n "$name" ] || continue
      fm_handbook_inherit_name_ok "$name" || die "kept name is not a safe file name: $name"
      KEPT="$KEPT$name
"
    done < "$TMP"
    removed=0
    for record in "$PARENT_REAL"/.fm-inherit-*.generation; do
      [ -e "$record" ] || [ -L "$record" ] || continue
      name=${record##*/.fm-inherit-}
      name=${name%.generation}
      fm_handbook_inherit_name_ok "$name" || continue
      case "$KEPT" in *"
$name
"*) continue ;; esac
      BASE=$name
      read_generation "$name"
      [ "$REC_COMMAND" = put ] || continue
      [ "$REC_GENERATION" -le "$GENERATION" ] || continue
      DEST="$PARENT_REAL/$name"
      dest_safe "$DEST"
      if [ -e "$DEST" ]; then
        rm -f -- "$DEST" || die "cannot remove absent inherited material"
        printf 'removed: %s/%s\n' "$REL" "$name"
        removed=$((removed + 1))
      fi
      write_generation "$name" "$GENERATION" 0 \
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 absent
    done
    [ "$removed" -gt 0 ] || printf 'unchanged: %s\n' "$REL"
    ;;
esac
