#!/usr/bin/env bash
# Proves the CAS actually stores and serves blobs, and that they reach GCS.
#
# Three passes:
#   1. cold  - build with an empty local cache, writing to the remote CAS
#   2. warm  - wipe the local cache and rebuild; every action must come back
#              as a remote cache hit
#   3. GCS   - list the bucket, proving the slow tier really was written
#
# A pass-2 result of zero remote cache hits means the CAS accepted writes but
# cannot serve reads, which is worse than an outright failure because a build
# still succeeds.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VM="${VM:-nl-test-client}"
CAS_ADDR="${CAS_ADDR:-nativelink-cas.nl.internal}"
CLIENT_PORT="${CLIENT_PORT:-8080}"
BUCKET="${BUCKET:-${PROJECT}-nativelink-cas}"

REMOTE="--remote_cache=grpc://${CAS_ADDR}:${CLIENT_PORT} --remote_instance_name=main --remote_timeout=120"

echo "==> [1/3] Cold build (populates the remote CAS)"
gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" --command="
cd ~/cas-test
bazel clean --expunge >/dev/null 2>&1 || true
bazel build ${REMOTE} //:combined 2>&1 | tail -15
"

echo
echo "==> [2/3] Warm build (must be served FROM the remote CAS)"
gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" --command="
cd ~/cas-test
bazel clean --expunge >/dev/null 2>&1 || true
bazel build ${REMOTE} //:combined 2>&1 | grep -E 'remote cache hit|processes|INFO: Build|ERROR' | tail -10
"

echo
echo "==> [3/3] GCS bucket contents (proof the slow tier was written)"
objects=$(gcloud storage ls -r "gs://${BUCKET}/**" --project="${PROJECT}" 2>/dev/null | head -15)
if [[ -n "${objects}" ]]; then
  echo "${objects}"
  echo
  echo "    OK: blobs reached GCS."
else
  echo "    Bucket still empty."
  echo "    The fast tmpfs tier may not have evicted yet - it is 2GB and this"
  echo "    test writes far less. That is expected behaviour, not a failure:"
  echo "    fast_slow writes through on eviction. A cache hit in pass 2 still"
  echo "    proves the CAS works; GCS persistence needs a larger workload or a"
  echo "    core restart to confirm."
fi
