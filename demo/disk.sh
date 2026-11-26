#!/usr/bin/env bash
# disk.sh - review test: less than 20% disk space left (NodeLowDiskSpace).
#
#   bash scripts/demo/disk.sh        reserve space until only 18% is free
#   bash scripts/demo/disk.sh stop   delete the file again
#
# fallocate reserves the space at once without writing data, so it takes a
# second and doesn't wear the disk. Runs as root on the node (node_pod).
# 18% free still leaves several GB, above Elasticsearch's disk watermarks.
# Expected: Firing after about 1-2 minutes, Resolved ~1 minute after stop.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "stop" ]]; then
  node_run demo-disk 'rm -f /var/demo-disk-fill.img && echo "Removed /var/demo-disk-fill.img"
df -h / | tail -1'
  exit 0
fi

node_run demo-disk 'set -- $(df -B1 --output=avail,size / | tail -1)
fill=$(( $1 - $2 * 18 / 100 ))
if [ "$fill" -le 0 ]; then
  echo "Already less than 18% free - nothing to do"
else
  fallocate -l "$fill" /var/demo-disk-fill.img
  echo "Reserved $(( fill / 1024 / 1024 )) MB in /var/demo-disk-fill.img"
fi
df -h / | tail -1'
echo "Expected: NodeLowDiskSpace after ~1-2 min. Clean up: bash scripts/demo/disk.sh stop"
where_to_look