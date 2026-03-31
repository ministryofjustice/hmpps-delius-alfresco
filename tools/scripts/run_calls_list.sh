#!/usr/bin/env bash
# Repeat curl calls and stop on first non-200
set -euo pipefail

URL="${URL:-https://hmpps-delius-alfrsco-poc.apps.live.cloud-platform.service.justice.gov.uk/alfresco/service/noms-spg/fetch/5b7112aa-e4ff-4372-a6fc-e0dc04e0ca33}"
USER_HDR="${USER_HDR:-X-DocRepository-Remote-User: N00}"
REAL_USER_HDR="${REAL_USER_HDR:-X-DocRepository-Real-Remote-User: real name}"
COOKIE="${COOKIE:-JSESSIONID=5F21DD7648096788552109C6B7E67657; alfrescoRepo=1773149487.574.22065.59561|ac2b05174e6b8b59787dcfe5898390f5}"

NUM_CALLS="300"
DELAY_SECONDS="1"

# Parse flags: -n NUM_CALLS, -d DELAY_SECONDS
while getopts ":n:d:" opt; do
  case "$opt" in
    n) NUM_CALLS="$OPTARG" ;;
    d) DELAY_SECONDS="$OPTARG" ;;
    *) echo "Usage: $0 [-n NUM_CALLS] [-d DELAY_SECONDS]" >&2; exit 1 ;;
  esac
done

trap 'echo; echo "Stopped by user."; exit 130' INT

count=0
while :; do
  count=$((count + 1))
  if [[ -n "${NUM_CALLS}" && $count -gt ${NUM_CALLS} ]]; then
    echo "Done ($((count-1)) calls). All returned 200."
    break
  fi

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] Call #$count -> ${URL}"

  # Call and capture status code + timings
  RESULT="$(curl -sS -m 30 --location --show-error \
    -H "${USER_HDR}" \
    -H "${REAL_USER_HDR}" \
    -H "Cookie: ${COOKIE}" \
    -o /dev/null \
    -w "%{http_code} DNS:%{time_namelookup}s TCP:%{time_connect}s TLS:%{time_appconnect}s TTFB:%{time_starttransfer}s TOTAL:%{time_total}s" \
    "${URL}" 2>&1 || true)"

  STATUS="$(printf '%s\n' "$RESULT" | awk '{print $1}')"
  echo "$RESULT"

  if [[ ! "$STATUS" =~ ^[0-9]{3}$ ]]; then
    echo "ERROR: No valid HTTP status returned (network/timeout?). Aborting on call #$count." >&2
    exit 1
  fi

  if [[ "$STATUS" != "200" ]]; then
    echo "ERROR: Non-200 response ($STATUS) on call #$count. Aborting." >&2
    exit 1
  fi

  sleep "${DELAY_SECONDS}"
done
``