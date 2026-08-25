# NativeLink remote execution example

Smallest thing that proves remote execution end to end.

## Run it

From an allowlisted source IP:

    bazel build --config=proxy //:hello
    bazel-bin/hello

From inside the VPC:

    bazel build --config=internal //:hello

## What a passing result looks like

    INFO: N processes: X internal, Y remote.

`remote` is the number that matters. If you see `linux-sandbox` or `local`
instead, Bazel silently fell back to building locally and the run proves
nothing - the build still succeeds either way.

The first run is slow: the hermetic LLVM toolchain is compiled from source on
the worker, several hundred actions. Subsequent runs hit the cache.

Running the binary should report clang, not your local gcc:

    hello from NativeLink remote execution
    compiled by clang 22.1.8
    target: x86_64

## If it fails

**`Could not canonicalize path for command root /usr/bin/gcc`** - the
`register_toolchains` line in MODULE.bazel is missing or the `--platforms`
flags are not applied. Bazel resolved your host compiler and shipped a path
the worker does not have.

**`Zero byte hash not empty ... dedup_store`** - the CAS is routing every blob
through the dedup store, which cannot hold zero-byte objects. Every successful
compile uploads empty stdout, so this breaks essentially every action. The
deployed config avoids it with `size_partitioning`; see `../config/cas.json5`.

**Connection timeouts through the proxy** - your source IP is not in the
allowlist. Check `ALLOWED_IPS` in `../create-proxy.sh` and confirm your egress
address with `curl ifconfig.me`.

**Actions run locally with no error** - `container-image` is a non-restrictive
`priority` property in the scheduler config, so a mismatched worker is not
refused. Check the process summary rather than trusting a green build.
