#!/usr/bin/env bash
# Proves the autoscaling signal is real, and watches it work.
#
#   ./verify-autoscaling.sh series   # Phase 0: does the metric exist at all?
#   ./verify-autoscaling.sh metric   # one-shot queue depth, broken out by stage
#   ./verify-autoscaling.sh watch    # live metric + instance count, every 15s
#
# WHY A SEPARATE SCRIPT: CREMA cannot tell "the queue is empty" from "the
# metric was never written". Both look like zero, and neither logs an error.
# `series` is the check that distinguishes them, and it is worth running
# BEFORE deploying CREMA at all - if the metric is not in Cloud Monitoring,
# nothing downstream can work and everything downstream will look fine.
set -uo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
CC_WORKER_POOL="${CC_WORKER_POOL:-nativelink-worker-lre-cc}"
INTERVAL="${INTERVAL:-15}"

PROM="https://monitoring.googleapis.com/v1/projects/${PROJECT}/location/global/prometheus"

# The mangled form of workload.googleapis.com/execution.active.count. Cloud
# Monitoring's PromQL rules: the first "/" becomes ":", every other special
# character becomes "_".
METRIC="workload_googleapis_com:execution_active_count"

# REQUIRED, NOT OPTIONAL. Cloud Monitoring's PromQL endpoint refuses any
# workload.googleapis.com selector that does not pin monitored_resource:
#   "must specify a label matcher on the 'monitored_resource' label because
#    multiple monitored resource types [...]"
# The googlecloud exporter writes this metric as generic_task, with job and
# task_id taken from the resource/stable_identity processor in
# otel/collector.yaml. Confirmed against the live deployment 2026-08-28.
RESOURCE='monitored_resource="generic_task"'


# promql runs an instant query and prints the raw JSON response.
promql() {
  curl -s -G \
    -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
    --data-urlencode "query=$1" \
    "${PROM}/api/v1/query"
}

# scalar_of extracts a single numeric result, or empty if there is none.
scalar_of() {
  python3 -c "
import json,sys
try:
    r = json.load(sys.stdin).get('data', {}).get('result', [])
except Exception:
    sys.exit(0)
print(r[0]['value'][1] if r else '')
"
}

# instances prints the pool's current instance count.
# The JSON field name survives gcloud releases better than any --format path
# for worker pools, so grep it rather than projecting it.
instances() {
  gcloud run worker-pools describe "${CC_WORKER_POOL}" \
    --region="${REGION}" --project="${PROJECT}" --format=json 2>/dev/null \
    | tr -d ' "' | grep -oE 'manualInstanceCount:[0-9]+' | head -1 | grep -oE '[0-9]+$'
}

QUEUE_QUERY="sum(${METRIC}{${RESOURCE}, execution_stage=~\"queued|executing\"})"

case "${1:-metric}" in
  series)
    echo "==> Every series of ${METRIC}"
    echo
    promql "${METRIC}{${RESOURCE}}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('  Could not parse the response. Is monitoring.googleapis.com enabled?')
    sys.exit(1)
if d.get('status') != 'success':
    print('  Query failed:', json.dumps(d)[:400]); sys.exit(1)
res = d['data']['result']
if not res:
    print('  NOTHING. The metric does not exist in Cloud Monitoring.')
    print()
    print('  In order of likelihood:')
    print('   1. No build has run yet - the scheduler only emits this once an')
    print('      action passes through it. Run a build, wait 3 minutes, retry.')
    print('   2. The otel-collector sidecar is not deployed. Redeploy with')
    print('      ./deploy-nativelink.sh.')
    print('   3. nativelink-core lacks roles/monitoring.metricWriter, so the')
    print('      collector logs PermissionDenied on every export.')
    print('   4. The mangled name or label key differs from what is assumed')
    print('      here. Check the metric explorer for workload.googleapis.com/')
    print('      execution.active.count and fix METRIC in this script AND the')
    print('      query in crema/config.yaml.tmpl - they must agree.')
    sys.exit(1)
for s in res:
    labels = {k: v for k, v in s['metric'].items() if k != '__name__'}
    print(f\"  {s['value'][1]:>8}  {labels}\")
print()
print('  Confirm: the label key is execution_stage, and stage values include')
print('  queued and executing. crema/config.yaml.tmpl filters on both.')
"
    ;;

  metric)
    echo "==> Queue depth by stage"
    for stage in queued executing completed cache_check; do
      v=$(promql "sum(${METRIC}{${RESOURCE}, execution_stage=\"${stage}\"})" | scalar_of)
      printf "  %-12s %s\n" "${stage}" "${v:--}"
    done
    echo
    echo "==> What CREMA scales on (queued + executing)"
    echo "  $(promql "${QUEUE_QUERY}" | scalar_of)"
    echo
    echo "SANITY CHECK: with no build running, queued and executing should both"
    echo "read 0. A queued count that only ever climbs means the gauge is"
    echo "leaking and CREMA would scale up forever - see AUTOSCALING.md."
    ;;

  watch)
    echo "==> Watching ${CC_WORKER_POOL}. Ctrl-C to stop."
    echo "    Generate load from the test client VM, e.g.:"
    echo "      cd example && bazel build --config=internal //:hello"
    echo
    printf "%-10s %10s %12s %12s\n" "time" "instances" "queued" "executing"
    while true; do
      q=$(promql "sum(${METRIC}{${RESOURCE}, execution_stage=\"queued\"})" | scalar_of)
      x=$(promql "sum(${METRIC}{${RESOURCE}, execution_stage=\"executing\"})" | scalar_of)
      printf "%-10s %10s %12s %12s\n" \
        "$(date +%H:%M:%S)" "$(instances)" "${q:--}" "${x:--}"
      sleep "${INTERVAL}"
    done
    ;;

  *)
    echo "usage: $0 {series|metric|watch}" >&2
    exit 1
    ;;
esac
