# Autoscaling the worker fleet with CREMA

Cloud Run worker pools have **no built-in autoscaling** — they run whatever
`--instances` you set, and bill for it whether or not anything is queued. The
blunt instrument for that is [`scale.sh`](scale.sh), which deletes the whole
deployment between sessions. CREMA (Cloud Run External Metrics Autoscaling) is
Google's answer: a KEDA-backed service you deploy yourself that reads an
external metric and resizes the pool for you, so the fleet tracks demand
within a session instead of sitting at a fixed size.

This wires it to the only signal that actually describes build demand — the
NativeLink scheduler's action queue.

    scheduler pool (1 instance, pinned)
      ├─ nativelink ──── OTLP/gRPC localhost:4317 ──┐
      ├─ dns-register                               │
      └─ otel-collector  ◄──────────────────────────┘
            └─ googlecloud exporter
                  └─ workload.googleapis.com/execution.active.count

    nativelink-crema (Cloud Run service, scales to zero)
      ◄─ Cloud Scheduler POST, every minute
      └─ KEDA prometheus scaler ─ PromQL ─► Cloud Monitoring
            └─ run.workerPools.update ─► nativelink-worker-lre-cc

## Deploy it

    ./deploy-nativelink.sh        # now also builds and attaches the collector
    ./verify-autoscaling.sh series   # STOP HERE if this finds nothing
    ./deploy-crema.sh

`verify-autoscaling.sh series` is not optional politeness. CREMA cannot
distinguish *"the queue is empty"* from *"the metric was never written"* —
both are zero, and neither logs an error. If the metric is missing, the pool
silently never scales up and every other check in `status.sh` still passes.

To remove it again:

    ./deploy-crema.sh delete

## Why this design

**Why a collector sidecar.** NativeLink emits OTLP and nothing else; it has no
Prometheus scrape endpoint at all (see
[`../metrics/README.md`](../metrics/README.md)). Something has to bridge OTLP
to Cloud Monitoring.

**Why no NativeLink change was needed.** `init_tracing()` builds the OTLP
metric exporter unconditionally over gRPC and defaults to `localhost:4317`
(`nativelink-util/src/telemetry.rs`). The scheduler has been exporting these
metrics all along, into a socket nothing was listening on. Adding a container
that listens is the entire change.

**Why the `prometheus` scaler and not `gcp-stackdriver`.** KEDA deprecated the
Stackdriver scaler in September 2025. The Prometheus scaler pointed at Cloud
Monitoring's PromQL endpoint is what Google's own worker-pool tutorial uses,
and it needs no stored credential — the service account's own token is enough.

**Why not Pub/Sub or Kafka**, the scalers CREMA is usually demonstrated with:
there is no queue in this deployment to observe. The queue is inside the
scheduler process, and `execution.active.count` is how it describes itself.

## The metric

`execution.active.count` is an i64 up-down counter carrying one attribute,
`execution.stage` ∈ `unknown | cache_check | queued | executing | completed`
(`nativelink-util/src/metrics.rs`). It is incremented when an action enters the
queue and moved on every stage transition
(`nativelink-scheduler/src/memory_awaited_action_db.rs`).

CREMA scales on **queued *and* executing**:

    sum(
      workload_googleapis_com:execution_active_count{
        monitored_resource="generic_task",
        execution_stage=~"queued|executing"
      }
    )

`monitored_resource` is required, not decorative: Cloud Monitoring's PromQL
endpoint rejects any `workload.googleapis.com` selector without it, because
that domain can attach to around twenty resource types and it will not guess.
The `googlecloud` exporter writes this metric as `generic_task`, with `job`
and `task_id` set from the `resource/stable_identity` processor.

Counting only queued actions is the documented CREMA failure mode
([issue #6](https://github.com/GoogleCloudPlatform/cloud-run-external-metrics-autoscaling/issues/6)):
the instant workers claim the work the queue reads zero, CREMA recommends zero
instances, and Cloud Run sends `SIGTERM` with roughly ten seconds of grace.
NativeLink workers do handle `SIGTERM` (`nativelink-worker/src/local_worker.rs`)
and the scheduler re-queues orphaned actions after `worker_timeout_s`, so a
build does not *fail* — but every killed action is re-run from scratch.
Including executing actions keeps a worker alive while it is working;
`scaleDown.stabilizationWindowSeconds: 300` is the second line of defence.

KEDA computes `ceil(metric / threshold)`, so `threshold` is "actions one worker
runs at once" and must track the pool's `--cpu`, which is what
[`config/worker.json5`](config/worker.json5) advertises as `cpu_count`.

The metric name is Cloud Monitoring's PromQL mangling of
`workload.googleapis.com/execution.active.count`: the first `/` becomes `:`,
every other special character becomes `_`.

## Cost

Autoscaling is not free here, and at prototype scale the overhead is a real
fraction of what it saves. Worth knowing before you turn it on.

| | Cost | Note |
|---|---|---|
| `otel-collector` sidecar | +1 vCPU / 512Mi, always on | The scheduler pool is pinned to 1 instance, so this runs 24/7 |
| `nativelink-crema` service | per-request only | See below |
| Custom metric series | ~5 series | Kept to 5 by the filter processor |
| Saved | worker pool idle time | The thing being bought |

**The CREMA service is deployed against Google's documented pattern, on
purpose.** Their setup sets `pollingInterval` and `--no-cpu-throttling`, which
makes CREMA re-invoke itself in a loop — a Java Cloud Run service billed around
the clock. At this deployment's size that plausibly costs more than the single
worker instance it exists to park. [`crema/config.yaml.tmpl`](crema/config.yaml.tmpl)
omits `pollingInterval` and [`deploy-crema.sh`](deploy-crema.sh) drives it from
Cloud Scheduler instead, so it scales to zero between ticks. The trade is one
minute of granularity, which is far below the metric's own latency anyway.

**The five-series cap is a billing control, not tidiness.** NativeLink attaches
`execution.action_digest` — one distinct value per action executed — to
`execution.completed.count`. Exported unfiltered that is an unbounded number of
Cloud Monitoring custom metric series, billed forever. The `filter` processor
in [`otel/collector.yaml`](otel/collector.yaml) drops everything except the one
metric autoscaling needs. **Do not widen it casually.**

## Measured behaviour

Verified end to end against `leffler-nativelink` on 2026-08-28, with a
`bazel clean` + `--noremote_accept_cached` build of the C++ example (669
actions, 565 executed remotely) starting from a pool parked at zero:

| Time (UTC) | Instances | What happened |
|---|---|---|
| 03:22 | 0 | idle, recommendation 0 |
| 03:23:00 | 0 | queue reaches CREMA, recommendation **25** |
| 03:23:47 | 1 | first worker |
| 03:25:01 | 1 | `Recommendation was clamped to range [0, 4]` |
| 03:25:32 | 4 | full fleet, 48 actions executing |
| 03:28:00 | 4 | build drained, recommendation back to 0 |
| 03:30:47 | 3 | shrink begins |
| 03:36:53 | 0 | fully parked |

**Cold start to first worker: ~3.5 minutes**; to the full fleet, ~5.5. That is
the figure to plan around, and it matches the estimate this document was
written with.

**Scale-down took ~11 minutes** from the queue draining. Note the
stabilization window runs from when the metric starts *declining*, not from
when the recommendation reaches zero - the shrink began at 03:30:47, roughly
five minutes after the decline started at ~03:25, not five minutes after the
recommendation hit 0 at 03:28. Instances then stepped down about one per 100s,
consistent with the 1-per-60s policy plus one-minute tick granularity.

The hold from 03:26 to 03:30 is the point of counting executing actions: the
recommendation was already 1 at 03:27 and 0 at 03:28, while work was still
running. Scaling on queue depth alone would have killed workers there.

## Known limitations

**Scale-up takes ~3.5 minutes from cold** (measured; see above). Cloud
Monitoring ingests custom metrics with a 2+ minute delay (CREMA's own README
calls this out), then the tick fires, then the instance starts and the worker
registers. Bazel waits rather than failing, so a build from a parked farm is
slow, not broken.
`./scale.sh up` rebuilds the pool at its default size, which prewarms it. To trade cost for
responsiveness permanently, either set `minReplicaCount: 1`, or add a second
`cron` trigger to the same `scaledObject` — KEDA takes the maximum across
triggers, giving min-1 during working hours and true zero overnight.

**The metric cannot tell the two worker pools apart.** `execution.active.count`
carries only `execution.stage`; there is no platform property on it, so "five
actions queued" does not say whether they need `nativelink-worker-x86` or
`nativelink-worker-lre-cc`. CREMA is therefore pointed at the C++ pool only —
the one that does the real work — and the x86 pool stays manual. Pointing two
scalers at one aggregate metric would have them fight, which Google's docs
warn against explicitly. Fixing this properly means adding a platform
attribute to the metric upstream in `memory_awaited_action_db.rs`, which is a
NativeLink change rather than a deployment one.

**One scaler per pool.** CREMA restores the instance count within a minute of
anything else changing it. `scale.sh down` pauses the tick job before it starts
deleting — otherwise CREMA would spend every minute logging a not-found against
a scale target that no longer exists — and `scale.sh up` resumes it once the
pool is back. A bare `gcloud run worker-pools update --instances` does neither,
and will be silently undone. `./scale.sh autoscale off` is the manual switch.

**The scheduler stays pinned at one instance.** CREMA never touches the CAS or
scheduler pools. Both hold instance-local state — queue state and the
filesystem fast tier respectively — and autoscaling either would corrupt the
deployment rather than merely cost money. See
[`config/scheduler.json5`](config/scheduler.json5) and
[`config/cas.json5`](config/cas.json5).

**The collector is fail-fast, and it shares the scheduler's instance.** Tested
locally: with no usable credentials the `googlecloud` exporter fails to start
and the collector process exits 1 rather than degrading. A container that exits
takes its Cloud Run instance with it, so if `nativelink-core` ever loses
`roles/monitoring.metricWriter`, the symptom is not "metrics stopped" — it is
the **scheduler pool restart-looping**, which stops the entire farm.
`deploy-nativelink.sh` grants the binding in step 4, before the pools are
deployed in step 6, so the ordering is safe on a clean run. Keep it that way.

Startup also blocks in `resource_detection` until it has probed the metadata
server, up to its 10s timeout — receivers do not start before processors do.
On Cloud Run the metadata server answers immediately; off it, the collector
takes ~10s longer to accept OTLP.

## Troubleshooting

Run `./status.sh` first — section 6 covers all of this.

**`verify-autoscaling.sh series` finds nothing.** In order of likelihood: no
build has run yet (the scheduler only emits the metric once an action passes
through); the collector sidecar is not deployed; `nativelink-core` is missing
`roles/monitoring.metricWriter`, in which case the collector logs
`PermissionDenied` on every export:

    gcloud logging read \
      "resource.labels.worker_pool_name=nativelink-scheduler" \
      --freshness=15m --project="${PROJECT}" | grep -i otelcol

**Queued count only ever climbs.** The `+1 Queued` on insert is unconditional
while stage transitions do `-1 old / +1 new`, so an action that starts in
`cache_check` is arguably counted twice. If `./verify-autoscaling.sh metric`
shows a queued count that never returns to zero on an idle farm, the gauge is
leaking and CREMA will scale up forever. Narrow the query in
[`crema/config.yaml.tmpl`](crema/config.yaml.tmpl) to
`execution_stage="executing"` as a stopgap, and fix it upstream.

**`[SCALER] Failed to scale` with `PERMISSION_DENIED: run.operations.get`.**
The resize actually worked — check the instance count before believing the
error. CREMA updates the pool, then polls the long-running operation that the
update returns, and that operation is a *location*-scoped resource, so the
pool-scoped `roles/run.developer` binding does not cover it. `deploy-crema.sh`
grants project-level `roles/run.viewer` for exactly this. If you built the
service account by hand from Google's docs, you will hit this.

**CREMA logs a not-found on the scale target.** Google's docs disagree with
themselves on the case of `workerPools` in `scaleTargetRef` — the CREMA guide
writes `workerpools`, the Prometheus tutorial writes `workerPools`. Try the
other one.

**Nothing scales and CREMA logs nothing.** Check the tick job is not paused:

    gcloud scheduler jobs describe nativelink-crema-tick \
      --location="${REGION}" --project="${PROJECT}" --format="value(state)"

`./scale.sh down` pauses it by design, and leaves it paused until `up`.
