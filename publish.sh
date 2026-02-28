#!/usr/bin/env bash
set -euo pipefail

# Publish script for ex_openzl
# Usage: ./publish.sh
#
# Prerequisites:
#   1. Version already bumped in mix.exs
#   2. Changes committed and pushed to main
#   3. Tag pushed (e.g. git tag v0.4.1 && git push origin v0.4.1)
#   4. Precompile CI has finished (builds NIFs, updates checksum.exs, pushes to main)
#
# This script:
#   - Pulls the CI's checksum.exs update
#   - Moves the tag to include the updated checksum
#   - Force-pushes the tag
#   - Publishes to Hex

VERSION=$(grep '@version' mix.exs | head -1 | sed 's/.*"\(.*\)".*/\1/')
TAG="v${VERSION}"

echo "==> Publishing ex_openzl ${TAG}"
echo ""

# Sanity checks
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: Working directory is dirty. Commit or stash changes first."
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "ERROR: Not on main branch (on: ${BRANCH})"
  exit 1
fi

# Check the tag exists
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "ERROR: Tag ${TAG} does not exist."
  echo "  Create it with: git tag ${TAG} && git push origin ${TAG}"
  echo "  Then wait for CI to finish before running this script."
  exit 1
fi

# Check CI status
echo "==> Checking precompile CI status for ${TAG}..."
CI_STATUS=$(gh run list --workflow=precompile.yml --limit 1 --json conclusion,headBranch --jq ".[0] | select(.headBranch == \"${TAG}\") | .conclusion")

if [ "$CI_STATUS" != "success" ]; then
  echo "ERROR: Precompile CI has not succeeded for ${TAG}."
  echo "  Status: ${CI_STATUS:-not found}"
  echo "  Check: gh run list --workflow=precompile.yml"
  exit 1
fi

echo "  CI passed."

# Pull the checksum update from CI
echo "==> Pulling latest main (includes CI's checksum.exs update)..."
git pull --ff-only origin main

# Verify checksum.exs has the current version
if ! grep -q "${VERSION}" checksum.exs; then
  echo "ERROR: checksum.exs does not contain version ${VERSION}."
  echo "  CI may not have updated it. Check the precompile workflow logs."
  exit 1
fi

echo "  checksum.exs has ${VERSION} entries."

# Move the tag to the current commit (which includes updated checksums)
echo "==> Moving tag ${TAG} to current HEAD ($(git rev-parse --short HEAD))..."
git tag -f "$TAG"
git push origin "$TAG" --force

echo "  Tag updated."

# Publish to Hex
echo ""
echo "==> Publishing to Hex..."
mix hex.publish

echo ""
echo "Done! ${TAG} published to Hex."
