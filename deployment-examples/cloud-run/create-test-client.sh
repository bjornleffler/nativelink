#!/usr/bin/env bash
# Creates an in-VPC VM that can run real Bazel builds against the deployment.
#
# WHY A VM AND NOT cas_speed_check: the cas_speed_check binary shipped in the
# nativelink image unconditionally applies TLS config and refuses a grpc://
# endpoint ("You have set TLS configuration ... but the scheme is not https or
# grpcs"). It targets NativeLink Cloud, not a plaintext internal deployment.
# A real Bazel build is the honest test anyway: it exercises the CAS, the GCS
# slow tier, and - for remote execution - the platform property matching that
# otherwise fails silently.
#
# The VM sits in the CORE subnet so the nl-vpc-client-api firewall rule
# (10.20.0.0/16 -> tcp:8080) permits it to reach the build API. It is
# deliberately NOT in the worker subnet, so it cannot reach the worker API -
# which is the security boundary the split ports exist to enforce.
set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
VPC="${VPC:-nl-vpc}"
CORE_SUBNET="${CORE_SUBNET:-nl-core-subnet}"
VM="${VM:-nl-test-client}"

echo "==> Allowing IAP SSH into ${VPC}"
gcloud compute firewall-rules create "${VPC}-allow-iap-ssh" \
  --network="${VPC}" --allow=tcp:22 --source-ranges=35.235.240.0/20 \
  --project="${PROJECT}" 2>/dev/null || echo "    iap rule exists"

# The VM has no external IP, so without Cloud NAT it has no internet egress
# and apt-get/curl hang indefinitely on a black hole. NAT is also generally
# useful for anything else that needs to run inside this VPC.
echo "==> Cloud NAT (the VM has no external IP and needs egress)"
gcloud compute routers create "${VPC}-router" \
  --network="${VPC}" --region="${REGION}" \
  --project="${PROJECT}" 2>/dev/null || echo "    router exists"
gcloud compute routers nats create "${VPC}-nat" \
  --router="${VPC}-router" --region="${REGION}" \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges \
  --project="${PROJECT}" 2>/dev/null || echo "    nat exists"

echo "==> Creating ${VM} in ${CORE_SUBNET}"
gcloud compute instances create "${VM}" \
  --zone="${ZONE}" --machine-type=e2-standard-2 \
  --subnet="${CORE_SUBNET}" --no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=50GB \
  --scopes=cloud-platform \
  --project="${PROJECT}" 2>/dev/null || echo "    vm exists"

echo "==> Installing Bazel and a trivial workspace"
gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap \
  --project="${PROJECT}" --command='
set -e
if ! command -v bazel >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl gcc g++ python3 >/dev/null
  sudo curl -sSLo /usr/local/bin/bazel \
    https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
  sudo chmod +x /usr/local/bin/bazel
fi

mkdir -p ~/cas-test && cd ~/cas-test
touch MODULE.bazel WORKSPACE

# A handful of genrules with distinct outputs, so the CAS sees real traffic
# rather than a single trivially cacheable action.
cat > BUILD.bazel <<"BUILD"
[
    genrule(
        name = "gen%d" % i,
        outs = ["out%d.txt" % i],
        cmd = "for j in $$(seq 1 2000); do echo \"cas-test-%d line $$j\"; done > $@" % i,
    )
    for i in range(1, 11)
]

genrule(
    name = "combined",
    srcs = [":gen%d" % i for i in range(1, 11)],
    outs = ["combined.txt"],
    cmd = "cat $(SRCS) > $@",
)
BUILD
echo "workspace ready at ~/cas-test"
'

cat <<NEXT

==> Test client ready.

Run the cache round-trip:

  ./test-remote-cache.sh

NEXT
