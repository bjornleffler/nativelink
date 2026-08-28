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
#   4. If CREMA is deployed: the queue-depth metric is actually reaching Cloud
#      Monitoring. A missing metric reads as an idle farm, so the worker pool
#      never scales up and nothing anywhere logs an error.
set -uo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
DNS_ZONE="${DNS_ZONE:-nl-internal}"
CAS_POOL="${CAS_POOL:-nativelink-cas}"
CC_WORKER_POOL="${CC_WORKER_POOL:-nativelink-worker-lre-cc}"
CREMA_JOB="${CREMA_JOB:-nativelink-crema-tick}"
CREMA_SERVICE="${CREMA_SERVICE:-nativelink-crema}"
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

echo
echo "--- [6] Autoscaling (CREMA) ---"
if ! gcloud run services describe "${CREMA_SERVICE}" --region="${REGION}" \
     --project="${PROJECT}" >/dev/null 2>&1; then
  echo "    Not deployed. Worker pools are on manual instance counts; use"
  echo "    ./scale.sh. Run ./deploy-crema.sh to enable autoscaling."
else
  tick=$(gcloud scheduler jobs describe "${CREMA_JOB}" --location="${REGION}" \
    --project="${PROJECT}" --format="value(state)" 2>/dev/null || echo "ABSENT")
  echo "  tick job    : ${CREMA_JOB} = ${tick:-ABSENT}"
  if [[ "${tick}" == "PAUSED" ]]; then
    echo "    NOTE: paused, so nothing is autoscaling. ./scale.sh down pauses"
    echo "    it deliberately before deleting the pool; ./scale.sh up rebuilds"
    echo "    the pool and resumes it."
  fi

  # The pool's current size. The JSON field name is more stable across gcloud
  # releases than any --format path for worker pools, so grep it directly.
  count=$(gcloud run worker-pools describe "${CC_WORKER_POOL}" \
    --region="${REGION}" --project="${PROJECT}" --format=json 2>/dev/null \
    | tr -d ' "' | grep -oE 'manualInstanceCount:[0-9]+' | head -1 | grep -oE '[0-9]+$')
  echo "  ${CC_WORKER_POOL}: ${count:-unknown} instances"

  # THE LOAD-BEARING CHECK. Everything else can look healthy while this is
  # empty, and an empty result is indistinguishable from an idle farm.
  echo "  queue depth (queued+executing):"
  # monitored_resource is required by Cloud Monitoring's PromQL endpoint.
  q='sum(workload_googleapis_com:execution_active_count{monitored_resource="generic_task",execution_stage=~"queued|executing"})'
  val=$(curl -s -G \
    -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
    --data-urlencode "query=${q}" \
    "https://monitoring.googleapis.com/v1/projects/${PROJECT}/location/global/prometheus/api/v1/query" \
    2>/dev/null | python3 -c "
import json,sys
try:
    r = json.load(sys.stdin).get('data', {}).get('result', [])
except Exception:
    sys.exit(1)
print(r[0]['value'][1] if r else '')
" 2>/dev/null)
  if [[ -n "${val}" ]]; then
    echo "    ${val}"
  else
    echo "    NO DATA. Either the farm has been idle long enough for the"
    echo "    series to go stale, or the metric is not arriving at all. In the"
    echo "    second case CREMA will never scale up and will log no error."
    echo "    Check the collector sidecar:"
    echo "      gcloud logging read 'resource.labels.worker_pool_name=${SCHED_POOL}' \\"
    echo "        --freshness=15m --project=${PROJECT} | grep -i otelcol"
    echo "    A PermissionDenied there means nativelink-core is missing"
    echo "    roles/monitoring.metricWriter."
  fi

  echo "  recent scale decisions:"
  gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=${CREMA_SERVICE}" \
    --limit=20 --format="value(textPayload)" --freshness=30m --project="${PROJECT}" 2>/dev/null \
    | grep -E "\[SCALER\]|\[METRIC-PROVIDER\]" | head -5 \
    || echo "    (none in the last 30m)"
fi
