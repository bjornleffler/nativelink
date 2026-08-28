#!/usr/bin/env bash
# Tears the NativeLink deployment down between sessions, and rebuilds it.
#
#   ./scale.sh down             # DELETE the pools, VMs and NAT
#   ./scale.sh up               # rebuild them
#   ./scale.sh status           # what exists right now
#   ./scale.sh autoscale on|off # flip CREMA without touching anything else
#
# WHY DELETE RATHER THAN SCALE TO ZERO:
# A worker pool at --instances=0 already bills no compute, so scaling to zero
# was never the saving it looked like. What actually keeps costing money while
# the deployment is idle cannot be scaled at all - it can only be deleted:
#
#   - the Cloud NAT gateway, billed hourly whether or not a packet crosses it
#   - the VMs' persistent disks, billed while the VMs are merely stopped
#
# So `down` deletes. The cost of that is that `up` is now a rebuild taking
# several minutes rather than a flag flip, and the test client VM comes back
# empty - its 50GB disk, local Bazel cache and ~/cas-test workspace go with it.
# create-test-client.sh reinstalls Bazel and recreates the workspace.
#
# WHAT SURVIVES ON PURPOSE:
#   - the nl-proxy-ip static address. example/.bazelrc hardcodes the IP, so
#     releasing it would mean editing that file after every single rebuild.
#     It bills a small amount while unattached - that is the price of a stable
#     client endpoint.
#   - the CAS bucket. It is a cache; keeping it means the first build back is
#     warm instead of recompiling a hermetic LLVM toolchain from scratch.
#   - the Artifact Registry images, so `up` skips Cloud Build entirely.
#   - the VPC, subnets, firewall rules and DNS zone. All free, and recreating
#     them is where the fiddly failure modes live.
#
# To go further than this, delete those by hand - see AUTOSCALING.md and the
# comments in create-proxy.sh.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
CAS_POOL="${CAS_POOL:-nativelink-cas}"
SCHED_POOL="${SCHED_POOL:-nativelink-scheduler}"
WORKER_POOL="${WORKER_POOL:-nativelink-worker-x86}"
CC_WORKER_POOL="${CC_WORKER_POOL:-nativelink-worker-lre-cc}"
VPC="${VPC:-nl-vpc}"
VM="${VM:-nl-test-client}"
PROXY_VM="${PROXY_VM:-nl-proxy}"
ZONE="${ZONE:-${REGION}-a}"
CREMA_JOB="${CREMA_JOB:-nativelink-crema-tick}"

action="${1:-status}"
arg2="${2:-}"

# THE AUTOSCALER AND THIS SCRIPT FIGHT IF BOTH ARE ACTIVE.
#
# Once ./deploy-crema.sh has run, CREMA owns CC_WORKER_POOL. After a teardown
# the pool does not exist at all, so an un-paused tick job would log a
# not-found against a deleted scale target every single minute. `down` pauses
# it before deleting anything; `up` resumes it once the pool is back.

# autoscaler_state prints enabled/paused/absent for the CREMA tick job.
autoscaler_state() {
  gcloud scheduler jobs describe "${CREMA_JOB}" --location="${REGION}" \
    --project="${PROJECT}" --format="value(state)" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | grep -E "enabled|paused" || echo "absent"
}

# set_autoscaler pauses or resumes the CREMA tick job.
set_autoscaler() {
  local verb="$1"   # pause | resume
  if [[ "$(autoscaler_state)" == "absent" ]]; then
    return 0   # CREMA was never deployed; nothing to coordinate with.
  fi
  echo "==> ${verb%e}ing the autoscaler (${CREMA_JOB})"
  gcloud scheduler jobs "${verb}" "${CREMA_JOB}" --location="${REGION}" \
    --project="${PROJECT}" --quiet >/dev/null 2>&1 || echo "    (failed)"
}

# delete_pool removes a Cloud Run worker pool.
delete_pool() {
  echo "  worker-pool ${1}"
  gcloud run worker-pools delete "${1}" \
    --region="${REGION}" --project="${PROJECT}" --quiet >/dev/null 2>&1 \
    || echo "    (already gone)"
}

# ensure_vm_running starts an instance that exists but is stopped.
#
# `up` normally recreates VMs from scratch, but it must also converge from a
# merely-stopped VM: an older version of this script stopped them instead of
# deleting them, and a VM can be stopped by hand at any time. The create-*
# scripts use `instances create`, which reports "vm exists" and leaves a
# stopped VM stopped - so without this, `up` would report success against a
# deployment that is still down.
ensure_vm_running() {
  local status
  status=$(gcloud compute instances describe "${1}" --zone="${ZONE}" \
    --project="${PROJECT}" --format="value(status)" 2>/dev/null || true)
  if [[ "${status}" == "TERMINATED" || "${status}" == "SUSPENDED" ]]; then
    echo "  starting existing ${1} (was ${status})"
    gcloud compute instances start "${1}" --zone="${ZONE}" \
      --project="${PROJECT}" --quiet >/dev/null 2>&1 || echo "    (failed)"
  fi
}

# delete_vm removes a Compute Engine instance and its boot disk with it.
delete_vm() {
  echo "  instance ${1}"
  gcloud compute instances delete "${1}" \
    --zone="${ZONE}" --project="${PROJECT}" --quiet >/dev/null 2>&1 \
    || echo "    (already gone)"
}

case "${action}" in
  down)
    # Deleting is not reversible by re-running one command, and it destroys
    # the client VM's disk. Ask, unless told not to.
    if [[ "${arg2}" != "--yes" && "${arg2}" != "-y" ]]; then
      cat <<WARN
This DELETES, in project ${PROJECT}:

  worker pools : ${CC_WORKER_POOL}, ${WORKER_POOL}, ${SCHED_POOL}, ${CAS_POOL}
  instances    : ${VM}, ${PROXY_VM}   (and their boot disks)
  networking   : ${VPC}-nat, ${VPC}-router

It KEEPS the ${PROXY_VM}-ip static address, the CAS bucket, the Artifact
Registry images, and the VPC/subnets/firewall/DNS zone.

./scale.sh up rebuilds all of it, but takes several minutes and the test
client VM comes back with an empty disk.

WARN
      read -r -p "Type 'delete' to continue: " reply
      [[ "${reply}" == "delete" ]] || { echo "Aborted."; exit 1; }
    fi

    # Pause FIRST: CREMA must not be ticking against a pool being deleted.
    set_autoscaler pause

    echo "==> Deleting worker pools"
    # Workers before the scheduler before the CAS - the reverse of the order
    # `up` brings them back in, so nothing is ever left dialling a dependency
    # that has just been removed.
    delete_pool "${CC_WORKER_POOL}"
    delete_pool "${WORKER_POOL}"
    delete_pool "${SCHED_POOL}"
    delete_pool "${CAS_POOL}"

    echo "==> Deleting VMs"
    delete_vm "${VM}"
    delete_vm "${PROXY_VM}"

    echo "==> Deleting Cloud NAT"
    # NAT before router: the router owns the NAT config and will not delete
    # while it holds one.
    echo "  nat ${VPC}-nat"
    gcloud compute routers nats delete "${VPC}-nat" \
      --router="${VPC}-router" --region="${REGION}" \
      --project="${PROJECT}" --quiet >/dev/null 2>&1 || echo "    (already gone)"
    echo "  router ${VPC}-router"
    gcloud compute routers delete "${VPC}-router" \
      --region="${REGION}" --project="${PROJECT}" --quiet >/dev/null 2>&1 \
      || echo "    (already gone)"

    cat <<DONE

==> Torn down. Still billing, deliberately:
  - the ${PROXY_VM}-ip static address (keeps example/.bazelrc valid)
  - GCS storage for whatever is in the CAS bucket
  - Artifact Registry image storage

DONE
    ;;

  up)
    echo "==> Rebuilding. This takes several minutes."
    echo

    # 1. NAT first - the client VM has no external IP and hangs on a black
    #    hole without egress. create-test-client.sh creates the router, the
    #    NAT and the VM, in that order, and is idempotent.
    ./create-test-client.sh

    # 2. The pools. SKIP_BUILD because `down` kept the images; rebuilding them
    #    would add minutes and Cloud Build spend for an identical result.
    #    Drop it if you have changed a Dockerfile or a config/*.json5.
    SKIP_BUILD=1 ./deploy-nativelink.sh

    # 3. The proxy. Reuses the surviving static IP, so the endpoint in
    #    example/.bazelrc keeps working without edits.
    ./create-proxy.sh

    # 4. Converge any VM that existed but was stopped rather than deleted.
    echo "==> Ensuring VMs are running"
    ensure_vm_running "${VM}"
    ensure_vm_running "${PROXY_VM}"

    # 5. Hand the C++ pool back to CREMA, now that it exists again.
    set_autoscaler resume

    cat <<DONE

==> Rebuilt.

Give the DNS sidecars ~60s to publish - instance IPs are new, so workers will
log resolve failures until they do. Then check it actually came back:

  ./status.sh

If create-test-client.sh failed on its SSH step, the VM was probably not
booted yet. Re-running that script alone is safe and picks up where it left
off.
DONE
    ;;

  autoscale)
    case "${arg2}" in
      on)  set_autoscaler resume ;;
      off) set_autoscaler pause ;;
      *)   echo "usage: $0 autoscale {on|off}" >&2; exit 1 ;;
    esac
    echo "    autoscaler is now: $(autoscaler_state)"
    ;;

  status)
    echo "==> Autoscaler"
    echo "  ${CREMA_JOB}: $(autoscaler_state)"
    echo
    echo "==> Pools"
    gcloud run worker-pools list --region="${REGION}" --project="${PROJECT}" 2>&1 | head -6
    echo
    echo "==> VMs"
    gcloud compute instances list --project="${PROJECT}" \
      --format="table(name,machineType.basename(),status)" 2>&1 | head -4
    echo
    echo "==> Cloud NAT"
    gcloud compute routers describe "${VPC}-router" --region="${REGION}" \
      --project="${PROJECT}" --format="value(nats[0].name)" 2>/dev/null \
      | grep -q . && echo "  ${VPC}-nat exists (billing hourly)" \
      || echo "  absent - torn down"
    ;;

  *)
    echo "usage: $0 {down [--yes]|up|status|autoscale {on|off}}" >&2
    exit 1
    ;;
esac
