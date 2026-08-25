# Connecting Bazel clients over VPN / Interconnect

The deployment is deliberately **VPC-internal**. There is no public endpoint,
no load balancer, and no IAM-authenticated URL. Clients reach it by being on a
network that routes into `nl-vpc`.

Three things must all be true. Missing any one of them produces a different,
confusing failure.

Commands below assume `PROJECT` is set:

    export PROJECT=your-gcp-project

## 1. Routing — the tunnel itself

HA VPN (or Interconnect) between your on-prem network and `nl-vpc`, with
routes advertised for the subnets clients need to reach:

| Subnet | Range | Why clients need it |
|---|---|---|
| `nl-core-subnet` | `10.20.0.0/24` | The core serves CAS/AC/execution here |
| `nl-worker-subnet` | `10.21.0.0/24` | Not needed by clients — do not advertise |

Advertise only the core subnet. Clients have no reason to reach workers, and
workers are the half of the system that can forge action results.

**Failure mode if missing:** connection timeouts, `tcp connect error`.

## 2. DNS — resolving the private zone

`nativelink-core.nl.internal` lives in a **private** Cloud DNS zone, invisible
to on-prem resolvers by default. `deploy-nativelink.sh` creates an inbound
server policy which allocates forwarder IPs inside the VPC.

Find them:

    gcloud compute addresses list \
      --filter="purpose=DNS_RESOLVER" \
      --format="table(address,region,subnetwork.basename())" \
      --project="${PROJECT}"

Then configure your on-prem DNS to conditionally forward `nl.internal` to
those addresses.

**Failure mode if missing:** `failed to lookup address information: Name does
not resolve` — exactly what the workers hit before the DNS API was enabled.

Alternative if you would rather not touch on-prem DNS: point Bazel at the
core's IP directly. This works but is fragile — the IP changes whenever the
core is redeployed or its instance is replaced, which is precisely the problem
the DNS sidecar exists to solve. Not recommended.

## 3. Firewall — allowing the client range

`nl-vpc-client-api` currently allows only `10.20.0.0/16` on port 8080. Traffic
arriving over the VPN comes from your corporate range, so it must be added:

    gcloud compute firewall-rules update nl-vpc-client-api \
      --source-ranges=10.20.0.0/16,YOUR_ONPREM_CIDR \
      --project="${PROJECT}"

Or set `CLIENT_RANGE` before running `deploy-nativelink.sh`.

Do **not** add your corporate range to `nl-vpc-worker-api` (port 50061). That
rule is the security boundary: anyone who can reach the worker API can
register as a worker, claim actions, and return forged results, poisoning the
action cache for everyone. It must stay restricted to the worker subnet.

**Failure mode if missing:** connection timeouts that look identical to a
routing problem. Check the firewall before debugging the tunnel.

## Client configuration

Once all three are in place, in the client's `.bazelrc`:

    build --remote_cache=grpc://nativelink-core.nl.internal:8080
    build --remote_instance_name=main
    build --remote_timeout=120

For remote execution as well, add:

    build --remote_executor=grpc://nativelink-core.nl.internal:8080

Note `grpc://` not `grpcs://` — this is plaintext gRPC on a private network.
Traffic is protected by the VPN tunnel, not by TLS at the application layer.
If you need end-to-end TLS as well, NativeLink's `EndpointConfig` accepts a
`tls_config`, but that means managing certificates for an internal name.

## Verifying

    # From a machine on the VPN
    getent hosts nativelink-core.nl.internal    # DNS working?
    nc -zv nativelink-core.nl.internal 8080     # routing + firewall working?
    bazel build --remote_cache=... //your:target

A build that succeeds but reports zero remote cache hits on a second run means
the cache accepts writes but cannot serve reads — worse than an outright
failure, because nothing looks broken.
