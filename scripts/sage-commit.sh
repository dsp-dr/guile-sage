#!/bin/sh
# sage-commit.sh - Commit as guile-sage (for autonomous agent commits)
#
# Usage:
#   ./scripts/sage-commit.sh "commit message"
#   ./scripts/sage-commit.sh -m "commit message"
#
# This allows guile-sage to make commits with its own identity when
# running autonomously or in automated pipelines.

set -e

# Parse arguments
MSG=""
if [ "$1" = "-m" ]; then
    shift
    MSG="$1"
else
    MSG="$1"
fi

if [ -z "$MSG" ]; then
    echo "Usage: $0 [-m] \"commit message\""
    exit 1
fi

# Commit with sage identity
GIT_AUTHOR_NAME="guile-sage" \
GIT_AUTHOR_EMAIL="sage@noreply.defrecord.com" \
GIT_COMMITTER_NAME="guile-sage" \
GIT_COMMITTER_EMAIL="sage@noreply.defrecord.com" \
git commit -m "$MSG"

echo "Committed as guile-sage"
