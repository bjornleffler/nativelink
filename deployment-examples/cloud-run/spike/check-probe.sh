#!/usr/bin/env bash
# Reads the current state of the detached probe running on the client VM.
set -euo pipefail
PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VM="${VM:-nl-spike-client}"

gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" \
  --command="echo '--- running? ---'; pgrep -a spike-client || echo '(probe finished)'; echo '--- log tail ---'; tail -25 ~/spike-result.log 2>/dev/null || echo '(no log yet)'"
