#!/bin/sh
#
# Common release script for Dart/pub.dev packages.
#
# Usage: source this script from a project-specific release.sh after
# optionally setting configuration variables and defining hooks.
#
# Configuration variables (set before sourcing):
#   PUB_DIR       Directory containing pubspec.yaml.
#                 Default: $REPO_DIR
#   CHANGELOG     Path to CHANGELOG.md.
#                 Default: $REPO_DIR/CHANGELOG.md
#
# Hooks (define as shell functions before sourcing):
#   release_update_files
#     Called after pubspec.yaml version update but before changelog update
#     and commit. Use this to update extra version files (version.dart,
#     README constraints, etc.).
#     Available variables: $version, $tag, $date, $PUB_DIR, $REPO_DIR
#
set -e

usage() {
  echo "Usage: $0 <major|minor|patch|MAJOR.MINOR.PATCH[+BUILD]>" >&2
  exit 1
}

[ -z "$1" ] && usage

# Find repository root by walking up from PUB_DIR (or cwd).
find_repo_root() {
  dir="${1:-$(pwd)}"
  while [ "$dir" != "/" ]; do
    [ -d "$dir/.jj" ] || [ -d "$dir/.git" ] && echo "$dir" && return
    dir="$(dirname "$dir")"
  done
  echo "Error: not inside a git or jj repository." >&2
  exit 1
}

REPO_DIR="$(find_repo_root "${PUB_DIR:-$(pwd)}")"
PUB_DIR="${PUB_DIR:-$REPO_DIR}"
CHANGELOG="${CHANGELOG:-$REPO_DIR/CHANGELOG.md}"

cd "$PUB_DIR"

# Detect VCS.
if [ -d "$REPO_DIR/.jj" ] && command -v jj >/dev/null 2>&1; then
  vcs=jj
else
  vcs=git
fi

# Verify clean working tree.
if [ "$vcs" = "jj" ]; then
  if [ -n "$(jj diff --summary -R "$REPO_DIR")" ]; then
    echo "Error: working tree is not clean." >&2
    exit 1
  fi
else
  if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    echo "Error: working tree is not clean." >&2
    exit 1
  fi
fi

# Extract current version from pubspec.yaml.
current="$(grep '^version:' pubspec.yaml | sed 's/version: *//')"
current_base="${current%%+*}"
current_major="$(echo "$current_base" | cut -d. -f1)"
current_minor="$(echo "$current_base" | cut -d. -f2)"
current_patch="$(echo "$current_base" | cut -d. -f3)"

# Compute new version from argument.
case "$1" in
  major) version="$((current_major + 1)).0.0" ;;
  minor) version="$current_major.$((current_minor + 1)).0" ;;
  patch) version="$current_major.$current_minor.$((current_patch + 1))" ;;
  *[0-9]*)
    if ! echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$'; then
      echo "Error: invalid version '$1'. Expected MAJOR.MINOR.PATCH[+BUILD]." >&2
      exit 1
    fi
    version="$1"
    ;;
  *) usage ;;
esac

tag="v$version"
date="$(date +%Y-%m-%d)"

# Update version in pubspec.yaml.
sed -i.bak "s/^version: .*/version: $version/" pubspec.yaml
rm -f pubspec.yaml.bak

# Update version constraints in READMEs.
package_name="$(grep '^name:' pubspec.yaml | sed 's/name: *//')"
version_base="${version%%+*}"
version_major="$(echo "$version_base" | cut -d. -f1)"
version_minor="$(echo "$version_base" | cut -d. -f2)"
constraint="^$version_major.$version_minor.0"

for readme in README.md example/README.md example/example.md; do
  if [ -f "$PUB_DIR/$readme" ]; then
    sed -i.bak "s/$package_name: \^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/$package_name: $constraint/g" "$PUB_DIR/$readme"
    rm -f "$PUB_DIR/$readme.bak"
  fi
done

# Run project-specific file updates.
if command -V release_update_files >/dev/null 2>&1; then
  release_update_files
fi

# Ensure pub.dev authentication (no-op if already logged in).
dart pub login

echo "Releasing $tag..."

# Update CHANGELOG.md.
if ! grep -q '## \[Unreleased\]' "$CHANGELOG"; then
  echo "Error: no [Unreleased] section found in CHANGELOG.md." >&2
  exit 1
fi

sed -i.bak "s/## \[Unreleased\]/## [Unreleased]\n\n## [$version] - $date/" "$CHANGELOG"
rm -f "$CHANGELOG.bak"

sed -i.bak "s|\[Unreleased\]: \(.*\)/compare/v.*\.\.\.HEAD|[Unreleased]: \1/compare/$tag...HEAD\n[$version]: \1/releases/tag/$tag|" "$CHANGELOG"
rm -f "$CHANGELOG.bak"

# Commit, tag, and push.
if [ "$vcs" = "jj" ]; then
  jj commit -R "$REPO_DIR" -m "Release $tag"
  jj bookmark set main -R "$REPO_DIR" -r @-
  jj tag set "$tag" -R "$REPO_DIR" -r @-
  jj git push -R "$REPO_DIR"
  jj git export -R "$REPO_DIR"
  git -C "$REPO_DIR" push -f origin "$tag"
else
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -m "Release $tag"
  git -C "$REPO_DIR" tag "$tag"
  git -C "$REPO_DIR" push
  git -C "$REPO_DIR" push -f origin "$tag"
fi

# Publish to pub.dev.
dart pub publish --force

echo "Released $tag"
