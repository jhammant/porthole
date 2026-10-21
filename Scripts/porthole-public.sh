#!/bin/bash
# Porthole's public tree, for github.com/jhammant/porthole: everything git tracks (or would), less the
# private notes, copied into DEST (its .git, if any, is kept: run it again to refresh a clone of the public
# repository). It stops, and says where, if anything private is in the result.
#
#   Scripts/porthole-public.sh DEST
#
# Left out: CLAUDE.md, the design notes (docs/*-plan.md, docs/BRIEF.md: they carry the decisions'
# history and the people in it), .project-map/, and design/reel/ (not tracked anyway).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:?usage: Scripts/porthole-public.sh DEST}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
[ "$dest" != "$root" ] || { echo "DEST must not be this repository" >&2; exit 2; }

cd "$root"
list="$(mktemp)"
git ls-files -co --exclude-standard | grep -vE '^(CLAUDE\.md|docs/.*-plan\.md|docs/BRIEF\.md|\.project-map/|design/reel/)' > "$list"
rsync -a --delete --exclude .git --files-from="$list" "$root/" "$dest/"
# --files-from never deletes what the list no longer names: drop what is in DEST but not in the list.
(cd "$dest" && find . -type f -not -path './.git/*' | sed 's|^\./||' | sort) | comm -23 - <(sort "$list") | while IFS= read -r f; do
    mv "$dest/$f" "$(mktemp -d)/" 2>/dev/null || true   # moved aside, never deleted outright
done
rm -f "$list"

# Nothing private may go out. Keys and tokens of any kind, and the maintainer's own words (workspace and
# company names, the tailnet, people, key ids), one regex a line in a file kept outside the repository, so
# the list itself never goes out. Without that file the tree is not judged safe. NOTICE alone may name
# the original project and its author (Apache 2.0 attribution).
private="$HOME/Library/Application Support/Porthole/public-scan.txt"
[ -s "$private" ] || { echo "No $private: the public tree can't be checked for private words" >&2; exit 1; }
pattern="AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|BEGIN [A-Z ]*PRIVATE KEY|xox[bp]-|sk-[A-Za-z0-9]{20}|$(grep -v '^#' "$private" | grep . | paste -sd'|' -)"
if grep -rIlE "$pattern" "$dest" --exclude-dir=.git --exclude=NOTICE >/dev/null; then
    echo "Private material in the public tree:" >&2
    grep -rInE "$pattern" "$dest" --exclude-dir=.git --exclude=NOTICE | head -20 >&2
    exit 1
fi
echo "Public tree in $dest: $(cd "$dest" && find . -type f -not -path './.git/*' | wc -l | tr -d ' ') files, nothing private found."
