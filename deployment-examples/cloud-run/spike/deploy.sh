#!/usr/bin/env bash
# Deploys the Cloud Run worker pool spike.
#
# Answers three questions that decide the shape of the NativeLink deployment:
#   1. Is a worker pool instance reachable inbound over Direct VPC?
#   2. Does a long-lived stream survive past the 60m Cloud Run services cap?
#   3. Is any port other than the declared PORT reachable?
#
# Run ./teardown.sh when finished - this leaves billable resources running.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VPC="${VPC:-nl-spike-vpc}"
SUBNET="${SUBNET:-nl-spike-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/24}"
REPO="${REPO:-nl-spike}"
POOL="${POOL:-nl-spike-pool}"
VM="${VM:-nl-spike-client}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/spike:latest"

echo "==> project=${PROJECT} region=${REGION}"

echo "==> [1/6] Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT}"

echo "==> [2/6] Creating VPC and subnet"
gcloud compute networks create "${VPC}" \
  --subnet-mode=custom --project="${PROJECT}" 2>/dev/null || echo "    vpc exists"
gcloud compute networks subnets create "${SUBNET}" \
  --network="${VPC}" --range="${SUBNET_RANGE}" --region="${REGION}" \
  --project="${PROJECT}" 2>/dev/null || echo "    subnet exists"

# Allow the client VM to reach the worker pool instances on both probe ports,
# and allow IAP-based SSH so the VM needs no public IP.
gcloud compute firewall-rules create "${VPC}-allow-internal" \
  --network="${VPC}" --allow=tcp:8080,tcp:8081 --source-ranges="${SUBNET_RANGE}" \
  --project="${PROJECT}" 2>/dev/null || echo "    internal rule exists"
gcloud compute firewall-rules create "${VPC}-allow-iap-ssh" \
  --network="${VPC}" --allow=tcp:22 --source-ranges=35.235.240.0/20 \
  --project="${PROJECT}" 2>/dev/null || echo "    iap rule exists"

echo "==> [3/6] Building and pushing image (linux/amd64 - Cloud Run has no arm64)"
gcloud artifacts repositories create "${REPO}" \
  --repository-format=docker --location="${REGION}" \
  --project="${PROJECT}" 2>/dev/null || echo "    repo exists"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker buildx build --platform linux/amd64 -t "${IMAGE}" --push .

# PORT is a reserved env name on Cloud Run - the platform injects it and
# rejects the deploy if you set it yourself. Only PORT2 is ours to set.
echo "==> [4/6] Deploying worker pool (instances=1, Direct VPC)"
gcloud run worker-pools deploy "${POOL}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --instances=1 \
  --network="${VPC}" \
  --subnet="${SUBNET}" \
  --set-env-vars=PORT2=8081 \
  --project="${PROJECT}"

echo "==> [5/6] Creating client VM in the same subnet"
gcloud compute instances create "${VM}" \
  --zone="${ZONE}" --machine-type=e2-micro \
  --subnet="${SUBNET}" --no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --scopes=cloud-platform \
  --project="${PROJECT}" 2>/dev/null || echo "    vm exists"

echo "==> [6/6] Discovering worker pool instance IP from Cloud Logging"
echo "    (Cloud Run exposes no API for worker pool instance IPs, so the"
echo "     server self-reports it. Allow ~60s for logs to surface.)"
gcloud logging read \
  "resource.type=cloud_run_worker_pool AND textPayload:SPIKE_IP" \
  --limit=5 --format="value(textPayload)" --freshness=10m \
  --project="${PROJECT}" || true

cat <<'NEXT'

==> Next steps

1. Note the SPIKE_IP address printed above (e.g. 10.10.0.3).
   If nothing printed, wait a minute and re-run just the logging read.

2. SSH to the client VM and run the probe for 75 minutes:

   gcloud compute ssh nl-spike-client --zone ZONE --tunnel-through-iap
   # on the VM:
   sudo apt-get update && sudo apt-get install -y golang-go git
   # copy cmd/client/main.go and go.mod across, then:
   go run ./cmd/client -host <SPIKE_IP> -duration 75m

3. Read the verdicts. What they mean:
   H2C PASS            -> no 60m cap on Direct VPC ingress. Major win.
   H2C FAIL at ~60m    -> the cap applies here too; fall back to a service.
   TCP UNREACHABLE     -> only the declared PORT is exposed; merged-port
                          config is mandatory.
   TCP PASS            -> multiple ports work; you can UN-merge the scheduler
                          frontend/backend split and recover the boundary.

4. Restart the pool and re-check SPIKE_IP to see whether the private IP is
   stable across revisions. This decides the service-discovery design.

5. Run ./teardown.sh
NEXT
