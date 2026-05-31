# Inline Git Blame (current line only) — Implementation Plan

## Goal

Add inline git blame to the single-file code editor (CodeMirror 6 in a WKWebView).
Scope is intentionally narrow: **single-file view only** (not diff/MergeView) and
**current-line-only** annotation (GitLens-style end-of-line text for the line the
cursor is on), not a full per-line gutter.

When the cursor sits on a line, a faint end-of-line annotation shows:

```
        Philip Zhan · 3 days ago · Fix blank Settings window on reopen
```

Uncommitted (working-tree) lines show `You · Uncommitted changes`.

## Approach

Reuse the existing diff-feature plumbing wherever possible:

- Git execution / repo-root / relative-path: mirror `CodeViewerGitDiffSource`.
- Swift→JS transport: same WKWebView bridge, but via a **dedicated** bridge
  function `__cmuxCodeSetBlame`, **not** the `CodeWebRendererPayload`. This is
  the key design decision: `__cmuxCodeApply` tears down and remounts the editor
  on every payload change (mirrors how `__cmuxCodeSetFontSize` is a separate
  path). Routing blame through the payload would remount the editor and lose
  cursor/scroll each time blame loads in asynchronously. So blame is tracked
  separately in the coordinator (like font size) and re-sent after any remount
  (`didFinish` / process recovery).
- JS rendering: a `ViewPlugin` that places a `Decoration.widget` at the end of
  the cursor's line, recomputed on selection change. No gutter.

Blame is fetched **once per file load** (in `FilePreviewPanel.init` and on file
reload), whole-file via `git blame --line-porcelain`, cached as `[GitBlameLine]`
indexed by line. Blaming once and caching gives instant cursor response with no
per-move git calls. Only for single-file mode (`diffAgainstHead == false`).

## Files

### New
- `Sources/Panels/GitBlameLine.swift` — value type: `{ shortHash, author, timestamp (epoch), summary, isUncommitted }`. `Codable` for the bridge.
- `Sources/Panels/CodeViewerGitBlameSource.swift` — runs `git blame --line-porcelain`, parses porcelain into `[GitBlameLine]`. Copies the `runGit`/`repoRoot`/`relativePath` helpers from `CodeViewerGitDiffSource` (kept private/independent to avoid coupling).

### Modified
- `Sources/Panels/FilePreviewPanel.swift` — `@Published private(set) var blameLines: [GitBlameLine]?`; `loadBlame()` called from init + file reload when `!diffAgainstHead`; generation guard like `loadDiffContent`.
- `Sources/Panels/FilePreviewCodeEditor.swift` — read `panel.blameLines`, pass to `CodeWebRenderer`.
- `Sources/Panels/CodeWebRenderer.swift` — add `blameLines: [GitBlameLine]?` prop; coordinator stores `lastBlame`, sends via `applyBlame()` (`window.__cmuxCodeSetBlame(json)`) from `updateNSView` when changed and re-sends on `didFinish`. Blame stays out of `CodeWebRendererPayload`.
- `web/code-viewer/src/index.ts` — `__cmuxCodeSetBlame`, a blame `StateField` + `ViewPlugin` producing the active-line end-of-line widget, themed faint/italic. Then rebuild bundle (`node build.mjs`) → `Resources/code-viewer/code-viewer.js`.

### Tests
- `cmuxTests/CodeViewerGitBlameSourceTests.swift` — porcelain parser unit tests (Swift Testing): normal commit lines, uncommitted (all-zero hash / "Not Committed Yet"), multi-line commit grouping, summary extraction. Parser must be factored as a pure `static func parse(porcelain:) -> [GitBlameLine]` so it's testable without a real repo. **Wire into `cmux.xcodeproj/project.pbxproj`** (PBXFileReference + Sources build phase) — unwired test files silently never run.

## Settings / toggle

v1 ships **on by default** with no keybinding (a plain behavior). If a toggle/
shortcut is added later it must follow the repo shortcut policy
(`KeyboardShortcutSettings` + `cmux.json` + docs). Not in scope for v1.

## Porcelain format reference

`git blame --line-porcelain <file>` emits, per source line, a header block:

```
<40-hex-sha> <orig-line> <final-line> [<group-size>]
author <name>
author-mail <email>
author-time <epoch>
author-tz <tz>
committer ...
summary <commit summary line>
filename <path>
\t<the actual source line text>
```

`--line-porcelain` repeats the full block for every line (no need to track the
abbreviated-on-repeat form of plain `--porcelain`). Uncommitted lines have SHA
`0000000000000000000000000000000000000000` and author `Not Committed Yet`.

## Risks / notes

- Large files: `git blame` is slow on 10k+ line files. Mitigated by off-main
  `Task.detached` (already the pattern) + generation guard so a reload supersedes
  an in-flight blame. Acceptable for v1; no debounce needed since it runs once.
- After an in-editor edit/save the line→commit mapping changes; blame is re-fetched
  on file reload. Between edit and reload the annotation may be stale by a line —
  acceptable for v1 (annotation is advisory).
- Payload size: blame is sent once, out-of-band, not on the hot payload path.
