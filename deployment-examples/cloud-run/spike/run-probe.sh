#!/usr/bin/env bash
# Cross-compiles the probe client, copies it to the in-VPC VM, and runs it
# against the worker pool instance. Requires deploy.sh to have completed.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VM="${VM:-nl-spike-client}"
DURATION="${DURATION:-75m}"
SPIKE_IP="${SPIKE_IP:-}"

# Discover the worker pool instance IP if the caller did not supply one.
if [[ -z "${SPIKE_IP}" ]]; then
  echo "==> Discovering SPIKE_IP from Cloud Logging"
  SPIKE_IP=$(gcloud logging read \
    'resource.type=cloud_run_worker_pool AND textPayload:SPIKE_IP' \
    --limit=1 --format="value(textPayload)" --freshness=30m \
    --project="${PROJECT}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

if [[ -z "${SPIKE_IP}" ]]; then
  echo "ERROR: could not find SPIKE_IP in Cloud Logging."
  echo "  The pool may still be starting, or it never got a VPC address at all."
  echo "  That second case is itself a finding: no Direct VPC ingress for worker pools."
  exit 1
fi
echo "==> worker pool instance IP: ${SPIKE_IP}"

echo "==> Cross-compiling client for linux/amd64"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/spike-client-linux ./cmd/client

echo "==> Copying client to ${VM}"
gcloud compute scp /tmp/spike-client-linux "${VM}":~/spike-client \
  --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT}"

# A short reachability check first - no point burning 75 minutes if the
# instance is not reachable at all.
echo "==> Smoke test (90s) to confirm reachability"
gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" \
  --command="chmod +x ~/spike-client && ~/spike-client -host ${SPIKE_IP} -duration 90s 2>&1 | tail -20"

echo
echo "==> Launching full ${DURATION} probe, detached"
gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" \
  --command="nohup ~/spike-client -host ${SPIKE_IP} -duration ${DURATION} > ~/spike-result.log 2>&1 & echo started pid=\$!"

echo
echo "==> Probe running. Check it with:"
echo "    ./check-probe.sh"
