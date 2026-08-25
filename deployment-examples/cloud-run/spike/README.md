# Cloud Run worker pool spike

Decides the shape of the NativeLink-on-Cloud-Run deployment before any real
work is built on top of it.

## Why

Running the NativeLink scheduler + CAS as a Cloud Run **worker pool** (rather
than a service) looks attractive because worker pools are the only Cloud Run
resource that supports Direct VPC *ingress*, giving each instance a private IP
with L4 reachability and no HTTP frontend. If that holds, it removes the worst
constraint in the design. But three things are unverified.

## What it tests

| # | Question | Signal |
|---|----------|--------|
| 1 | Is a worker pool instance reachable inbound over Direct VPC? | client connects at all |
| 2 | Does a long-lived stream survive past 60 minutes? | `H2C VERDICT: PASS` |
| 3 | Is any port beyond the declared `PORT` reachable? | `TCP VERDICT: PASS` |

Question 2 matters most. The 60-minute cap is enforced by the HTTP frontend in
front of Cloud Run *services*. Direct VPC ingress is raw L4, so there may be no
request to time out — but the docs do not say so either way.

Question 3 is upside: if a second port is reachable, the scheduler's client
frontend and `worker_api` backend can stay on separate ports, preserving the
security boundary that upstream deliberately built and that a single-port
deployment forces you to merge.

## How it works

`cmd/server` runs in the worker pool and listens on two ports — `PORT` speaks
h2c (the same transport gRPC uses) and `PORT2` speaks raw TCP. Both emit a
timestamped heartbeat every 30s. It logs its own private IP as `SPIKE_IP` at
startup, because Cloud Run exposes no API for listing worker pool instance IPs.

`cmd/client` runs on a GCE VM inside the same subnet, holds both connections
open, and reports how long each survived.

## Running

    ./deploy.sh          # creates VPC, subnet, AR repo, worker pool, client VM
    # follow the printed next steps to run the probe for 75 minutes
    ./teardown.sh        # removes everything - this leaves billable resources up

Override defaults with env vars: `PROJECT`, `REGION`, `VPC`, `SUBNET`, `POOL`.

## Interpreting results

- **H2C PASS** — no 60m cap on Direct VPC ingress. Build the core on a worker pool.
- **H2C FAIL at ~60m** — the cap applies. Fall back to a Cloud Run service and
  plan around hourly worker reconnects.
- **TCP UNREACHABLE** — only the declared port is exposed. The merged-port
  config (client services alongside `worker_api`) is mandatory.
- **TCP PASS** — un-merge the ports and recover the security boundary.

Also restart the pool and re-read `SPIKE_IP`: if the private IP changes across
revisions, service discovery needs solving before this design is viable.
