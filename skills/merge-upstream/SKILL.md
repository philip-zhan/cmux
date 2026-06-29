---
name: merge-upstream
description: "Merge the upstream source repo (manaflow-ai/cmux) into the fork (philip-zhan/cmux2) and open a review PR. Use for the weekly upstream sync, 'merge upstream into our fork', resolving the recurring Localizable.xcstrings / vendor/bonsplit / project.pbxproj merge conflicts, or any scheduled upstream-merge run."
---

# Merge upstream into the fork

Sync `upstream/main` (`manaflow-ai/cmux`) into the fork `philip-zhan/cmux2` and
open a PR for review. **Never push the merge straight to `main`** — open a PR so
a human (or a follow-up review) approves it. This skill is safe to run unattended
(e.g. a scheduled Monday run): if there is nothing to merge, it exits without
opening a PR.

The three conflicts that recur on this merge are mechanical and resolved the same
way every time: `Resources/Localizable.xcstrings`, `vendor/bonsplit`, and
`cmux.xcodeproj/project.pbxproj`. Anything else conflicting is a real conflict —
stop and surface it in the PR body or to the user.

## Steps

### 1. Preconditions

```bash
cd "$(git -C . rev-parse --show-toplevel)"
git fetch upstream
git fetch origin
AHEAD=$(git rev-list --count origin/main..upstream/main)
echo "upstream commits ahead of origin/main: $AHEAD"
```

- If `$AHEAD` is 0, there is nothing to merge. **Stop — do not open a PR.**
- Note any uncommitted submodule pointers (`git status --short` showing `M ghostty`
  / `M vendor/bonsplit`). These are working-tree state, not part of the merge.
  Leave `ghostty` alone (it is intentionally carried). If `vendor/bonsplit` is
  dirty and upstream also moves it, reset just that submodule to its committed
  pointer first: `git submodule update --checkout -- vendor/bonsplit`.
- Start from a clean, up-to-date `origin/main`. Create the work branch from it:

```bash
DATE=$(date +%Y-%m-%d)
BRANCH="merge-upstream-$DATE"
git checkout -B "$BRANCH" origin/main
```

### 2. Merge

```bash
git merge upstream/main --no-edit
```

If it succeeds with no conflicts, skip to step 4. Otherwise resolve **only** the
three known conflicts below; if `git diff --name-only --diff-filter=U` lists
anything else, stop and report it.

### 3. Resolve the recurring conflicts

**`Resources/Localizable.xcstrings`** — structural 3-way JSON merge (keep every
key/language from both sides, fork wins value ties, honor deletions). Do not edit
the markers by hand:

```bash
python3 skills/merge-upstream/references/merge-xcstrings.py Resources/Localizable.xcstrings
```

The script reads the three merge stages from git, writes the resolved file in
Xcode's xcstrings format (top-level `sourceLanguage`, `version`, `strings`;
everything else sorted), validates it, and `git add`s it.

**`vendor/bonsplit`** — keep the fork's pointer when it already descends from
upstream's; otherwise keep whichever commit is newer (a descendant of the other).
The fork maintains its own bonsplit, so the fork side is normally the descendant:

```bash
OURS=$(git rev-parse :2:vendor/bonsplit 2>/dev/null || git ls-tree origin/main vendor/bonsplit | awk '{print $3}')
THEIRS=$(git rev-parse :3:vendor/bonsplit)
if git -C vendor/bonsplit merge-base --is-ancestor "$THEIRS" "$OURS"; then KEEP="$OURS"; \
elif git -C vendor/bonsplit merge-base --is-ancestor "$OURS" "$THEIRS"; then KEEP="$THEIRS"; \
else echo "bonsplit diverged — STOP and resolve manually"; fi
git -C vendor/bonsplit checkout "$KEEP"
git add vendor/bonsplit
```

**`cmux.xcodeproj/project.pbxproj`** — keep upstream's structural changes but the
**fork's** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`. Git usually auto-merges
this; if it conflicts, take upstream's structure and re-assert the fork versions,
then normalize:

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
./scripts/check-pbxproj.sh
git add cmux.xcodeproj/project.pbxproj
```

After resolving, confirm nothing is still unmerged: `git diff --name-only --diff-filter=U`
must be empty.

### 4. Verify the merge compiles

```bash
bash scripts/lint-pbxproj-test-wiring.sh
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-merge-upstream \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expect `** BUILD SUCCEEDED **`. (`build-for-testing` is unreliable on machines
with an out-of-date CoreSimulator — use the `build` action with codesigning off.)
Clean up `/tmp/cmux-merge-upstream` afterward to avoid filling the disk; if disk is
tight, clear stale `~/Library/Developer/Xcode/DerivedData/cmux-*` first.

### 5. Commit, push the branch, open the PR

```bash
git commit --no-edit -m "Merge remote-tracking branch 'upstream/main'

Resolve Localizable.xcstrings via a structural 3-way union merge (keep all
keys/languages from both sides, fork wins value ties). Keep the fork's
vendor/bonsplit pointer and fork versions in project.pbxproj.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push -u origin "$BRANCH"
gh pr create --repo philip-zhan/cmux2 --base main --head "$BRANCH" \
  --title "Merge upstream into fork ($DATE)" \
  --body "Automated weekly upstream sync ($AHEAD upstream commits). Recurring conflicts (Localizable.xcstrings, vendor/bonsplit, project.pbxproj) resolved per the merge-upstream skill; \`cmux\` scheme compiles. Review and merge."
```

Report the PR URL. **Do not merge the PR** — leave it for review.

## Hard rules

- Target the fork `philip-zhan/cmux2` only — never push to or PR against `manaflow-ai/cmux`.
- Never push the merge to `main`; always open a PR from a `merge-upstream-<date>` branch.
- Only auto-resolve the three listed conflicts. Any other unmerged path → stop and report.
- Leave the `ghostty` submodule pointer as-is; do not bump it here.
- If the build fails or a non-mechanical conflict appears, still push the branch and
  open the PR, but call out the failure prominently in the PR body so it is not merged blindly.
