# shellcheck shell=bash
# Fork-only: inherited data DIRECTORIES (applypass/firstmate).
#
# The inherited-material contract in bin/fm-config-inherit-lib.sh carries single
# files: config/<item> from FM_INHERITABLE_CONFIG and data/captain-shared.md.
# This library adds the one directory form: FM_INHERITABLE_DATA_DIRS names
# data-dir-relative directories (default: the private firstmate handbook), and
# each regular, non-symlink, non-hidden file directly inside such a directory of
# the primary home becomes the inherited item data/<dir>/<file>. A file with more
# than one hard link or over FM_HANDBOOK_INHERIT_MAX_BYTES (the remote
# receiver's byte bound) is skipped with a warning on both routes, so one such
# file never fails the push or blocks the other inherited items. Copies are
# read-only (mode 444) and written atomically (temp file + mv). Local and remote
# routes both derive their items from fm_handbook_inherit_items, so the sender
# and the receiver cannot disagree about which names are legal.
#
# Removal is receipt-based: the local route records the names it published in
# data/.<dir>.inherited, and the remote receiver keeps one generation record per
# file (bin/fm-remote-inherit-handbook.sh). A file the primary no longer has is
# removed from the secondmate only when it was published by inheritance, so a
# file a mate wrote into that directory is never touched. A source directory
# proven absent removes every previously inherited copy; an inspection error
# preserves the destination.

# Space-separated, data-dir-relative directory names. Override only in tests.
FM_INHERITABLE_DATA_DIRS="${FM_INHERITABLE_DATA_DIRS:-firstmate-handbook}"
FM_HANDBOOK_INHERIT_MODE="444"
FM_HANDBOOK_INHERIT_MAX_BYTES=1048576

# True when <name> is one safe path component: no '/', no '..', no leading '.'.
fm_handbook_inherit_name_ok() {  # <name>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# True when <dir> is a declared inheritable data directory.
fm_handbook_inherit_dir_declared() {  # <dir>
  local candidate
  for candidate in $FM_INHERITABLE_DATA_DIRS; do
    fm_handbook_inherit_name_ok "$candidate" || continue
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# True when <rel> is data/<declared-dir>/<safe-file> (a per-file item).
fm_handbook_inherit_rel_file_ok() {  # <rel>
  local rest dir file
  case "$1" in data/*/*) ;; *) return 1 ;; esac
  rest=${1#data/}
  dir=${rest%%/*}
  file=${rest#*/}
  fm_handbook_inherit_dir_declared "$dir" && fm_handbook_inherit_name_ok "$file"
}

# True when <rel> is data/<declared-dir> itself (the prune target).
fm_handbook_inherit_rel_dir_ok() {  # <rel>
  case "$1" in data/*/*) return 1 ;; data/*) ;; *) return 1 ;; esac
  fm_handbook_inherit_dir_declared "${1#data/}"
}

# The source files of one declared dir, names only, one per line, sorted.
# Prints nothing and returns 0 when the dir is proven absent; returns 1 when the
# dir cannot be inspected or is not a real directory. Warns on stderr for each
# hardlinked, oversize or unreadable file it skips.
fm_handbook_inherit_source_files() {  # <src-data> <dir>
  local path=$1/$2 present entry name bytes
  present=$(fm_config_source_present "$path") || return 1
  [ "$present" = 1 ] || return 0
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  for entry in "$path"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    fm_handbook_inherit_name_ok "$name" || continue
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    if [ "$(fm_inherit_file_link_count "$entry")" != 1 ]; then
      echo "fm-config-inherit: warning: skipping hardlinked inherited file $entry" >&2
      continue
    fi
    bytes=$(LC_ALL=C wc -c < "$entry" 2>/dev/null | tr -d ' ')
    case "$bytes" in
      ''|*[!0-9]*)
        echo "fm-config-inherit: warning: skipping unreadable inherited file $entry" >&2
        continue
        ;;
    esac
    if [ "$bytes" -gt "$FM_HANDBOOK_INHERIT_MAX_BYTES" ]; then
      echo "fm-config-inherit: warning: skipping inherited file over $FM_HANDBOOK_INHERIT_MAX_BYTES bytes $entry" >&2
      continue
    fi
    printf '%s\n' "$name"
  done | LC_ALL=C sort
}

# Per-file items for every declared dir of the primary: data/<dir>/<file> lines.
# Returns 1 when a declared dir exists but cannot be inspected.
fm_handbook_inherit_items() {  # <src-data>
  local dir name names
  for dir in $FM_INHERITABLE_DATA_DIRS; do
    fm_handbook_inherit_name_ok "$dir" || continue
    names=$(fm_handbook_inherit_source_files "$1" "$dir") || return 1
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf 'data/%s/%s\n' "$dir" "$name"
    done <<EOF
$names
EOF
  done
}

fm_handbook_inherit_receipt() {  # <dest-data> <dir>
  printf '%s/.%s.inherited\n' "$1" "$2"
}

# Names recorded as published into <dir>, one per line (empty without receipt).
fm_handbook_inherit_receipt_names() {  # <dest-data> <dir>
  local receipt name
  receipt=$(fm_handbook_inherit_receipt "$1" "$2")
  [ -e "$receipt" ] || [ -L "$receipt" ] || return 0
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  while IFS= read -r name || [ -n "$name" ]; do
    fm_handbook_inherit_name_ok "$name" && printf '%s\n' "$name"
  done < "$receipt"
}

fm_handbook_inherit_write_receipt() {  # <dest-data> <dir> <names-newline-list>
  local receipt tmp
  receipt=$(fm_handbook_inherit_receipt "$1" "$2")
  if [ -z "$3" ]; then
    rm -f "$receipt" 2>/dev/null
    return
  fi
  [ ! -L "$receipt" ] || rm -f "$receipt" 2>/dev/null || return 1
  tmp=$(mktemp "$1/.fm-inherit.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$3" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$receipt" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# True when <path> is absent or a lone regular file (no symlink, no hardlink).
fm_handbook_inherit_dest_file_safe() {  # <path>
  [ -e "$1" ] || [ -L "$1" ] || return 0
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(fm_inherit_file_link_count "$1")" = 1 ]
}

# Atomically write a read-only copy of <src> at <dest>.
fm_handbook_inherit_copy() {  # <src> <dest>
  local tmp parent=${2%/*}
  tmp=$(mktemp "$parent/.fm-inherit.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$1" "$tmp" 2>/dev/null \
    || ! chmod "$FM_HANDBOOK_INHERIT_MODE" "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$2" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_handbook_inherit_report() {  # <item> <status> <reason>
  record_inheritable_config_result "$@"
}

fm_handbook_inherit_fail() {  # <item> <path> <reason>
  warn_inheritable_config_error "$1" "$2" "$3"
  fm_handbook_inherit_report "$1" error "$3"
}

# Converge one declared dir: <src-data>/<dir> into <dest-data>/<dir>. Returns 1
# on any error; every error leaves the affected destination files unchanged.
fm_handbook_inherit_propagate_dir() {  # <src-data> <dest-data> <dir>
  local src_data=$1 dest_data=$2 dir=$3 dest_dir names published name item src dest rc=0 keep
  dest_dir=$dest_data/$dir
  item=data/$dir
  if ! names=$(fm_handbook_inherit_source_files "$src_data" "$dir"); then
    fm_handbook_inherit_fail "$item" "$src_data/$dir" "cannot inspect primary source directory"
    return 1
  fi
  if ! published=$(fm_handbook_inherit_receipt_names "$dest_data" "$dir"); then
    fm_handbook_inherit_fail "$item" "$dest_data" "inheritance receipt is unsafe"
    return 1
  fi
  if [ -L "$dest_dir" ] || { [ -e "$dest_dir" ] && [ ! -d "$dest_dir" ]; }; then
    fm_handbook_inherit_fail "$item" "$dest_dir" "destination is not a directory"
    return 1
  fi
  if [ -n "$names" ]; then
    mkdir -p "$dest_dir" 2>/dev/null || {
      fm_handbook_inherit_fail "$item" "$dest_dir" "cannot create destination directory"
      return 1
    }
  fi
  keep=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src=$src_data/$dir/$name
    dest=$dest_dir/$name
    item=data/$dir/$name
    if ! fm_handbook_inherit_dest_file_safe "$dest"; then
      fm_handbook_inherit_fail "$item" "$dest" "unsafe destination"
      rc=1
      # Keep claiming a name already published, so a later run can still prune it.
      case "
$published
" in *"
$name
"*) keep="$keep$name"$'\n' ;; esac
      continue
    fi
    if [ -f "$dest" ] && cmp -s "$src" "$dest" \
      && [ "$(fm_inherit_file_mode "$dest")" = "$FM_HANDBOOK_INHERIT_MODE" ]; then
      fm_handbook_inherit_report "$item" unchanged ""
    elif fm_handbook_inherit_copy "$src" "$dest"; then
      fm_handbook_inherit_report "$item" pushed ""
    else
      fm_handbook_inherit_fail "$item" "$dest" "failed to copy"
      rc=1
      case "
$published
" in *"
$name
"*) keep="$keep$name"$'\n' ;; esac
      continue
    fi
    keep="$keep$name"$'\n'
  done <<EOF
$names
EOF
  # Remove inherited copies the primary no longer has (never unrelated files).
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "
$names
" in *"
$name
"*) continue ;; esac
    dest=$dest_dir/$name
    item=data/$dir/$name
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      continue
    fi
    if [ -d "$dest" ] && [ ! -L "$dest" ]; then
      continue
    fi
    if rm -f "$dest" 2>/dev/null; then
      fm_handbook_inherit_report "$item" pushed "mirrored primary absence"
    else
      fm_handbook_inherit_fail "$item" "$dest" "failed to remove"
      rc=1
      keep="$keep$name"$'\n'
    fi
  done <<EOF
$published
EOF
  keep=$(printf '%s' "$keep" | sed '/^$/d' | LC_ALL=C sort -u)
  if [ "$keep" != "$(printf '%s' "$published" | sed '/^$/d' | LC_ALL=C sort -u)" ] \
    && [ -d "$dest_data" ] && ! fm_handbook_inherit_write_receipt "$dest_data" "$dir" "$keep"; then
    fm_handbook_inherit_fail "data/$dir" "$dest_data" "cannot write inheritance receipt"
    rc=1
  fi
  return "$rc"
}

# Converge every declared dir. Called from propagate_secondmate_inheritance.
propagate_handbook_dirs() {  # <src-data> <dest-data>
  local dir rc=0
  [ -n "$1" ] && [ -n "$2" ] || return 1
  for dir in $FM_INHERITABLE_DATA_DIRS; do
    fm_handbook_inherit_name_ok "$dir" || continue
    fm_handbook_inherit_propagate_dir "$1" "$2" "$dir" || rc=1
  done
  return "$rc"
}

# Remote route: after the per-file puts, tell the receiver which names the
# primary still has, so it removes the inherited copies of files that are gone
# (and, with an absent or empty source dir, all of them). <items> is the
# data/<dir>/<file> list the puts were planned from, so puts and prune agree.
# The receiver removes only files it published. Prints the receiver's output;
# non-zero on failure.
fm_handbook_inherit_push_prune() {  # <script-dir> <id> <generation> <items> <tmp-dir>
  local script_dir=$1 id=$2 generation=$3 items=$4 tmp=$5 dir list item bytes hash rc=0
  for dir in $FM_INHERITABLE_DATA_DIRS; do
    fm_handbook_inherit_name_ok "$dir" || continue
    list=$tmp/handbook-prune.$dir
    while IFS= read -r item; do
      case "$item" in "data/$dir/"*) printf '%s\n' "${item#"data/$dir/"}" ;; esac
    done > "$list" <<EOF
$items
EOF
    bytes=$(LC_ALL=C wc -c < "$list" | tr -d ' ')
    hash=$(fm_inherit_sha256 "$list") || return 1
    "$script_dir/fm-on.sh" --stdin "$id" fm-remote-inherit.sh prune "data/$dir" "$bytes" "$hash" "$generation" \
      < "$list" || rc=$?
  done
  return "$rc"
}
