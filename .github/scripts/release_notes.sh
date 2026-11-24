#!/usr/bin/env bash
# Prints the GitHub release notes for a version: its CHANGELOG.md section plus links.
# Fails if the version has no dated section (missing, or still marked "unreleased").
# Usage: release_notes.sh 0.4.0
set -euo pipefail
version="$1"

heading="$(grep -E "^## ${version//./\\.} \(" CHANGELOG.md || true)"
if [ -z "$heading" ]; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi
if ! grep -qE '\([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' <<<"$heading"; then
  echo "CHANGELOG.md section for $version is not dated: $heading" >&2
  exit 1
fi

awk -v v="$version" '
  /^## / { on = (index($0, "## " v " (") == 1); next }
  on { print }
' CHANGELOG.md | sed -e '1{/^$/d}'

cat <<EOF

---

- Hex: https://hex.pm/packages/system_one_client/$version
- Docs: https://hexdocs.pm/system_one_client/$version
- Full changelog: https://hexdocs.pm/system_one_client/changelog.html
EOF
