#!/usr/bin/env bash
# Run mix inside the hexpm/elixir image (no Elixir on the host). Usage: ./run.sh test | ./run.sh hex.build
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-bookworm-20260918-slim"
ENVFILE="$(mktemp)"; chmod 600 "$ENVFILE"; trap 'rm -f "$ENVFILE"' EXIT
printf 'HEX_API_KEY=%s\n' "${HEX_API_KEY:-}" > "$ENVFILE"
if [ -z "${MIX_ENV:-}" ] && [ "${1:-}" = "test" ]; then MIX_ENV=test; fi
sudo -n docker run --rm -v "$HERE:/work" -w /work \
  -v system_one_client_deps:/work/deps -v system_one_client_build:/work/_build \
  -v system_one_client_mix:/root/.mix -v system_one_client_hex:/root/.hex \
  --env-file "$ENVFILE" -e MIX_ENV="${MIX_ENV:-dev}" \
  "$IMAGE" sh -c 'mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix "$@"' sh "$@"
