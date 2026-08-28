#!/usr/bin/env bash
# Deploys CREMA (Cloud Run External Metrics Autoscaling) so the NativeLink
# worker pool scales itself on the scheduler's action queue depth.
#
#   ./deploy-crema.sh          # create or update the autoscaler
#   ./deploy-crema.sh delete   # remove it and hand the pool back to scale.sh
#
# PREREQUISITE: the OTel collector sidecar must already be exporting
# execution.active.count to Cloud Monitoring. Run ./deploy-nativelink.sh first,
# then confirm the metric exists with ./verify-autoscaling.sh - CREMA cannot
# distinguish "the metric reads zero" from "the metric does not exist", so a
# missing collector looks exactly like an idle farm and the pool silently
# never scales up.
#
# WHAT THIS DOES NOT TOUCH: the CAS and scheduler pools. Both are pinned to a
# single instance for correctness reasons documented in config/cas.json5 and
# config/scheduler.json5, and autoscaling either one would corrupt the
# deployment rather than merely cost money.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"

# The pool CREMA owns. Deliberately the C++ worker pool and not the generic
# x86 one: execution.active.count carries no platform attribute, so the metric
# cannot say WHICH pool a queued action needs. Pointing one scaler at the pool
# that does the real work is honest; pointing two scalers at one aggregate
# metric would have them fight. See AUTOSCALING.md, "Known limitations".
WORKER_POOL="${CC_WORKER_POOL:-nativelink-worker-lre-cc}"

MAX_WORKERS="${MAX_WORKERS:-4}"
# Must match the worker pool's --cpu, which is what config/worker.json5
# advertises to the scheduler as cpu_count.
ACTIONS_PER_WORKER="${ACTIONS_PER_WORKER:-2}"

CREMA_SERVICE="${CREMA_SERVICE:-nativelink-crema}"
CREMA_JOB="${CREMA_JOB:-nativelink-crema-tick}"
CREMA_SA="nativelink-crema@${PROJECT}.iam.gserviceaccount.com"
CREMA_PARAM="${CREMA_PARAM:-nativelink-crema-config}"
TICK_SCHEDULE="${TICK_SCHEDULE:-* * * * *}"   # every minute; Scheduler's floor

# Published by Google, versioned separately from Cloud Run itself.
CREMA_IMAGE="${CREMA_IMAGE:-us-central1-docker.pkg.dev/cloud-run-oss-images/crema-v1/autoscaler:1.0}"
CREMA_BASE_IMAGE="${CREMA_BASE_IMAGE:-us-central1-docker.pkg.dev/serverless-runtimes/google-24/runtimes/java25}"

action="${1:-deploy}"

if [[ "${action}" == "delete" ]]; then
  echo "==> Removing the autoscaler"
  # Job first: otherwise a tick can fire against a half-deleted service.
  gcloud scheduler jobs delete "${CREMA_JOB}" --location="${REGION}" \
    --project="${PROJECT}" --quiet 2>/dev/null || echo "    (no tick job)"
  gcloud run services delete "${CREMA_SERVICE}" --region="${REGION}" \
    --project="${PROJECT}" --quiet 2>/dev/null || echo "    (no service)"
  echo
  echo "The worker pool keeps whatever instance count CREMA last set - it is"
  echo "NOT reset, and nothing is autoscaling it any more. ./scale.sh down"
  echo "deletes it outright; ./scale.sh up rebuilds it at its default size."
  exit 0
fi

if [[ "${action}" != "deploy" ]]; then
  echo "usage: $0 {deploy|delete}" >&2
  exit 1
fi

echo "==> project=${PROJECT} region=${REGION} pool=${WORKER_POOL}"

echo "==> [1/5] Enabling APIs"
gcloud services enable run.googleapis.com monitoring.googleapis.com \
  parametermanager.googleapis.com cloudscheduler.googleapis.com \
  --project="${PROJECT}"

echo "==> [2/5] Service account and IAM"
gcloud iam service-accounts create nativelink-crema \
  --display-name="NativeLink CREMA autoscaler" \
  --project="${PROJECT}" 2>/dev/null || echo "    sa exists"

# Project-scoped: reading the config and reading/writing metrics.
for role in \
  roles/parametermanager.parameterViewer \
  roles/monitoring.viewer \
  roles/monitoring.metricWriter \
  roles/iam.serviceAccountUser \
  roles/run.viewer
do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${CREMA_SA}" --role="${role}" \
    --condition=None >/dev/null
done

# Scoped to the ONE pool it may resize, rather than project-wide run.developer.
# This is the binding that actually lets it scale, and keeping it pool-scoped
# means a misconfigured scaleTargetRef fails loudly instead of quietly
# resizing the scheduler.
#
# IT IS NOT SUFFICIENT ON ITS OWN. After updating the pool, CREMA polls the
# resulting long-running operation, which lives at
#   projects/PROJECT/locations/REGION/operations/OPERATION_ID
# - NOT under the worker pool - so a pool-scoped binding cannot cover it.
# Without a project-level grant the resize APPLIES and CREMA then logs
#   PERMISSION_DENIED: run.operations.get ... [SCALER] Failed to scale
# i.e. it succeeds and reports failure. That is why roles/run.viewer is in the
# project-level loop above: read-only, and enough to poll the operation, while
# the power to actually resize stays scoped to this one pool. Google's
# documented setup omits this; observed live 2026-08-28.
gcloud run worker-pools add-iam-policy-binding "${WORKER_POOL}" \
  --region="${REGION}" --project="${PROJECT}" \
  --member="serviceAccount:${CREMA_SA}" --role=roles/run.developer >/dev/null

echo "==> [3/5] Rendering config into Parameter Manager"
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
sed -e "s|__PROJECT__|${PROJECT}|g" \
    -e "s|__REGION__|${REGION}|g" \
    -e "s|__WORKER_POOL__|${WORKER_POOL}|g" \
    -e "s|__MAX_WORKERS__|${MAX_WORKERS}|g" \
    -e "s|__ACTIONS_PER_WORKER__|${ACTIONS_PER_WORKER}|g" \
    crema/config.yaml.tmpl > "${rendered}"

gcloud parametermanager parameters create "${CREMA_PARAM}" \
  --location=global --parameter-format=YAML \
  --project="${PROJECT}" 2>/dev/null || echo "    parameter exists"

# Parameter versions are immutable, so each deploy creates a new one and the
# service is repointed at it. That also gives a trivial rollback: redeploy the
# service with an older version id in CREMA_CONFIG.
PARAM_VERSION="v$(date +%Y%m%d%H%M%S)"
gcloud parametermanager parameters versions create "${PARAM_VERSION}" \
  --location=global --parameter="${CREMA_PARAM}" \
  --payload-data-from-file="${rendered}" \
  --project="${PROJECT}" >/dev/null
echo "    config version ${PARAM_VERSION}"

echo "==> [4/5] Deploying the CREMA service"
# NOT --no-cpu-throttling, and no pollingInterval in the config: this service
# wakes on a Cloud Scheduler POST and scales back to zero in between. Google's
# documented setup runs it hot around the clock, which at this deployment's
# size can cost more than the worker it parks. See AUTOSCALING.md.
#
# No VPC connector either. CREMA never talks to the scheduler - it reads the
# queue depth from Cloud Monitoring and writes to the Cloud Run API, both
# public endpoints. Keeping it off the VPC is one less thing in the blast
# radius of the worker-API firewall rules.
#
# --base-image is carried over verbatim from Google's documented command (it
# opts the service into automatic base image updates). If a future gcloud
# rejects it alongside --image, drop it - it is not load-bearing.
# deploy_service creates or updates the CREMA Cloud Run service.
deploy_service() {
  gcloud run deploy "${CREMA_SERVICE}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --image="${CREMA_IMAGE}" \
    --base-image="${CREMA_BASE_IMAGE}" \
    --service-account="${CREMA_SA}" \
    --no-allow-unauthenticated \
    --min-instances=0 \
    --labels=created-by=crema \
    --set-env-vars="CREMA_CONFIG=projects/${PROJECT}/locations/global/parameters/${CREMA_PARAM}/versions/${PARAM_VERSION},OUTPUT_SCALER_METRICS=True"
}

# RETRY ONCE ON A COLD IAM BINDING.
#
# Step 2 grants roles/parametermanager.parameterViewer seconds before the
# container starts and reads its config from Parameter Manager. IAM bindings
# are not immediately consistent, so on a first-ever run the container can
# come up before the grant is visible and die with:
#   [METRIC-PROVIDER] Failed to load valid crema config: ... PermissionDenied
#   ... parametermanager.parameterVersions.get
# which Cloud Run then reports only as "container failed to start and listen
# on PORT" - the useful error is in the revision logs, not the deploy output.
# Observed on the first deploy into leffler-nativelink, 2026-08-28.
if ! deploy_service; then
  echo
  echo "    Deploy failed. If the revision logs show a Parameter Manager"
  echo "    PermissionDenied, this is just a cold IAM binding. Waiting 60s"
  echo "    and retrying once."
  sleep 60
  deploy_service
fi

CREMA_URL="$(gcloud run services describe "${CREMA_SERVICE}" \
  --region="${REGION}" --project="${PROJECT}" --format='value(status.url)')"

echo "==> [5/5] Cloud Scheduler tick"
gcloud run services add-iam-policy-binding "${CREMA_SERVICE}" \
  --region="${REGION}" --project="${PROJECT}" \
  --member="serviceAccount:${CREMA_SA}" --role=roles/run.invoker >/dev/null

# create-or-update: `jobs create` fails if the job exists and `jobs update`
# fails if it does not, and neither is safely idempotent on its own.
if gcloud scheduler jobs describe "${CREMA_JOB}" --location="${REGION}" \
     --project="${PROJECT}" >/dev/null 2>&1; then
  verb=update
else
  verb=create
fi
gcloud scheduler jobs "${verb}" http "${CREMA_JOB}" \
  --location="${REGION}" --project="${PROJECT}" \
  --schedule="${TICK_SCHEDULE}" \
  --uri="${CREMA_URL}/" \
  --http-method=POST \
  --oidc-service-account-email="${CREMA_SA}" \
  --oidc-token-audience="${CREMA_URL}" \
  --attempt-deadline=60s \
  --description="Wakes CREMA to re-evaluate the NativeLink action queue" >/dev/null

cat <<NEXT

==> Autoscaler deployed.

  service     : ${CREMA_URL}
  tick        : ${CREMA_JOB} (${TICK_SCHEDULE})
  scales      : ${WORKER_POOL}, 0..${MAX_WORKERS} instances
  threshold   : ${ACTIONS_PER_WORKER} concurrent actions per instance

CREMA NOW OWNS ${WORKER_POOL}. Do not set its instance count by hand while the
tick job is enabled - CREMA will undo it within a minute, and Google's docs
warn that two things scaling one pool race each other. ./scale.sh pauses the
tick job for you - it has to, since its teardown deletes the pool entirely -
but a bare 'gcloud run worker-pools update --instances' does not.

VERIFY BEFORE TRUSTING IT:
  ./verify-autoscaling.sh watch     # metric and instance count, live
  ./status.sh                       # includes recent CREMA scale decisions

Expect roughly 3-5 minutes from the first queued action to a running worker
when starting from zero: Cloud Monitoring ingests custom metrics with a 2+
minute delay, then the tick fires, then the instance starts. Bazel waits
rather than failing. AUTOSCALING.md explains how to trade that away.
NEXT
