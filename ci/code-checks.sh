#!/usr/bin/env bash
# code-checks.sh - lint, security scan and unit tests for ONE app component.
#
#   bash ci/code-checks.sh backend
#   bash ci/code-checks.sh frontend
#
# Runs INSIDE the build pod's "python" container (python:3.12-slim, the same
# Python as the app images). No Docker needed. Each component gets its own
# throwaway virtualenv in /tmp, so nothing is installed system-wide.
# Test results go to reports/<component>-tests.xml (Jenkins "Tests" tab).
set -euo pipefail

COMPONENT="${1:?usage: code-checks.sh <backend|frontend>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS="$ROOT/reports"
VENV="/tmp/venv-$COMPONENT"
export PYTHONDONTWRITEBYTECODE=1

mkdir -p "$REPORTS"
python -m venv "$VENV"
cd "$ROOT/app/$COMPONENT"

"$VENV/bin/pip" install --quiet --disable-pip-version-check \
  -r requirements.txt -r ../requirements-dev.txt

echo "=== [$COMPONENT] Ruff - lint ==="
"$VENV/bin/ruff" check --no-cache --config ../ruff.toml .

echo "=== [$COMPONENT] Bandit - security scan of the code ==="
"$VENV/bin/bandit" -q -r . -x ./tests

echo "=== [$COMPONENT] pytest - unit tests ==="
"$VENV/bin/python" -m pytest -q -p no:cacheprovider \
  --junitxml="$REPORTS/$COMPONENT-tests.xml" tests