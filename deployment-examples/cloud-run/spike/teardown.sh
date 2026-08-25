#!/usr/bin/env bash
# Removes everything deploy.sh created. Safe to re-run.
set -uo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VPC="${VPC:-nl-spike-vpc}"
SUBNET="${SUBNET:-nl-spike-subnet}"
REPO="${REPO:-nl-spike}"
POOL="${POOL:-nl-spike-pool}"
VM="${VM:-nl-spike-client}"

echo "==> Tearing down spike resources in ${PROJECT}"

gcloud run worker-pools delete "${POOL}" --region="${REGION}" --quiet --project="${PROJECT}"
gcloud compute instances delete "${VM}" --zone="${ZONE}" --quiet --project="${PROJECT}"
gcloud compute firewall-rules delete "${VPC}-allow-internal" --quiet --project="${PROJECT}"
gcloud compute firewall-rules delete "${VPC}-allow-iap-ssh" --quiet --project="${PROJECT}"
gcloud compute networks subnets delete "${SUBNET}" --region="${REGION}" --quiet --project="${PROJECT}"
gcloud compute networks delete "${VPC}" --quiet --project="${PROJECT}"
gcloud artifacts repositories delete "${REPO}" --location="${REGION}" --quiet --project="${PROJECT}"

echo "==> Teardown complete. Verify in the console that nothing bills on."
