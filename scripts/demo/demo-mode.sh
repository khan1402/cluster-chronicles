#!/usr/bin/env bash
# demo-mode.sh - shorter waits for the review.
#
#   bash scripts/demo/demo-mode.sh on    every "for: 5m" alert fires after 1 minute
#   bash scripts/demo/demo-mode.sh off   back to the real 5 minutes (after the review)
#
# Affects NodeHighCPU, NodeHighMemory and PodPendingTooLong. Thresholds (80%,
# 90%...) never change - only how long the problem must last. The file in Git
# is not edited: "on" applies a changed copy, "off" applies the file as it is.
# Prometheus picks up the change within about 1 minute.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

RULES=manifests/monitoring/alert-rules.yaml
case "${1:-}" in
  on)
    sed 's/for: 5m/for: 1m/' "$RULES" | kubectl apply -f -
    echo "Demo mode ON: 5-minute alerts now fire after 1 minute." ;;
  off)
    kubectl apply -f "$RULES"
    echo "Demo mode OFF: real 5-minute windows are back." ;;
  *)
    echo "usage: bash scripts/demo/demo-mode.sh on|off" >&2; exit 1 ;;
esac