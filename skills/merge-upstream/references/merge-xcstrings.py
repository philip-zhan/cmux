#!/usr/bin/env python3
"""Resolve a conflicted .xcstrings file via a structural 3-way JSON merge.

Reads the three merge stages straight from the git index (`:1:` base, `:2:` ours,
`:3:` theirs), performs a recursive 3-way merge that:
  - takes a side's change when only that side changed (honoring deletions),
  - prefers OURS (the fork) on a true conflict,
  - unions keys/languages added on either side,
then writes the resolved file in Xcode's xcstrings format (top-level order
sourceLanguage, version, strings; everything below sorted) and `git add`s it.

Usage: merge-xcstrings.py <path-to-xcstrings>   (run from the repo root)
"""
import collections
import json
import subprocess
import sys

MISSING = object()


def equal(a, b):
    if a is MISSING or b is MISSING:
        return a is b
    return a == b


def merge3(base, ours, theirs):
    if ours is MISSING and theirs is MISSING:
        return MISSING
    if equal(ours, theirs):
        return ours
    if equal(base, ours):      # only theirs changed (incl. theirs-side deletion)
        return theirs
    if equal(base, theirs):    # only ours changed (incl. ours-side deletion)
        return ours
    if isinstance(ours, dict) and isinstance(theirs, dict):
        b = base if isinstance(base, dict) else {}
        out = {}
        for k in set(b) | set(ours) | set(theirs):
            m = merge3(b.get(k, MISSING), ours.get(k, MISSING), theirs.get(k, MISSING))
            if m is not MISSING:
                out[k] = m
        return out
    # scalar / list / type conflict -> prefer ours; if ours deleted, delete
    return MISSING if ours is MISSING else ours


def stage(n, path):
    raw = subprocess.run(
        ["git", "show", f":{n}:{path}"], capture_output=True, text=True
    )
    if raw.returncode != 0:
        sys.exit(f"failed to read stage {n} of {path}: {raw.stderr.strip()}")
    return json.loads(raw.stdout)


def sort_rec(o):
    if isinstance(o, dict):
        return {k: sort_rec(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [sort_rec(x) for x in o]
    return o


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: merge-xcstrings.py <path-to-xcstrings>")
    path = sys.argv[1]
    base, ours, theirs = stage(1, path), stage(2, path), stage(3, path)
    merged = merge3(base, ours, theirs)

    out = collections.OrderedDict()
    for k in ("sourceLanguage", "version"):
        if k in merged:
            out[k] = merged[k]
    out["strings"] = sort_rec(merged.get("strings", {}))
    for k in sorted(merged):
        if k not in out:
            out[k] = sort_rec(merged[k])

    text = json.dumps(out, ensure_ascii=False, indent=2) + "\n"
    json.loads(text)  # validate before writing
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)

    o = set(ours.get("strings", {}))
    t = set(theirs.get("strings", {}))
    m = set(out["strings"])
    dropped = (o & t) - m
    if dropped:
        sys.exit(f"refusing: {len(dropped)} keys present on both sides were dropped")

    subprocess.run(["git", "add", path], check=True)
    print(f"resolved {path}: {len(out['strings'])} string keys "
          f"(ours={len(o)}, theirs={len(t)}, base={len(base.get('strings', {}))})")


if __name__ == "__main__":
    main()
