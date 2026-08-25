#!/usr/bin/env bash
# Scales the NativeLink pools up or down.
#
# WHY THIS EXISTS: Cloud Run worker pools do NOT scale to zero on their own.
# Unlike Cloud Run services, an idle pool bills at full rate around the clock.
# For a prototype that is used occasionally, parking the pools at zero between
# sessions is the single biggest cost lever available.
#
#   ./scale.sh down   # everything to 0 instances - stops the meter
#   ./scale.sh up     # back to prototype sizing
#   ./scale.sh status # what is running right now
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
CAS_POOL="${CAS_POOL:-nativelink-cas}"
SCHED_POOL="${SCHED_POOL:-nativelink-scheduler}"
WORKER_POOL="${WORKER_POOL:-nativelink-worker-x86}"
CC_WORKER_POOL="${CC_WORKER_POOL:-nativelink-worker-lre-cc}"
VM="${VM:-nl-test-client}"
PROXY_VM="${PROXY_VM:-nl-proxy}"
ZONE="${ZONE:-${REGION}-a}"

action="${1:-status}"

# scale_pool sets a worker pool's instance count.
scale_pool() {
  local pool="$1" count="$2"
  echo "  ${pool} -> ${count}"
  gcloud run worker-pools update "${pool}" \
    --region="${REGION}" --instances="${count}" \
    --project="${PROJECT}" >/dev/null 2>&1 || echo "    (failed - pool may not exist)"
}

case "${action}" in
  down)
    echo "==> Scaling everything to zero"
    scale_pool "${CC_WORKER_POOL}" 0
    scale_pool "${WORKER_POOL}" 0
    scale_pool "${SCHED_POOL}" 0
    scale_pool "${CAS_POOL}" 0
    echo "==> Stopping VMs"
    for vm in "${VM}" "${PROXY_VM}"; do
      echo "  ${vm}"
      gcloud compute instances stop "${vm}" --zone="${ZONE}" --project="${PROJECT}" --quiet 2>/dev/null \
        || echo "    (not found or already stopped)"
    done
    echo
    echo "Stopped. Note that these still cost a little even at zero:"
    echo "  - Cloud NAT gateway (hourly, whether used or not)"
    echo "  - GCS storage for whatever is in the CAS bucket"
    echo "  - Artifact Registry image storage"
    echo "  - the stopped VMs' persistent disks"
    echo "  - the proxy's reserved static IP (charged while NOT attached to"
    echo "    a running instance, so stopping the VM slightly increases it)"
    echo "Delete the NAT too if you will not be back for a while:"
    echo "  gcloud compute routers nats delete nl-vpc-nat --router=nl-vpc-router --region=${REGION}"
    ;;
  up)
    echo "==> Restoring prototype sizing"
    # CAS first: the scheduler reads action protos from it, and workers need
    # both before they can register and claim work.
    scale_pool "${CAS_POOL}" 1
    scale_pool "${SCHED_POOL}" 1
    scale_pool "${WORKER_POOL}" 1
    scale_pool "${CC_WORKER_POOL}" 1
    echo "==> Starting VMs"
    for vm in "${VM}" "${PROXY_VM}"; do
      echo "  ${vm}"
      gcloud compute instances start "${vm}" --zone="${ZONE}" --project="${PROJECT}" --quiet 2>/dev/null \
        || echo "    (not found)"
    done
    echo
    echo "Give the sidecars ~60s to republish DNS - instance IPs change on"
    echo "restart, so workers will log resolve failures until they do."
    ;;
  status)
    echo "==> Pools"
    gcloud run worker-pools list --region="${REGION}" --project="${PROJECT}" 2>&1 | head -5
    echo
    echo "==> VM"
    gcloud compute instances list --project="${PROJECT}" \
      --format="table(name,machineType.basename(),status)" 2>&1 | head -4
    ;;
  *)
    echo "usage: $0 {down|up|status}" >&2
    exit 1
    ;;
esac
