#!/usr/bin/env bash
# Start an outgoing assistant call through the running HFP daemon.
# Usage: docker/call.sh <+number> [brief]
# Env: HFP_ENV_FILE (default ~/.config/hfp-mcp-docker.env), HFP_MCP_URL (default http://127.0.0.1:8000)
set -euo pipefail

number="${1:?usage: $0 <+number> [brief]}"
brief="${2:-You are a personal assistant. Greet the person politely and ask if there is anything you can help with. Keep it short.}"
env_file="${HFP_ENV_FILE:-$HOME/.config/hfp-mcp-docker.env}"
base_url="${HFP_MCP_URL:-http://127.0.0.1:8000}"

token="$(grep '^HFP_MCP_BEARER_TOKEN=' "$env_file" | cut -d= -f2-)"
[ -n "$token" ] || { echo "HFP_MCP_BEARER_TOKEN not found in $env_file" >&2; exit 1; }

payload="$(python3 -c 'import json, sys, uuid; print(json.dumps({"number": sys.argv[1], "request_id": "call-" + uuid.uuid4().hex[:12], "purpose": sys.argv[2]}))' "$number" "$brief")"

curl -sS -X POST "$base_url/v1/phone/calls" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  -d "$payload"
echo
