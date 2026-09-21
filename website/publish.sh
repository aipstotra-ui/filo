#!/bin/bash
#
# publish.sh — push website/site/ (and nothing else) to the filo-website repo,
# which is what Vercel builds from.
#
# Why this script exists: the GitHub repo behind the live site must contain the
# deployable site ONLY. Everything else in website/ — design-source/, the
# playbook, working notes — is internal, and a host pointed at a folder serves
# every file in it. This script makes that boundary mechanical instead of
# remembered. See DEPLOY.md.
#
# Usage:  ./website/publish.sh          (from the repo root)
#
set -euo pipefail

REMOTE="website-origin"
PREFIX="website/site"
TMP_BRANCH="filo-site-deploy"

cd "$(dirname "$0")/.."

# ---- 1. the working tree must be clean, or we would publish a stale commit ---
if [ -n "$(git status --porcelain -- "$PREFIX")" ]; then
  echo "✗ You have uncommitted changes in $PREFIX."
  echo "  Commit them first — this script publishes committed work only."
  exit 1
fi

# ---- 2. build a branch whose ROOT is website/site ---------------------------
git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true
git subtree split -q --prefix="$PREFIX" -b "$TMP_BRANCH" >/dev/null

# ---- 3. the safety gate: refuse to publish anything internal ----------------
FILES=$(git ls-tree -r --name-only "$TMP_BRANCH")

if ! echo "$FILES" | grep -qx "index.html"; then
  echo "✗ No index.html at the root of the split. Refusing to publish."
  git branch -D "$TMP_BRANCH" >/dev/null
  exit 1
fi

if BAD=$(echo "$FILES" | grep -E 'design-source/|Playbook|\.dc\.html$|^README\.md$|screenshots/'); then
  echo "✗ Internal files reached the publish set. Refusing to publish:"
  echo "$BAD" | sed 's/^/    /'
  git branch -D "$TMP_BRANCH" >/dev/null
  exit 1
fi

echo "This is everything that will be public:"
echo "$FILES" | sed 's/^/    /'
echo
echo "Target: $(git remote get-url "$REMOTE") → branch main (overwritten)"
read -r -p "Publish? [y/N] " reply
if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
  echo "Cancelled. Nothing was pushed."
  git branch -D "$TMP_BRANCH" >/dev/null
  exit 0
fi

# ---- 4. publish -------------------------------------------------------------
git push "$REMOTE" "$TMP_BRANCH:main" --force
git branch -D "$TMP_BRANCH" >/dev/null

echo
echo "✓ Pushed. Vercel builds automatically within ~30 seconds."
echo "  Watch it at https://vercel.com/dashboard"
