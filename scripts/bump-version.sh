#!/bin/sh
# bump-version.sh - Bump semantic version in version.scm
# Usage: bump-version.sh [major|minor|patch]

set -e

VERSION_FILE="src/sage/version.scm"
BUMP_TYPE="${1:-patch}"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: $VERSION_FILE not found"
    exit 1
fi

# Extract current version components
MAJOR=$(grep 'define \*version-major\*' "$VERSION_FILE" | sed 's/.*\*version-major\* \([0-9]*\).*/\1/')
MINOR=$(grep 'define \*version-minor\*' "$VERSION_FILE" | sed 's/.*\*version-minor\* \([0-9]*\).*/\1/')
PATCH=$(grep 'define \*version-patch\*' "$VERSION_FILE" | sed 's/.*\*version-patch\* \([0-9]*\).*/\1/')

OLD_VERSION="$MAJOR.$MINOR.$PATCH"

case "$BUMP_TYPE" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Usage: $0 [major|minor|patch]"
        exit 1
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

echo "Bumping version: $OLD_VERSION -> $NEW_VERSION"

# Update version.scm
sed -i.bak \
    -e "s/(define \*version-major\* [0-9]*)/(define *version-major* $MAJOR)/" \
    -e "s/(define \*version-minor\* [0-9]*)/(define *version-minor* $MINOR)/" \
    -e "s/(define \*version-patch\* [0-9]*)/(define *version-patch* $PATCH)/" \
    -e "s/(define \*version\* \"[^\"]*\")/(define *version* \"$NEW_VERSION\")/" \
    "$VERSION_FILE"

rm -f "$VERSION_FILE.bak"

echo "Updated $VERSION_FILE"
echo "v$NEW_VERSION"
