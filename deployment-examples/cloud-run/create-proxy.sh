#!/usr/bin/env bash
# Exposes the NativeLink CAS and scheduler to a small set of source IPs.
#
# Cloud Run worker pools have no public endpoint and cannot be load-balancer
# backends, so a small VM in the VPC forwards TCP to them. VPC firewall rules
# restrict who may connect.
#
# PROTOTYPE ONLY - TRAFFIC IS PLAINTEXT:
# gRPC is forwarded without TLS, so build inputs, outputs and cache traffic
# cross the public internet in the clear. IP allowlisting controls who may
# CONNECT; it does not stop an on-path observer reading the traffic, nor an
# on-path attacker tampering with cached artifacts in flight - which is a
# supply-chain risk, since a poisoned cache entry becomes your build output.
# Acceptable for throwaway test code. Do NOT point real source at this.
# To fix: terminate TLS here and have Bazel trust the cert via
# --tls_certificate, or move the client-facing side behind a load balancer
# with managed certificates.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VPC="${VPC:-nl-vpc}"
CORE_SUBNET="${CORE_SUBNET:-nl-core-subnet}"
PROXY_VM="${PROXY_VM:-nl-proxy}"

# WHO MAY CONNECT. Comma-separated CIDRs. Keep this list as small as possible;
# it is the only thing standing between the internet and an unauthenticated
# build cache that accepts writes.
#
# The default is a placeholder and will not match you - set ALLOWED_IPS to
# your own egress address (curl ifconfig.me). Failing closed is deliberate:
# the wrong default here opens a writable cache to strangers, so it errs
# towards locking you out rather than letting anyone else in.
ALLOWED_IPS="${ALLOWED_IPS:-1.2.3.4/32}"

# Public ports on the proxy, forwarded to the internal pools.
CAS_PUBLIC_PORT="${CAS_PUBLIC_PORT:-8980}"
SCHED_PUBLIC_PORT="${SCHED_PUBLIC_PORT:-8981}"
CAS_ADDR="${CAS_ADDR:-nativelink-cas.nl.internal}"
SCHED_ADDR="${SCHED_ADDR:-nativelink-scheduler.nl.internal}"
INTERNAL_PORT="${INTERNAL_PORT:-8080}"

echo "==> Reserving a static external IP (so the endpoint survives restarts)"
gcloud compute addresses create "${PROXY_VM}-ip" --region="${REGION}" \
  --project="${PROJECT}" 2>/dev/null || echo "    address exists"
PROXY_IP=$(gcloud compute addresses describe "${PROXY_VM}-ip" --region="${REGION}" \
  --project="${PROJECT}" --format="value(address)")
echo "    ${PROXY_IP}"

echo "==> Firewall: allow ONLY ${ALLOWED_IPS}"
gcloud compute firewall-rules create "${VPC}-proxy-in" \
  --network="${VPC}" \
  --allow="tcp:${CAS_PUBLIC_PORT},tcp:${SCHED_PUBLIC_PORT}" \
  --source-ranges="${ALLOWED_IPS}" \
  --target-tags=nl-proxy \
  --project="${PROJECT}" 2>/dev/null \
  || gcloud compute firewall-rules update "${VPC}-proxy-in" \
       --source-ranges="${ALLOWED_IPS}" --project="${PROJECT}"

# The nginx config is a real file rather than a heredoc inside a heredoc.
# Embedding it caused two bugs: shell escaping turned $var into \$var, which
# nginx rejects as an invalid variable name, and an empty 60-stream.conf
# clobbered the modules-enabled entry that libnginx-mod-stream installs, so
# the stream module never loaded and nginx served nothing on either port.
STARTUP=$(cat <<'STARTUP_EOF'
#!/bin/bash
set -e
apt-get update -qq
apt-get install -y -qq nginx libnginx-mod-stream
# Config is fetched from instance metadata, set below.
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/nginx-conf" \
  > /etc/nginx/nginx.conf
nginx -t
systemctl enable nginx
systemctl restart nginx
STARTUP_EOF
)

echo "==> Creating proxy VM"
gcloud compute instances create "${PROXY_VM}" \
  --zone="${ZONE}" --machine-type=e2-small \
  --subnet="${CORE_SUBNET}" --address="${PROXY_IP}" \
  --tags=nl-proxy \
  --image-family=debian-12 --image-project=debian-cloud \
  --metadata=startup-script="${STARTUP}" \
  --metadata-from-file=nginx-conf=proxy/nginx.conf \
  --project="${PROJECT}" 2>/dev/null || echo "    vm exists"

cat <<NEXT

==> Proxy at ${PROXY_IP}

Allow ~90s for nginx to install, then from an allowed source:

  bazel build --config=rbe \\
    --remote_cache=grpc://${PROXY_IP}:${CAS_PUBLIC_PORT} \\
    --remote_executor=grpc://${PROXY_IP}:${SCHED_PUBLIC_PORT} \\
    //:hello

Reachable only from: ${ALLOWED_IPS}
Traffic is PLAINTEXT - see the header of this script.
NEXT
