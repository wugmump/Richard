#!/usr/bin/env bash
set -euo pipefail

code="${1:-696367}"
url="${RICHARD_URL:-http://127.0.0.1:9443}"
payload="$(curl -sS "$url/api/activity?code=$code")"

RICHARD_ACTIVITY_JSON="$payload" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["RICHARD_ACTIVITY_JSON"])
print(f"isSending: {data.get('isSending')}")
print(f"status: {data.get('statusText') or ''}")
print()

for event in data.get("activity", [])[-16:]:
    print(f"{event.get('createdAt')}  {event.get('kind')}  {event.get('message')}")
    detail = event.get("detail")
    if detail:
        detail = detail.replace("\n", "\\n")
        print(f"  {detail[:240]}")
PY
