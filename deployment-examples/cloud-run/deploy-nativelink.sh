#!/usr/bin/env bash
# Deploys NativeLink (scheduler + CAS core, and a worker fleet) to Cloud Run.
#
# Architecture:
#   - core:    Cloud Run worker pool, 1 instance, Direct VPC, TWO ports
#              (client frontend + worker API on separate ports, per upstream's
#              intended permission split - possible because worker pools get a
#              real subnet NIC rather than a single-port HTTP proxy).
#   - workers: Cloud Run worker pool, N instances, no listener, dials the core.
#   - CAS:     GCS bucket behind a tmpfs-backed fast tier.
#
# Core and workers live in SEPARATE SUBNETS so firewall rules can distinguish
# them: only the worker subnet may reach the worker API port. Worker pools
# cannot use network tags for ingress rules, so source ranges are the lever.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
VPC="${VPC:-nl-vpc}"
CORE_SUBNET="${CORE_SUBNET:-nl-core-subnet}"
CORE_RANGE="${CORE_RANGE:-10.20.0.0/24}"
WORKER_SUBNET="${WORKER_SUBNET:-nl-worker-subnet}"
WORKER_RANGE="${WORKER_RANGE:-10.21.0.0/24}"
CLIENT_RANGE="${CLIENT_RANGE:-10.20.0.0/16}"   # who may reach the build API
BUCKET="${BUCKET:-${PROJECT}-nativelink-cas}"
REPO="${REPO:-nativelink}"
CAS_POOL="${CAS_POOL:-nativelink-cas}"
SCHED_POOL="${SCHED_POOL:-nativelink-scheduler}"
WORKER_POOL="${WORKER_POOL:-nativelink-worker-x86}"
NATIVELINK_VERSION="${NATIVELINK_VERSION:-v1.6.6}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/nativelink:${NATIVELINK_VERSION}"

DNS_ZONE="${DNS_ZONE:-nl-internal}"
DNS_INBOUND_POLICY="${DNS_INBOUND_POLICY:-nl-inbound}"
DNS_DOMAIN="${DNS_DOMAIN:-nl.internal.}"
CAS_DNS_NAME="${CAS_DNS_NAME:-nativelink-cas.${DNS_DOMAIN}}"
SCHED_DNS_NAME="${SCHED_DNS_NAME:-nativelink-scheduler.${DNS_DOMAIN}}"
SIDECAR_IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/dns-register:latest"

CORE_SA="nativelink-core@${PROJECT}.iam.gserviceaccount.com"
WORKER_SA="nativelink-worker@${PROJECT}.iam.gserviceaccount.com"

CLIENT_PORT="${CLIENT_PORT:-8080}"      # injected by Cloud Run as PORT
WORKER_API_PORT="${WORKER_API_PORT:-50061}"
# PROTOTYPE SIZING - deliberately minimal to keep spend down.
#
# The fast-tier cache budgets below MUST move with memory. Those caches live on
# tmpfs, so every cached byte is instance RAM: setting CAS_MEM=2Gi while the
# store config still budgets 3GB of cache guarantees an OOM. The NL_*_BYTES
# values are passed through to the store config for exactly this reason.
#
# Raise these together when moving past prototype.
CAS_CPU="${CAS_CPU:-1}"
CAS_MEM="${CAS_MEM:-2Gi}"
CAS_INDEX_BYTES="${CAS_INDEX_BYTES:-100000000}"    # 100MB
CAS_CONTENT_BYTES="${CAS_CONTENT_BYTES:-500000000}" # 500MB
CAS_AC_BYTES="${CAS_AC_BYTES:-100000000}"          # 100MB
                                                    # ~700MB cache in 2Gi
SCHED_CPU="${SCHED_CPU:-1}"
SCHED_MEM="${SCHED_MEM:-1Gi}"   # holds queue state only, no storage
WORKER_CPU="${WORKER_CPU:-2}"
WORKER_MEM="${WORKER_MEM:-4Gi}"
WORKER_CACHE_BYTES="${WORKER_CACHE_BYTES:-500000000}" # 500MB of the 4Gi
WORKER_COUNT="${WORKER_COUNT:-1}"

echo "==> project=${PROJECT} region=${REGION} version=${NATIVELINK_VERSION}"

echo "==> [1/8] Enabling APIs"
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  compute.googleapis.com storage.googleapis.com cloudbuild.googleapis.com \
  dns.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com --project="${PROJECT}"

echo "==> [2/8] Network: one VPC, separate subnets for core and workers"
gcloud compute networks create "${VPC}" --subnet-mode=custom \
  --project="${PROJECT}" 2>/dev/null || echo "    vpc exists"
gcloud compute networks subnets create "${CORE_SUBNET}" --network="${VPC}" \
  --range="${CORE_RANGE}" --region="${REGION}" --project="${PROJECT}" 2>/dev/null || echo "    core subnet exists"
gcloud compute networks subnets create "${WORKER_SUBNET}" --network="${VPC}" \
  --range="${WORKER_RANGE}" --region="${REGION}" --project="${PROJECT}" 2>/dev/null || echo "    worker subnet exists"

# Only workers may reach the worker API. This is the boundary that a
# single-port deployment would have destroyed.
gcloud compute firewall-rules create "${VPC}-worker-api" --network="${VPC}" \
  --allow="tcp:${WORKER_API_PORT}" --source-ranges="${WORKER_RANGE}" \
  --project="${PROJECT}" 2>/dev/null || echo "    worker-api rule exists"
# Build clients reach only the CAS/AC/execution frontend.
gcloud compute firewall-rules create "${VPC}-client-api" --network="${VPC}" \
  --allow="tcp:${CLIENT_PORT}" --source-ranges="${CLIENT_RANGE},${WORKER_RANGE}" \
  --project="${PROJECT}" 2>/dev/null || echo "    client-api rule exists"

echo "==> [3/8] GCS bucket for the CAS"
gcloud storage buckets create "gs://${BUCKET}" --location="${REGION}" \
  --uniform-bucket-level-access --project="${PROJECT}" 2>/dev/null || echo "    bucket exists"

echo "==> [3b/8] Private DNS zone (gives the core a stable name)"
# Worker pool instance IPs are ephemeral and Cloud Run exposes no API to list
# them, so the core publishes its own A record here via a sidecar.
# NOTE: do NOT swallow errors here with `2>/dev/null || echo exists`. Doing so
# previously hid a disabled dns.googleapis.com, so the zone was never created,
# the sidecar could not publish, and every worker failed to resolve the core -
# with the deploy still reporting success.
if ! zone_err=$(gcloud dns managed-zones create "${DNS_ZONE}" \
  --dns-name="${DNS_DOMAIN}" --visibility=private --networks="${VPC}" \
  --description="NativeLink internal service discovery" \
  --project="${PROJECT}" 2>&1); then
  # gcloud phrases this as "already exists" / "subject of a conflict",
  # not "alreadyExists" - match loosely so a benign rerun is not fatal.
  if echo "${zone_err}" | grep -qiE "already exists|alreadyExists|subject of a conflict"; then
    echo "    dns zone exists"
  else
    echo "    FATAL: could not create DNS zone:" >&2
    echo "${zone_err}" >&2
    exit 1
  fi
fi

# On-prem resolvers cannot see a private Cloud DNS zone by default. An inbound
# server policy allocates forwarder IPs inside the VPC that an on-prem DNS
# server can forward nl.internal queries to. Without this, clients across the
# VPN resolve nativelink-core.nl.internal to nothing, even though the tunnel
# itself is healthy.
echo "==> [3c/7] Cloud DNS inbound forwarding (for clients across the VPN)"
gcloud dns policies create "${DNS_INBOUND_POLICY}" \
  --networks="${VPC}" \
  --enable-inbound-forwarding \
  --description="Let on-prem resolvers query ${DNS_DOMAIN}" \
  --project="${PROJECT}" 2>/dev/null || echo "    inbound policy exists"

echo "==> [4/8] Service accounts and IAM"
gcloud iam service-accounts create nativelink-core --project="${PROJECT}" 2>/dev/null || echo "    core sa exists"
gcloud iam service-accounts create nativelink-worker --project="${PROJECT}" 2>/dev/null || echo "    worker sa exists"
# The core is the only thing that touches the bucket, scoped to that bucket.
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${CORE_SA}" --role=roles/storage.objectAdmin \
  --project="${PROJECT}" >/dev/null
# The sidecar needs to write the core's A record.
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${CORE_SA}" --role=roles/dns.admin \
  --condition=None >/dev/null

echo "==> [5/8] Image (upstream + CA certificates - upstream ships none)"
gcloud artifacts repositories create "${REPO}" --repository-format=docker \
  --location="${REGION}" --project="${PROJECT}" 2>/dev/null || echo "    repo exists"
# Built in Cloud Build, not locally: pushing layers from a laptop proved
# unreliable, and Cloud Build sits next to Artifact Registry.
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions="_NATIVELINK_VERSION=${NATIVELINK_VERSION},_REGION=${REGION},_REPO=${REPO}" \
  --project="${PROJECT}" .

echo "==> [6/7] Deploying CAS and scheduler as separate pools"
# Split deliberately: the scheduler holds queue state in memory and is pinned
# to one instance. Sharing a pool made CAS inherit that cap and let blob
# uploads compete with the one component coordinating the whole farm.
#
# NOTE: every non-container-specific flag (--project included) MUST appear
# before the first --container, or gcloud parses it as belonging to that
# container and rejects it as an unrecognized argument.

# --- CAS: storage only, GCS-backed. One instance on purpose: the filesystem
# --- fast tier is instance-local and NativeLink has no cross-instance
# --- coordination for it, so N instances would mean N diluted caches.
gcloud run worker-pools deploy "${CAS_POOL}" \
  --project="${PROJECT}" \
  --region="${REGION}" --instances=1 \
  --service-account="${CORE_SA}" \
  --network="${VPC}" --subnet="${CORE_SUBNET}" \
  --container=nativelink \
    --image="${IMAGE}" \
    --cpu="${CAS_CPU}" --memory="${CAS_MEM}" \
    --set-env-vars="NL_GCS_BUCKET=${BUCKET},NL_INDEX_CACHE_BYTES=${CAS_INDEX_BYTES},NL_CAS_CACHE_BYTES=${CAS_CONTENT_BYTES},NL_AC_CACHE_BYTES=${CAS_AC_BYTES}" \
    --args="/etc/nativelink/cas.json5" \
  --container=dns-register \
    --image="${SIDECAR_IMAGE}" \
    --cpu=1 --memory=512Mi \
    --set-env-vars="DNS_ZONE=${DNS_ZONE},DNS_NAME=${CAS_DNS_NAME},TTL=60"

CAS_ADDR="${CAS_DNS_NAME%.}"
echo "    CAS at ${CAS_ADDR}:${CLIENT_PORT}"

# --- Scheduler: no storage of its own; reads action protos from the CAS pool.
# --- MUST stay at one instance - queue state lives in memory.
gcloud run worker-pools deploy "${SCHED_POOL}" \
  --project="${PROJECT}" \
  --region="${REGION}" --instances=1 \
  --service-account="${CORE_SA}" \
  --network="${VPC}" --subnet="${CORE_SUBNET}" \
  --container=nativelink \
    --image="${IMAGE}" \
    --cpu="${SCHED_CPU}" --memory="${SCHED_MEM}" \
    --set-env-vars="NL_CAS_ENDPOINT=${CAS_ADDR}:${CLIENT_PORT},NL_WORKER_API_PORT=${WORKER_API_PORT}" \
    --args="/etc/nativelink/scheduler.json5" \
  --container=dns-register \
    --image="${SIDECAR_IMAGE}" \
    --cpu=1 --memory=512Mi \
    --set-env-vars="DNS_ZONE=${DNS_ZONE},DNS_NAME=${SCHED_DNS_NAME},TTL=60"

SCHED_ADDR="${SCHED_DNS_NAME%.}"
echo "    scheduler at ${SCHED_ADDR}:${CLIENT_PORT} (worker API :${WORKER_API_PORT})"

echo "==> [7/7] Deploying worker fleet"
gcloud run worker-pools deploy "${WORKER_POOL}" \
  --image="${IMAGE}" --region="${REGION}" --instances="${WORKER_COUNT}" \
  --cpu="${WORKER_CPU}" --memory="${WORKER_MEM}" \
  --service-account="${WORKER_SA}" \
  --network="${VPC}" --subnet="${WORKER_SUBNET}" \
  --set-env-vars="NL_CAS_ENDPOINT=${CAS_ADDR}:${CLIENT_PORT},NL_SCHEDULER_ENDPOINT=${SCHED_ADDR}:${WORKER_API_PORT},NL_WORKER_CPU_COUNT=${WORKER_CPU},NL_WORKER_CACHE_BYTES=${WORKER_CACHE_BYTES},NL_WORKER_PLATFORM=${NL_WORKER_PLATFORM:-undefined_platform}" \
  --args="/etc/nativelink/worker.json5" \
  --project="${PROJECT}"

cat <<NEXT

==> Deployed.

  CAS (cache/blobs)  : ${CAS_ADDR}:${CLIENT_PORT}
  scheduler (exec)   : ${SCHED_ADDR}:${CLIENT_PORT}
  worker API         : ${SCHED_ADDR}:${WORKER_API_PORT}  (worker subnet only)
  CAS bucket         : gs://${BUCKET}

Point Bazel at it from inside the VPC. Note these are now TWO endpoints -
caching and execution are served by separate pools:

  build --remote_cache=grpc://${CAS_ADDR}:${CLIENT_PORT}
  build --remote_executor=grpc://${SCHED_ADDR}:${CLIENT_PORT}
  build --remote_instance_name=main

STILL UNVERIFIED - check these before trusting the deployment:
  1. No blob has ever been written to or read from GCS. Run a real build.
  2. Your Bazel platform exec_properties 'container-image' must match
     NL_WORKER_PLATFORM exactly, or actions queue forever with no error.
  3. Confirm the sidecar actually published the A record:
       gcloud dns record-sets list --zone=${DNS_ZONE} --project=${PROJECT}
NEXT
