#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${REMOTE_ENV_S3_URI:-}" ]]; then
  if [[ ! "${REMOTE_ENV_S3_URI}" =~ ^s3:// ]]; then
    echo "REMOTE_ENV_S3_URI must start with s3://" >&2
    exit 1
  fi

  TMP_ENV_JSON="/tmp/remote-env.json"
  aws s3 cp "${REMOTE_ENV_S3_URI}" "${TMP_ENV_JSON}"

  python3 - <<'PY'
import json
import os
import shlex

path = "/tmp/remote-env.json"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

for key, value in data.items():
    if value is None:
        continue
    print(f"export {key}={shlex.quote(str(value))}")
PY
fi > /tmp/export-remote-env.sh

if [[ -f /tmp/export-remote-env.sh ]]; then
  # shellcheck disable=SC1091
  source /tmp/export-remote-env.sh
fi

APP_FUNCTION_VALUE="${APP_FUNCTION:-run:app}"
exec uvicorn \
  --host 0.0.0.0 \
  --port 8080 \
  --loop asyncio \
  --workers 1 \
  --timeout-keep-alive 65 \
  "${APP_FUNCTION_VALUE}"
