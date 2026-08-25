#!/usr/bin/env bash
# Reports whether the NativeLink deployment is actually healthy.
#
# Checks the three things that can each fail silently:
#   1. The DNS sidecar published the core's A record. If not, every worker is
#      pointed at a name that does not resolve.
#   2. Workers registered with the scheduler. A worker whose platform
#      properties do not match will connect but never claim work.
#   3. Blobs have reached the GCS bucket. Until then the CAS slow tier is
#      unproven no matter what the config says.
set -uo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
DNS_ZONE="${DNS_ZONE:-nl-internal}"
CAS_POOL="${CAS_POOL:-nativelink-cas}"
SCHED_POOL="${SCHED_POOL:-nativelink-scheduler}"
WORKER_POOL="${WORKER_POOL:-nativelink-worker-x86}"
BUCKET="${BUCKET:-${PROJECT}-nativelink-cas}"

echo "=============================================================="
echo " NativeLink deployment status - ${PROJECT}/${REGION}"
echo "=============================================================="

echo
echo "--- [1] Worker pools ---"
gcloud run worker-pools list --region="${REGION}" --project="${PROJECT}" 2>&1 | head -5

echo
echo "--- [2] DNS record (core service discovery) ---"
records=$(gcloud dns record-sets list --zone="${DNS_ZONE}" --project="${PROJECT}" \
  --format="table(name,type,ttl,rrdatas[0])" 2>&1)
echo "${records}"
if echo "${records}" | grep -q "nativelink-cas" && echo "${records}" | grep -q "nativelink-scheduler"; then
  echo "    OK: both sidecars published their addresses."
else
  echo "    PROBLEM: missing an A record. Workers need BOTH nativelink-cas
    (for blobs) and nativelink-scheduler (for the worker API)."
  echo "    Check the dns-register sidecar logs (step 4 below)."
fi

echo
echo "--- [3] Worker registration ---"
reg=$(gcloud logging read \
  "resource.type=cloud_run_worker_pool AND resource.labels.worker_pool_name=${WORKER_POOL}" \
  --limit=30 --format="value(textPayload)" --freshness=30m --project="${PROJECT}" 2>/dev/null)
if echo "${reg}" | grep -q "Worker registered with scheduler"; then
  echo "    OK: at least one worker registered."
  echo "${reg}" | grep "Worker registered with scheduler" | head -3
else
  echo "    No registration seen in the last 30m. Recent worker log lines:"
  echo "${reg}" | grep -viE "^\s*$" | head -8
fi

echo
echo "--- [4] CAS and scheduler logs ---"
for pool in "${CAS_POOL}" "${SCHED_POOL}"; do
  echo "  ---- ${pool} ----"
  gcloud logging read \
    "resource.type=cloud_run_worker_pool AND resource.labels.worker_pool_name=${pool}" \
    --limit=15 --format="value(textPayload)" --freshness=30m --project="${PROJECT}" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -viE "^\s*$|^\s+(at|in) " | head -6
done

echo
echo "--- [5] CAS bucket contents (proof the GCS tier is live) ---"
objects=$(gcloud storage ls -r "gs://${BUCKET}/**" --project="${PROJECT}" 2>/dev/null | head -10)
if [[ -n "${objects}" ]]; then
  echo "${objects}"
  echo "    OK: blobs have reached GCS."
else
  echo "    Bucket is empty. Expected until a build runs - or the fast tier"
  echo "    has not evicted yet. Run ./verify-cas.sh to force a round-trip."
fi
