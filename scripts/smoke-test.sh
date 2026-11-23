#!/usr/bin/env bash
# smoke-test.sh - check the live app through the Ingress after a deploy.
#
#   bash scripts/smoke-test.sh <url> <expected-version> [requests]
#   bash scripts/smoke-test.sh http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/ 3f2a1bc
#
# Passes only if EVERY request:
#   - returns HTTP 200
#   - shows "Frontend <version>"  (the new frontend image is running)
#   - shows "Backend <version>"   (the new backend answers the frontend)
# and the answers came from at least 2 different frontend pods (load balancing).
# The page shows the pod that answered: "Responding server: <strong>frontend-...</strong>"
set -euo pipefail

URL="${1:?usage: smoke-test.sh <url> <expected-version> [requests]}"
VERSION="${2:?usage: smoke-test.sh <url> <expected-version> [requests]}"
REQUESTS="${3:-6}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

echo "Smoke test: ${REQUESTS} requests to ${URL}, expecting version ${VERSION}"
pods=()
for i in $(seq 1 "$REQUESTS"); do
  code="$(curl -s -m 10 -o "$TMP/body" -w '%{http_code}' "$URL" || true)"
  pod="$(sed -n 's/.*Responding server: <strong>\([^<]*\)<\/strong>.*/\1/p' "$TMP/body" | head -1)"

  [[ "$code" == "200" ]]                     || fail "request $i: HTTP ${code:-none} (pod ${pod:-?})"
  grep -q "Frontend ${VERSION}" "$TMP/body"  || fail "request $i: frontend is not version ${VERSION} (pod ${pod:-?})"
  grep -q "Backend ${VERSION}" "$TMP/body"   || fail "request $i: backend is not version ${VERSION} (pod ${pod:-?})"

  echo "  request $i OK  (served by ${pod})"
  pods+=("$pod")
done

unique="$(printf '%s\n' "${pods[@]}" | sort -u | wc -l)"
(( unique >= 2 )) || fail "all requests went to one frontend pod - load balancing is not working"

echo "PASS: version ${VERSION} is live, served by ${unique} frontend pods"