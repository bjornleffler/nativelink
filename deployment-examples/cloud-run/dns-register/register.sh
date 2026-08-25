#!/usr/bin/env sh
# Publishes this Cloud Run worker pool instance's private IP as an A record in
# a private Cloud DNS zone, giving the core a STABLE NAME across redeploys.
#
# WHY: Cloud Run exposes no API for listing worker pool instance IPs, and the
# IPs change on every redeploy and instance replacement. Without this, workers
# must be handed a raw IP at deploy time and break the moment the core moves.
# Follows Google's documented pattern:
#   https://docs.cloud.google.com/run/docs/tutorials/worker-pool-private-ip-dns
#
# Talks to the Cloud DNS REST API with curl rather than using gcloud: the
# cloud-sdk image is ~1GB, against a 30MB nativelink main container. This one
# is ~15MB. It also avoids a large push on every deploy.
set -eu

DNS_ZONE="${DNS_ZONE:?DNS_ZONE is required}"
DNS_NAME="${DNS_NAME:?DNS_NAME is required, e.g. nativelink-core.nl.internal.}"
TTL="${TTL:-60}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"

MD="http://metadata.google.internal/computeMetadata/v1"
API="https://dns.googleapis.com/dns/v1/projects"

# Fetch a value from the instance metadata server.
metadata() {
  curl -sf -H "Metadata-Flavor: Google" "${MD}/$1"
}

# Current OAuth token for the attached service account.
access_token() {
  metadata "instance/service-accounts/default/token" | jq -r .access_token
}

# The A record currently published for DNS_NAME, or empty.
current_record() {
  curl -sf -H "Authorization: Bearer $(access_token)" \
    "${API}/${PROJECT}/managedZones/${DNS_ZONE}/rrsets?name=${DNS_NAME}&type=A" \
    | jq -r '.rrsets[0].rrdatas[0] // empty'
}

# Atomically swap the A record to point at $1, deleting any stale value.
publish_record() {
  ip="$1"
  old="$(current_record || true)"

  if [ "${old}" = "${ip}" ]; then
    return 0
  fi

  if [ -n "${old}" ]; then
    echo "DNS: replacing ${DNS_NAME} ${old} -> ${ip}"
    deletions="[{\"name\":\"${DNS_NAME}\",\"type\":\"A\",\"ttl\":${TTL},\"rrdatas\":[\"${old}\"]}]"
  else
    echo "DNS: creating ${DNS_NAME} -> ${ip}"
    deletions="[]"
  fi

  body="{\"additions\":[{\"name\":\"${DNS_NAME}\",\"type\":\"A\",\"ttl\":${TTL},\"rrdatas\":[\"${ip}\"]}],\"deletions\":${deletions}}"

  if ! curl -sf -X POST \
      -H "Authorization: Bearer $(access_token)" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${API}/${PROJECT}/managedZones/${DNS_ZONE}/changes" > /dev/null; then
    echo "DNS: WARNING - failed to publish record, will retry" >&2
    return 1
  fi
}

# Stop re-asserting the moment Cloud Run signals shutdown.
#
# WHY: during a rolling deploy the outgoing instance overlaps the incoming one.
# Both sidecars re-assert their own IP every REFRESH_INTERVAL, so the A record
# flaps between the dying and the live instance and roughly half of worker
# connections land on a dead address. Observed in production: 10.20.0.16 and
# 10.20.0.17 fought over the record for ~60s across a redeploy. Exiting on
# SIGTERM makes the outgoing instance concede immediately.
running=1
trap 'echo "DNS: SIGTERM received, conceding the record"; running=0; exit 0' TERM INT

PROJECT="$(metadata 'project/project-id')"
IP="$(metadata 'instance/network-interfaces/0/ip')"
if [ -z "${IP}" ]; then
  echo "FATAL: metadata returned no private IP. Is Direct VPC attached?" >&2
  exit 1
fi
echo "DNS: project=${PROJECT} instance IP=${IP}"
publish_record "${IP}" || true

# Keep re-asserting: an instance can be replaced without the pool being
# redeployed, and a stale A record would silently break every worker.
while [ "${running}" -eq 1 ]; do
  # Sleep in short slices so SIGTERM is acted on promptly rather than up to a
  # full refresh interval later.
  slept=0
  while [ "${slept}" -lt "${REFRESH_INTERVAL}" ] && [ "${running}" -eq 1 ]; do
    sleep 5
    slept=$((slept + 5))
  done
  [ "${running}" -eq 1 ] || break
  IP="$(metadata 'instance/network-interfaces/0/ip' || true)"
  if [ -n "${IP}" ]; then
    publish_record "${IP}" || true
  else
    echo "DNS: metadata unavailable, retrying"
  fi
done
