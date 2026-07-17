# Fleet Radar Build Week Demo Runbook

This runbook fixes the three-session fixture and recording cues for the Fleet Radar demo. Run it
from a clean DevIsland checkout on macOS 15+ after installing the bridge for Codex CLI. The Git
commands below only create and modify disposable worktrees; Fleet itself remains read-only.

## Fixed Fixture

| Card display name | Branch | Worktree | Changed file | Demo role |
|---|---|---|---|---|
| `Priority Approval` | `demo/fleet-priority` | `/tmp/devisland-fleet-priority` | `README.md` | overlap and pending approval |
| `Overlap Peer` | `demo/fleet-overlap` | `/tmp/devisland-fleet-overlap` | `README.md` | overlap peer |
| `Independent Observer` | `demo/fleet-observer` | `/tmp/devisland-fleet-observer` | `CONTRIBUTING.md` | dirty, but no overlap |

The overlap path is exactly `README.md`. `CONTRIBUTING.md` proves that a third dirty worktree does
not receive a false overlap warning.

## Prepare Before Recording

From the clean checkout, run this fail-fast setup. It refuses to reuse an existing branch, path,
registered worktree, or approval marker:

```bash
(
set -euo pipefail

STATE_FILE=/tmp/devisland-fleet-demo-state
PRIORITY_PATH=/tmp/devisland-fleet-priority
OVERLAP_PATH=/tmp/devisland-fleet-overlap
OBSERVER_PATH=/tmp/devisland-fleet-observer
PRIORITY_BRANCH=demo/fleet-priority
OVERLAP_BRANCH=demo/fleet-overlap
OBSERVER_BRANCH=demo/fleet-observer
PRIORITY_SUFFIX=$'\nFleet priority demo change\n'
OVERLAP_SUFFIX=$'\nFleet overlap peer demo change\n'
OBSERVER_SUFFIX=$'\nFleet independent demo change\n'

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
COMMON_GIT_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
BASE_SHA="$(git rev-parse HEAD)"

STATE_CREATED=0
CREATED_PRIORITY=0
CREATED_OVERLAP=0
CREATED_OBSERVER=0

print_state() {
  printf 'common_git_dir=%s\nbase_sha=%s\n' "$COMMON_GIT_DIR" "$BASE_SHA"
}

is_registered_worktree() {
  local worktree_path="$1"
  local list
  list="$(git worktree list --porcelain)"
  grep -Fqx "worktree $worktree_path" <<<"$list" \
    || grep -Fqx "worktree /private$worktree_path" <<<"$list"
}

verify_demo_content() {
  local worktree_path="$1"
  local file="$2"
  local suffix="$3"
  local actual_hash
  local expected_hash
  test -f "$worktree_path/$file" && test ! -L "$worktree_path/$file" || return 1
  test -z "$(git -c core.fsmonitor=false -C "$worktree_path" diff \
    --no-ext-diff --summary -- "$file")" || return 1
  actual_hash="$(git hash-object "$worktree_path/$file")"
  expected_hash="$({
    git -C "$worktree_path" show "HEAD:$file"
    printf '%s' "$suffix"
  } | git hash-object --stdin)"
  test "$actual_hash" = "$expected_hash" \
    && cmp -s "$worktree_path/$file" <(
      git -C "$worktree_path" show "HEAD:$file"
      printf '%s' "$suffix"
    )
}

verify_rollback_candidate() {
  local worktree_path="$1"
  local branch="$2"
  local file="$3"
  local suffix="$4"
  local worktree_status

  git show-ref --verify --quiet "refs/heads/$branch" || return 1
  test "$(git rev-parse "$branch")" = "$BASE_SHA" || return 1
  is_registered_worktree "$worktree_path" || return 1
  test -d "$worktree_path" && test ! -L "$worktree_path" || return 1
  test "$(git -C "$worktree_path" rev-parse --path-format=absolute --git-common-dir)" \
    = "$COMMON_GIT_DIR" || return 1
  test "$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD)" = "$branch" \
    || return 1
  test "$(git -C "$worktree_path" rev-parse HEAD)" = "$BASE_SHA" || return 1
  worktree_status="$(git -C "$worktree_path" -c core.fsmonitor=false status \
    --porcelain=v1 --untracked-files=all)"
  if test -n "$worktree_status"; then
    test "$worktree_status" = " M $file" || return 1
    verify_demo_content "$worktree_path" "$file" "$suffix" || return 1
  fi
}

verify_state_file() {
  test -f "$STATE_FILE" && test ! -L "$STATE_FILE" \
    && test "$(stat -f '%Lp' "$STATE_FILE")" = 600 \
    && cmp -s "$STATE_FILE" <(print_state)
}

remove_rollback_candidate() {
  local worktree_path="$1"
  local branch="$2"
  local file="$3"
  local suffix="$4"
  local worktree_status

  verify_rollback_candidate "$worktree_path" "$branch" "$file" "$suffix" || return 1
  if is_registered_worktree "$worktree_path"; then
    worktree_status="$(git -C "$worktree_path" -c core.fsmonitor=false status \
      --porcelain=v1 --untracked-files=all)"
    if test -n "$worktree_status"; then
      git -C "$worktree_path" restore -- "$file" || return 1
    fi
    test -z "$(git -C "$worktree_path" -c core.fsmonitor=false status \
      --porcelain=v1 --untracked-files=all)" || return 1
    git worktree remove "$worktree_path" || return 1
  fi
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    test "$(git rev-parse "$branch")" = "$BASE_SHA" || return 1
    git branch -d "$branch" || return 1
  fi
}

rollback_setup() {
  local original_status="$?"
  local rollback_safe=1
  trap - EXIT
  set +e

  if test "$CREATED_PRIORITY" -eq 1; then
    verify_rollback_candidate \
      "$PRIORITY_PATH" "$PRIORITY_BRANCH" README.md "$PRIORITY_SUFFIX" \
      || rollback_safe=0
  fi
  if test "$CREATED_OVERLAP" -eq 1; then
    verify_rollback_candidate \
      "$OVERLAP_PATH" "$OVERLAP_BRANCH" README.md "$OVERLAP_SUFFIX" \
      || rollback_safe=0
  fi
  if test "$CREATED_OBSERVER" -eq 1; then
    verify_rollback_candidate \
      "$OBSERVER_PATH" "$OBSERVER_BRANCH" CONTRIBUTING.md "$OBSERVER_SUFFIX" \
      || rollback_safe=0
  fi
  if test "$STATE_CREATED" -eq 1; then
    verify_state_file || rollback_safe=0
  fi

  if test "$rollback_safe" -eq 1; then
    if test "$CREATED_OBSERVER" -eq 1; then
      remove_rollback_candidate \
        "$OBSERVER_PATH" "$OBSERVER_BRANCH" CONTRIBUTING.md "$OBSERVER_SUFFIX" \
        || rollback_safe=0
    fi
    if test "$CREATED_OVERLAP" -eq 1; then
      remove_rollback_candidate \
        "$OVERLAP_PATH" "$OVERLAP_BRANCH" README.md "$OVERLAP_SUFFIX" \
        || rollback_safe=0
    fi
    if test "$CREATED_PRIORITY" -eq 1; then
      remove_rollback_candidate \
        "$PRIORITY_PATH" "$PRIORITY_BRANCH" README.md "$PRIORITY_SUFFIX" \
        || rollback_safe=0
    fi
    if test "$rollback_safe" -eq 1 && test "$STATE_CREATED" -eq 1; then
      verify_state_file && rm -- "$STATE_FILE" \
        || rollback_safe=0
    fi
  fi

  if test "$rollback_safe" -ne 1; then
    echo "Automatic rollback stopped: an asset no longer matches this setup invocation." >&2
    echo "Review the demo branches, worktrees, and $STATE_FILE manually; nothing unexpected was force-removed." >&2
  fi
  exit "$original_status"
}

trap rollback_setup EXIT

test -z "$(git -c core.fsmonitor=false status --porcelain=v1)" || {
  echo "Source checkout is not clean; stop and review it manually." >&2
  exit 1
}

for branch in "$PRIORITY_BRANCH" "$OVERLAP_BRANCH" "$OBSERVER_BRANCH"; do
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Branch already exists: $branch" >&2
    exit 1
  fi
done

WORKTREE_LIST="$(git worktree list --porcelain)"
for worktree_path in \
  "$PRIORITY_PATH" \
  "$OVERLAP_PATH" \
  "$OBSERVER_PATH"; do
  test ! -L "$worktree_path" || {
    echo "Path is a symlink: $worktree_path" >&2
    exit 1
  }
  test ! -e "$worktree_path" || {
    echo "Path already exists: $worktree_path" >&2
    exit 1
  }
  if grep -Fqx "worktree $worktree_path" <<<"$WORKTREE_LIST" \
    || grep -Fqx "worktree /private$worktree_path" <<<"$WORKTREE_LIST"; then
    echo "Worktree path is already registered: $worktree_path" >&2
    exit 1
  fi
done

test ! -L "$STATE_FILE" || {
  echo "Fixture state is a symlink: $STATE_FILE" >&2
  exit 1
}
test ! -e "$STATE_FILE" || {
  echo "Fixture state already exists: $STATE_FILE" >&2
  exit 1
}
test ! -L /tmp/devisland-fleet-demo-approval-marker || {
  echo "Approval marker is a symlink; stop and review it manually." >&2
  exit 1
}
test ! -e /tmp/devisland-fleet-demo-approval-marker || {
  echo "Approval marker already exists; stop and review it manually." >&2
  exit 1
}

(umask 077; set -o noclobber; print_state > "$STATE_FILE")
STATE_CREATED=1

report_failed_add() {
  local branch="$1"
  local worktree_path="$2"
  echo "git worktree add failed; its branch/path ownership is unknown and was not auto-removed." >&2
  echo "Review only; do not force-remove without checking:" >&2
  echo "  git show-ref --verify refs/heads/$branch" >&2
  echo "  git worktree list --porcelain" >&2
  echo "  ls -ld -- $worktree_path" >&2
}

if ! git worktree add -b "$PRIORITY_BRANCH" "$PRIORITY_PATH" "$BASE_SHA"; then
  report_failed_add "$PRIORITY_BRANCH" "$PRIORITY_PATH"
  exit 1
fi
CREATED_PRIORITY=1
if ! git worktree add -b "$OVERLAP_BRANCH" "$OVERLAP_PATH" "$BASE_SHA"; then
  report_failed_add "$OVERLAP_BRANCH" "$OVERLAP_PATH"
  exit 1
fi
CREATED_OVERLAP=1
if ! git worktree add -b "$OBSERVER_BRANCH" "$OBSERVER_PATH" "$BASE_SHA"; then
  report_failed_add "$OBSERVER_BRANCH" "$OBSERVER_PATH"
  exit 1
fi
CREATED_OBSERVER=1

printf '%s' "$PRIORITY_SUFFIX" >> "$PRIORITY_PATH/README.md"
printf '%s' "$OVERLAP_SUFFIX" >> "$OVERLAP_PATH/README.md"
printf '%s' "$OBSERVER_SUFFIX" >> "$OBSERVER_PATH/CONTRIBUTING.md"

trap - EXIT
)
```

Open one Codex CLI session in each worktree and leave all three running. In **Session Center >
Sessions**, use each row's context menu to rename the sessions to the exact display names in the
table. To copy the full `Priority Approval` session ID, expand the notch session list, open that
session row's context menu, then choose **Terminal Info > ID: `<full session id>`**. Export the
copied actual value in its worktree terminal:

```bash
cd /tmp/devisland-fleet-priority
export PRIORITY_SESSION_ID='<paste the actual Priority Approval session ID>'
```

The value must come from the running session. It is a local demo input, not the Codex `/feedback`
Session ID used as submission evidence. Do not publish a placeholder or synthetic value.

Open **Session Center > Fleet**, choose **Refresh**, and check the starting frame:

- all three named cards are visible;
- `Priority Approval` and `Overlap Peer` are dirty and show a `README.md` overlap with each other;
- `Independent Observer` is dirty and has no overlap badge;
- no approval is pending before recording starts.

Before recording, enable **Notch Auto-Expand** and the **Approval Request** expand trigger, set the
permission timeout to at least 30 seconds, and remove persistent or session rules that would match
the demo `shell` request. Also confirm that the priority terminal is not frontmost when the request
reaches DevIsland.

## Recording Cues

Use these cues to keep the edited video near 2 minutes 45 seconds and below the 3-minute limit.

1. **0:00–0:20 — Problem.** Show the three Codex sessions and explain that parallel work makes it
   hard to see where intervention is needed or which worktrees touch the same paths.
2. **0:20–0:50 — Fleet overview.** Open Fleet and point to provider, branch, dirty count, and the
   local-only analysis.
3. **0:50–1:20 — Overlap.** Open the overlap details on `Priority Approval`. Show peer branch
   `demo/fleet-overlap` and path `README.md`; say that path overlap is an early warning, not proof of
   a merge conflict. Point out that `Independent Observer` is dirty without an overlap warning.
4. **At 1:20 — Pending approval.** In the prepared priority terminal, run:

   ```bash
   SESSION_ID="$PRIORITY_SESSION_ID" ./scripts/test-hook.sh --cli codex codex-permission shell "touch /tmp/devisland-fleet-demo-approval-marker"
   ```

   Use the script's default five-second countdown to switch away from the priority terminal and
   show Fleet before the request arrives. The test hook submits a permission request against the
   actual running session and waits for DevIsland; it does not execute the displayed `touch`
   command. Leave the request pending for about 20 seconds. Show that `Priority Approval` moves to
   the top while the notch approval remains available, then approve or deny it by **1:50** so the
   recording terminal unblocks. If the script returns immediately, inspect its printed response:
   a matching rule, a still-frontmost terminal, or app/bridge connection fallback can all bypass
   the pending UI. Correct that cause before repeating the cue.
5. **1:50–2:15 — Context restore.** Choose **Show Detail** and show the expanded Island selecting
   the `Priority Approval` session without focusing its terminal. Return to Session Center, then
   choose **Focus Terminal** once and show the exact priority terminal becoming active.
6. **2:15–2:45 — Technical boundary and result.** Summarize porcelain v2 parsing, actor caching,
   bounded `/usr/bin/git` reads, no network, no Git writes, and the final one-glance outcome.

If demonstrating sub-agent attention as an optional variation, use a real child session from the
running provider and leave its approval pending briefly. Do not present a synthetic child session
ID as Build Week provenance.

## Cleanup

Exit the three Codex sessions first. If a permission remains pending, resolve it before closing
DevIsland. Then run this guarded cleanup from the original checkout. It verifies repository and
branch identity before restoring only the known files, and stops rather than force-removing any
unexpected edits:

```bash
(
set -euo pipefail

STATE_FILE=/tmp/devisland-fleet-demo-state
PRIORITY_PATH=/tmp/devisland-fleet-priority
OVERLAP_PATH=/tmp/devisland-fleet-overlap
OBSERVER_PATH=/tmp/devisland-fleet-observer
PRIORITY_BRANCH=demo/fleet-priority
OVERLAP_BRANCH=demo/fleet-overlap
OBSERVER_BRANCH=demo/fleet-observer
PRIORITY_SUFFIX=$'\nFleet priority demo change\n'
OVERLAP_SUFFIX=$'\nFleet overlap peer demo change\n'
OBSERVER_SUFFIX=$'\nFleet independent demo change\n'

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
ACTUAL_COMMON_GIT_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"

test -f "$STATE_FILE" && test ! -L "$STATE_FILE" || {
  echo "Missing fixture state: $STATE_FILE" >&2
  exit 1
}
test "$(stat -f '%Lp' "$STATE_FILE")" = 600 || {
  echo "Fixture state permissions are not 0600: $STATE_FILE" >&2
  exit 1
}

exec 3< "$STATE_FILE"
IFS= read -r common_git_line <&3
IFS= read -r base_sha_line <&3
if IFS= read -r unexpected_line <&3; then
  echo "Unexpected extra data in $STATE_FILE" >&2
  exit 1
fi
exec 3<&-

case "$common_git_line" in
  common_git_dir=*) EXPECTED_COMMON_GIT_DIR="${common_git_line#common_git_dir=}" ;;
  *) echo "Malformed common_git_dir in $STATE_FILE" >&2; exit 1 ;;
esac
case "$base_sha_line" in
  base_sha=*) EXPECTED_BASE_SHA="${base_sha_line#base_sha=}" ;;
  *) echo "Malformed base_sha in $STATE_FILE" >&2; exit 1 ;;
esac

print_expected_state() {
  printf 'common_git_dir=%s\nbase_sha=%s\n' \
    "$EXPECTED_COMMON_GIT_DIR" "$EXPECTED_BASE_SHA"
}

cmp -s "$STATE_FILE" <(print_expected_state) || {
  echo "Fixture state bytes are not in the expected format." >&2
  exit 1
}
test "$ACTUAL_COMMON_GIT_DIR" = "$EXPECTED_COMMON_GIT_DIR" || {
  echo "Fixture state belongs to a different repository." >&2
  exit 1
}
git cat-file -e "$EXPECTED_BASE_SHA^{commit}"

verify_worktree() {
  local worktree_path="$1"
  local expected_branch="$2"
  local file="$3"
  local suffix="$4"
  local worktree_status
  local actual_hash
  local expected_hash
  test -d "$worktree_path" && test ! -L "$worktree_path" || {
    echo "Missing expected worktree: $worktree_path" >&2
    exit 1
  }
  local actual_common_git_dir
  actual_common_git_dir="$(git -C "$worktree_path" rev-parse \
    --path-format=absolute --git-common-dir)"
  test "$actual_common_git_dir" = "$EXPECTED_COMMON_GIT_DIR" || {
    echo "Refusing unexpected repository at $worktree_path" >&2
    exit 1
  }
  local actual_branch
  actual_branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD)"
  test "$actual_branch" = "$expected_branch" || {
    echo "Refusing unexpected branch at $worktree_path: $actual_branch" >&2
    exit 1
  }
  test "$(git -C "$worktree_path" rev-parse HEAD)" = "$EXPECTED_BASE_SHA" || {
    echo "Refusing worktree with changed HEAD at $worktree_path" >&2
    exit 1
  }
  worktree_status="$(git -C "$worktree_path" -c core.fsmonitor=false status \
    --porcelain=v1 --untracked-files=all)"
  test "$worktree_status" = " M $file" || {
    echo "Expected exactly one unstaged modification ($file) in $worktree_path." >&2
    exit 1
  }
  test -f "$worktree_path/$file" && test ! -L "$worktree_path/$file" || {
    echo "Demo leaf is not a regular non-symlink file: $worktree_path/$file" >&2
    exit 1
  }
  test -z "$(git -c core.fsmonitor=false -C "$worktree_path" diff \
    --no-ext-diff --summary -- "$file")" || {
    echo "Demo leaf mode or type changed: $worktree_path/$file" >&2
    exit 1
  }
  actual_hash="$(git hash-object "$worktree_path/$file")"
  expected_hash="$({
    git -C "$worktree_path" show "HEAD:$file"
    printf '%s' "$suffix"
  } | git hash-object --stdin)"
  test "$actual_hash" = "$expected_hash" || {
    echo "Demo file hash differs from HEAD plus the exact suffix: $worktree_path/$file" >&2
    exit 1
  }
  cmp -s "$worktree_path/$file" <(
    git -C "$worktree_path" show "HEAD:$file"
    printf '%s' "$suffix"
  ) || {
    echo "Demo file bytes differ from HEAD plus the exact suffix: $worktree_path/$file" >&2
    exit 1
  }
}

verify_worktree "$PRIORITY_PATH" "$PRIORITY_BRANCH" README.md "$PRIORITY_SUFFIX"
verify_worktree "$OVERLAP_PATH" "$OVERLAP_BRANCH" README.md "$OVERLAP_SUFFIX"
verify_worktree "$OBSERVER_PATH" "$OBSERVER_BRANCH" CONTRIBUTING.md "$OBSERVER_SUFFIX"

test ! -L /tmp/devisland-fleet-demo-approval-marker || {
  echo "Approval marker is a symlink; stop and review it manually." >&2
  exit 1
}
test ! -e /tmp/devisland-fleet-demo-approval-marker || {
  echo "Unexpected approval marker exists; stop and review it manually." >&2
  exit 1
}

# No worktree is mutated until every identity, status, hash, and byte check above passes.
git -C "$PRIORITY_PATH" restore -- README.md
git -C "$OVERLAP_PATH" restore -- README.md
git -C "$OBSERVER_PATH" restore -- CONTRIBUTING.md

for worktree_path in \
  "$PRIORITY_PATH" \
  "$OVERLAP_PATH" \
  "$OBSERVER_PATH"; do
  if test -n "$(git -C "$worktree_path" -c core.fsmonitor=false status --porcelain=v2 --untracked-files=all)"; then
    echo "Unexpected edits remain in $worktree_path; stop and review them manually." >&2
    exit 1
  fi
done

git worktree remove "$PRIORITY_PATH"
git worktree remove "$OVERLAP_PATH"
git worktree remove "$OBSERVER_PATH"
git branch -d "$PRIORITY_BRANCH" "$OVERLAP_BRANCH" "$OBSERVER_BRANCH"

WORKTREE_LIST="$(git worktree list --porcelain)"
for worktree_path in \
  "$PRIORITY_PATH" \
  "$OVERLAP_PATH" \
  "$OBSERVER_PATH"; do
  if grep -Fqx "worktree $worktree_path" <<<"$WORKTREE_LIST" \
    || grep -Fqx "worktree /private$worktree_path" <<<"$WORKTREE_LIST"; then
    echo "Worktree is still registered: $worktree_path" >&2
    exit 1
  fi
done

cmp -s "$STATE_FILE" <(print_expected_state) || {
  echo "Fixture state changed during cleanup; refusing to remove it." >&2
  exit 1
}
rm -- "$STATE_FILE"

git worktree list
git -c core.fsmonitor=false status --short
)
```

The final two commands should show no disposable demo worktrees and no changes caused by the demo.
