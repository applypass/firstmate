#!/usr/bin/env bash
# Fork-only: behavior tests for inherited data directories (the firstmate handbook).
#
# The local route runs propagate_secondmate_inheritance into a test secondmate
# home. The remote route runs the real bin/fm-remote-inherit-push.sh (sender)
# against the real bin/fm-remote-inherit.sh (receiver) through a fake fm-on that
# executes the receiver in a second test home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_INHERITABLE_DATA_DIRS=firstmate-handbook
export FM_INHERITABLE_DATA_DIRS
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-handbook-inherit)
DIR=firstmate-handbook

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

new_pair() {  # <name> -> sets P (primary home) and S (secondmate home)
  local base=$TMP_ROOT/$1
  P=$base/primary
  S=$base/second
  mkdir -p "$P/data/$DIR" "$P/config" "$S/data" "$S/config"
  printf 'index v1\n' > "$P/data/$DIR/INDEX.md"
  printf 'topic a\n' > "$P/data/$DIR/topic-a.md"
}

push_local() {  # runs the local propagation; stdout+stderr in $LOCAL_OUT
  LOCAL_OUT=$(propagate_secondmate_inheritance "$P" "$S" "$P/config" "$P/data" 2>&1)
}

test_local_new_file_reaches_home_read_only() {
  new_pair local-new
  push_local || fail "propagation failed: $LOCAL_OUT"
  assert_equals "index v1" "$(cat "$S/data/$DIR/INDEX.md")" "INDEX.md should be copied"
  assert_equals "topic a" "$(cat "$S/data/$DIR/topic-a.md")" "topic-a.md should be copied"
  assert_equals 444 "$(file_mode "$S/data/$DIR/INDEX.md")" "copies should be read-only"
  printf 'topic b\n' > "$P/data/$DIR/topic-b.md"
  push_local || fail "second propagation failed: $LOCAL_OUT"
  assert_equals "topic b" "$(cat "$S/data/$DIR/topic-b.md")" "a new source file should reach the home"
  assert_equals 444 "$(file_mode "$S/data/$DIR/topic-b.md")" "the new copy should be read-only"
  pass "local: new file reaches the secondmate home read-only"
}

test_local_changed_file_updates() {
  new_pair local-change
  push_local || fail "propagation failed: $LOCAL_OUT"
  printf 'index v2\n' > "$P/data/$DIR/INDEX.md"
  push_local || fail "second propagation failed: $LOCAL_OUT"
  assert_equals "index v2" "$(cat "$S/data/$DIR/INDEX.md")" "a changed source file should update"
  assert_equals 444 "$(file_mode "$S/data/$DIR/INDEX.md")" "the updated copy should stay read-only"
  pass "local: changed file updates"
}

test_local_removed_file_removed_unrelated_kept() {
  new_pair local-remove
  push_local || fail "propagation failed: $LOCAL_OUT"
  printf 'mate notes\n' > "$S/data/$DIR/mate-notes.md"
  rm -f "$P/data/$DIR/topic-a.md"
  push_local || fail "second propagation failed: $LOCAL_OUT"
  [ ! -e "$S/data/$DIR/topic-a.md" ] || fail "a file removed from the primary should be removed from the home"
  assert_equals "mate notes" "$(cat "$S/data/$DIR/mate-notes.md")" "an unrelated file must be left alone"
  assert_equals "index v1" "$(cat "$S/data/$DIR/INDEX.md")" "remaining files stay"
  pass "local: removed file is removed and an unrelated file is kept"
}

test_local_source_dir_absent_removes_only_inherited() {
  new_pair local-dir-absent
  push_local || fail "propagation failed: $LOCAL_OUT"
  printf 'mate notes\n' > "$S/data/$DIR/mate-notes.md"
  rm -rf "$P/data/$DIR"
  push_local || fail "second propagation failed: $LOCAL_OUT"
  [ ! -e "$S/data/$DIR/INDEX.md" ] || fail "inherited INDEX.md should be removed"
  [ ! -e "$S/data/$DIR/topic-a.md" ] || fail "inherited topic-a.md should be removed"
  assert_equals "mate notes" "$(cat "$S/data/$DIR/mate-notes.md")" "the mate's own file must survive"
  pass "local: absent source dir removes only inherited copies"
}

test_local_skips_hidden_symlink_and_unsafe_names() {
  new_pair local-skip
  printf 'secret\n' > "$P/data/$DIR/.hidden.md"
  printf 'x\n' > "$TMP_ROOT/outside.md"
  ln -s "$TMP_ROOT/outside.md" "$P/data/$DIR/link.md"
  printf 'sp\n' > "$P/data/$DIR/has space.md"
  mkdir -p "$P/data/$DIR/sub"
  printf 'n\n' > "$P/data/$DIR/sub/nested.md"
  push_local || fail "propagation failed: $LOCAL_OUT"
  for n in .hidden.md link.md "has space.md" sub; do
    [ ! -e "$S/data/$DIR/$n" ] && [ ! -L "$S/data/$DIR/$n" ] || fail "$n must not be inherited"
  done
  pass "local: hidden, symlinked, oddly named and nested entries are not inherited"
}

test_local_inspection_error_preserves_destination() {
  new_pair local-error
  push_local || fail "propagation failed: $LOCAL_OUT"
  rm -rf "$P/data/$DIR"
  : > "$P/data/$DIR"
  if push_local; then fail "a source that is not a directory should be an error"; fi
  assert_equals "index v1" "$(cat "$S/data/$DIR/INDEX.md")" "destination must be preserved on inspection error"
  pass "local: inspection error preserves the destination"
}

test_local_symlinked_destination_refused() {
  new_pair local-unsafe
  mkdir -p "$TMP_ROOT/elsewhere"
  ln -s "$TMP_ROOT/elsewhere" "$S/data/$DIR"
  if push_local; then fail "a symlinked destination dir should be refused"; fi
  [ -z "$(ls -A "$TMP_ROOT/elsewhere")" ] || fail "nothing may be written through the symlink"
  pass "local: symlinked destination directory is refused"
}

# --- remote route -----------------------------------------------------------

setup_remote() {  # <name> -> sets P, R (remote home), SENDER (code root copy)
  local base=$TMP_ROOT/$1
  P=$base/primary
  R=$base/remote-home
  SENDER=$base/sender
  mkdir -p "$P/data/$DIR" "$P/config" "$P/state" "$R/data" "$R/config" "$R/state" "$SENDER"
  cp -R "$ROOT/bin" "$SENDER/bin"
  printf 'index v1\n' > "$P/data/$DIR/INDEX.md"
  printf 'topic a\n' > "$P/data/$DIR/topic-a.md"
  printf -- '- sm - sm delivery (host: h; root: %s; home: %s; scope: test; projects: alpha; added 2026-08-02)\n' \
    "$ROOT" "$R" > "$P/data/secondmates.md"
  # The fake fm-on runs the receiver exactly as the remote entrypoint would:
  # in the remote home, with the command's stdin.
  cat > "$SENDER/bin/fm-on.sh" <<SH
#!/usr/bin/env bash
set -eu
stdin=0
[ "\${1:-}" != --stdin ] || { stdin=1; shift; }
shift
cmd=\$1
shift
[ "\$stdin" = 1 ] || exec < /dev/null
FM_HOME='$R' exec env -i PATH="\$PATH" HOME="\$HOME" FM_HOME='$R' "$SENDER/bin/\$cmd" "\$@"
SH
  chmod +x "$SENDER/bin/fm-on.sh"
}

push_remote() {  # <generation>
  REMOTE_OUT=$(env FM_HOME="$P" FM_ROOT_OVERRIDE="$SENDER" "$SENDER/bin/fm-remote-inherit-push.sh" sm "$1" 2>&1)
}

test_remote_new_changed_removed() {
  setup_remote remote-flow
  push_remote 1 || fail "remote push failed: $REMOTE_OUT"
  assert_equals "index v1" "$(cat "$R/data/$DIR/INDEX.md")" "remote INDEX.md should arrive"
  assert_equals "topic a" "$(cat "$R/data/$DIR/topic-a.md")" "remote topic-a.md should arrive"
  assert_equals 444 "$(file_mode "$R/data/$DIR/INDEX.md")" "remote copies should be read-only"
  printf 'index v2\n' > "$P/data/$DIR/INDEX.md"
  printf 'topic b\n' > "$P/data/$DIR/topic-b.md"
  rm -f "$P/data/$DIR/topic-a.md"
  printf 'mate notes\n' > "$R/data/$DIR/mate-notes.md"
  push_remote 2 || fail "second remote push failed: $REMOTE_OUT"
  assert_equals "index v2" "$(cat "$R/data/$DIR/INDEX.md")" "remote changed file should update"
  assert_equals "topic b" "$(cat "$R/data/$DIR/topic-b.md")" "remote new file should arrive"
  [ ! -e "$R/data/$DIR/topic-a.md" ] || fail "remote removed file should be removed"
  assert_equals "mate notes" "$(cat "$R/data/$DIR/mate-notes.md")" "remote unrelated file must be left alone"
  push_remote 3 || fail "idempotent remote push failed: $REMOTE_OUT"
  pass "remote: new file arrives, changed file updates, removed file is removed, unrelated file kept"
}

test_remote_source_dir_absent_removes_only_inherited() {
  setup_remote remote-absent
  push_remote 1 || fail "remote push failed: $REMOTE_OUT"
  printf 'mate notes\n' > "$R/data/$DIR/mate-notes.md"
  rm -rf "$P/data/$DIR"
  push_remote 2 || fail "second remote push failed: $REMOTE_OUT"
  [ ! -e "$R/data/$DIR/INDEX.md" ] && [ ! -e "$R/data/$DIR/topic-a.md" ] || fail "inherited copies should be removed"
  assert_equals "mate notes" "$(cat "$R/data/$DIR/mate-notes.md")" "the mate's own file must survive"
  pass "remote: absent source dir removes only inherited copies"
}

test_receiver_refuses_traversal_and_undeclared_names() {
  setup_remote remote-refuse
  empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
  for rel in "data/$DIR/../captain.md" "data/$DIR/.hidden" "data/$DIR/a/b.md" "data/other-dir/x.md" "data/$DIR/..md/x" "data/$DIR/"; do
    for cmd in put absent; do
      if out=$(printf '' | env -i PATH="$PATH" HOME="$HOME" FM_HOME="$R" "$ROOT/bin/fm-remote-inherit.sh" "$cmd" "$rel" 0 "$empty_hash" 1 2>&1); then
        fail "receiver should refuse $cmd $rel: $out"
      fi
    done
  done
  [ ! -e "$R/data/captain.md" ] || fail "traversal must not write outside the declared directory"
  if out=$(printf '' | env -i PATH="$PATH" HOME="$HOME" FM_HOME="$R" "$ROOT/bin/fm-remote-inherit.sh" put "data/$DIR" 0 "$empty_hash" 1 2>&1); then
    fail "receiver should refuse a put on the directory itself: $out"
  fi
  printf '../x\n' > "$TMP_ROOT/keep"
  keep_hash=$(shasum -a 256 "$TMP_ROOT/keep" | awk '{print $1}')
  if out=$(env -i PATH="$PATH" HOME="$HOME" FM_HOME="$R" "$ROOT/bin/fm-remote-inherit.sh" prune "data/$DIR" "$(wc -c < "$TMP_ROOT/keep" | tr -d ' ')" "$keep_hash" 1 < "$TMP_ROOT/keep" 2>&1); then
    fail "receiver should refuse an unsafe kept name: $out"
  fi
  pass "remote: receiver refuses traversal, hidden, nested and undeclared names"
}

test_declared_items_are_per_file_and_data_dirs_override() {
  new_pair items
  items=$(fm_handbook_inherit_items "$P/data")
  assert_equals "data/$DIR/INDEX.md
data/$DIR/topic-a.md" "$items" "items should list one entry per file"
  items=$(FM_INHERITABLE_DATA_DIRS="other" fm_handbook_inherit_items "$P/data")
  assert_equals "" "$items" "an undeclared dir should yield nothing"
  pass "items: per-file listing follows FM_INHERITABLE_DATA_DIRS"
}

fm_test_run \
  test_local_new_file_reaches_home_read_only \
  test_local_changed_file_updates \
  test_local_removed_file_removed_unrelated_kept \
  test_local_source_dir_absent_removes_only_inherited \
  test_local_skips_hidden_symlink_and_unsafe_names \
  test_local_inspection_error_preserves_destination \
  test_local_symlinked_destination_refused \
  test_remote_new_changed_removed \
  test_remote_source_dir_absent_removes_only_inherited \
  test_receiver_refuses_traversal_and_undeclared_names \
  test_declared_items_are_per_file_and_data_dirs_override
