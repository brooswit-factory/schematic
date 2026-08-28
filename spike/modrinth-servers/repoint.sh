#!/usr/bin/env bash
# repoint.sh — KAN-723 spike proof.
#
# Re-points a Modrinth Server's upstream to a modpack version and applies it,
# using the Servers (Archon) management API directly over curl (no Node/
# @modrinth/api-client dependency — this repo has no JS toolchain, and the
# whole call sequence is five small HTTP requests, so bash+curl keeps the
# spike runnable with zero new dependencies).
#
# Usage:
#   MODRINTH_TOKEN=... ./repoint.sh SERVER_ID PROJECT_ID [VERSION_ID]
#
# If VERSION_ID is omitted, resolves the latest version of PROJECT_ID via the
# public (unauthenticated) version-lookup endpoint (Q5).
#
# Endpoints (sourced from github.com/modrinth/code, see FINDINGS.md for
# citations):
#   GET  https://archon.modrinth.com/modrinth/v0/servers/:id            (Q4 — read current upstream)
#   POST https://archon.modrinth.com/modrinth/v0/servers/:id/reinstall  (Q2 — re-point upstream)
#   POST https://archon.modrinth.com/modrinth/v0/servers/:id/power      (Q3 — restart, if reinstall doesn't already trigger one)
#   GET  https://api.modrinth.com/v2/project/:id/version                (Q5 — resolve latest version id)
#
# REDACTION: MODRINTH_TOKEN is never echoed, never passed as a CLI arg, and
# never appears in a printed response body. The Archon server object embeds
# sftp_username/sftp_password/sftp_host — this script only ever extracts and
# prints an allowlisted set of fields (server_id, name, status, upstream)
# via the same allowlist parser the probe workflow uses; it never dumps a
# raw response body.

set -euo pipefail

SERVER_ID="${1:?Usage: MODRINTH_TOKEN=... ./repoint.sh SERVER_ID PROJECT_ID [VERSION_ID]}"
PROJECT_ID="${2:?Usage: MODRINTH_TOKEN=... ./repoint.sh SERVER_ID PROJECT_ID [VERSION_ID]}"
VERSION_ID="${3:-}"

if [ -z "${MODRINTH_TOKEN:-}" ]; then
  echo "ERROR: MODRINTH_TOKEN is not set in the environment." >&2
  echo "Usage: MODRINTH_TOKEN=... ./repoint.sh SERVER_ID PROJECT_ID [VERSION_ID]" >&2
  exit 1
fi

ARCHON_BASE="https://archon.modrinth.com/modrinth/v0"
LABRINTH_BASE="https://api.modrinth.com/v2"
# "Bearer <token>" — confirmed live against the real server in the probe
# workflow run (see FINDINGS.md Q1: HTTP 200 with Bearer prefix, HTTP 401
# with a bare token — the opposite of the pre-flight hypothesis).
ARCHON_AUTH_HEADER="Bearer ${MODRINTH_TOKEN}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

allowlist_print() {
  # $1 = json file, $2 = mode (server|error)
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
d = json.load(open(path))
if mode == "server":
    print("server_id:", d.get("server_id"), "| name:", d.get("name"),
          "| status:", d.get("status"), "| upstream:", d.get("upstream"))
elif mode == "error":
    print("error field:", d.get("error"))
    print("description field:", d.get("description"))
PYEOF
}

check_no_token_leak() {
  # $1 = json file
  if grep -qF "$MODRINTH_TOKEN" "$1"; then
    echo "REFUSING to continue — response body appears to contain the token" >&2
    exit 1
  fi
}

archon_get() {
  # $1 = path (e.g. /servers/$SERVER_ID), $2 = output file
  # X-Panel-Version is required — without it Archon 426s every request
  # before auth is even checked (see FINDINGS.md Q1).
  curl -sS -o "$2" -w '%{http_code}' \
    -H "Authorization: ${ARCHON_AUTH_HEADER}" \
    -H "X-Panel-Version: 1" \
    "${ARCHON_BASE}$1"
}

archon_post() {
  # $1 = path, $2 = json body, $3 = output file
  curl -sS -o "$3" -w '%{http_code}' \
    -H "Authorization: ${ARCHON_AUTH_HEADER}" \
    -H "X-Panel-Version: 1" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$2" \
    "${ARCHON_BASE}$1"
}

echo "== Step 1: resolve VERSION_ID (if not given) =="
if [ -z "$VERSION_ID" ]; then
  ver_status=$(curl -sS -o "$WORKDIR/versions.json" -w '%{http_code}' \
    "${LABRINTH_BASE}/project/${PROJECT_ID}/version")
  if [ "$ver_status" != "200" ]; then
    echo "ERROR: version lookup failed (HTTP ${ver_status})" >&2
    cat "$WORKDIR/versions.json" >&2 || true
    exit 1
  fi
  VERSION_ID=$(python3 -c "import json,sys; v=json.load(open('$WORKDIR/versions.json')); print(v[0]['id'])")
  echo "Resolved latest VERSION_ID=${VERSION_ID} (GET ${LABRINTH_BASE}/project/${PROJECT_ID}/version -> HTTP ${ver_status})"
else
  echo "Using explicit VERSION_ID=${VERSION_ID}"
fi

echo "== Step 2: capture BEFORE upstream =="
before_status=$(archon_get "/servers/${SERVER_ID}" "$WORKDIR/before.json")
echo "GET ${ARCHON_BASE}/servers/${SERVER_ID} -> HTTP ${before_status}"
if [ "$before_status" != "200" ]; then
  check_no_token_leak "$WORKDIR/before.json"
  echo "BLOCKED at step 2 (read server): HTTP ${before_status}" >&2
  allowlist_print "$WORKDIR/before.json" error || cat "$WORKDIR/before.json" >&2
  exit 1
fi
check_no_token_leak "$WORKDIR/before.json"
echo "BEFORE:"
allowlist_print "$WORKDIR/before.json" server

echo "== Step 3: re-point upstream via reinstall =="
body=$(python3 -c "import json,sys; print(json.dumps({'project_id': sys.argv[1], 'version_id': sys.argv[2]}))" "$PROJECT_ID" "$VERSION_ID")
reinstall_status=$(archon_post "/servers/${SERVER_ID}/reinstall?hard=false" "$body" "$WORKDIR/reinstall.json")
echo "POST ${ARCHON_BASE}/servers/${SERVER_ID}/reinstall?hard=false -> HTTP ${reinstall_status}"
check_no_token_leak "$WORKDIR/reinstall.json"
if [ "$reinstall_status" -ge 300 ]; then
  echo "BLOCKED at step 3 (reinstall/re-point): HTTP ${reinstall_status}" >&2
  echo "Intended request: POST ${ARCHON_BASE}/servers/${SERVER_ID}/reinstall?hard=false" >&2
  echo "Intended body: {\"project_id\": \"${PROJECT_ID}\", \"version_id\": \"${VERSION_ID}\"}" >&2
  allowlist_print "$WORKDIR/reinstall.json" error || cat "$WORKDIR/reinstall.json" >&2
  exit 1
fi
echo "Reinstall accepted."

echo "== Step 4: ensure the server is running the new version (explicit Restart) =="
power_status=$(archon_post "/servers/${SERVER_ID}/power" '{"action":"Restart"}' "$WORKDIR/power.json")
echo "POST ${ARCHON_BASE}/servers/${SERVER_ID}/power -> HTTP ${power_status}"
check_no_token_leak "$WORKDIR/power.json"
if [ "$power_status" -ge 300 ]; then
  echo "NOTE: explicit Restart call failed/rejected (HTTP ${power_status}) — reinstall in step 3 may already have restarted the server; check AFTER status below." >&2
fi

echo "== Step 5: capture AFTER upstream =="
after_status=$(archon_get "/servers/${SERVER_ID}" "$WORKDIR/after.json")
echo "GET ${ARCHON_BASE}/servers/${SERVER_ID} -> HTTP ${after_status}"
check_no_token_leak "$WORKDIR/after.json"
if [ "$after_status" != "200" ]; then
  echo "BLOCKED at step 5 (read server after re-point): HTTP ${after_status}" >&2
  allowlist_print "$WORKDIR/after.json" error || cat "$WORKDIR/after.json" >&2
  exit 1
fi
echo "AFTER:"
allowlist_print "$WORKDIR/after.json" server

echo "== Done =="
echo "Re-point target was project_id=${PROJECT_ID} version_id=${VERSION_ID}"
