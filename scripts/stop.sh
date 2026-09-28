#!/bin/sh
# Graceful shutdown for the Data Integrator stack.
#
# Use this INSTEAD of `docker compose down` / `docker compose stop`.
#
# Why: `docker stop` sends SIGTERM, and IRIS does not trap it in the default
# entrypoint, so Docker SIGKILLs it after the grace period. The WIJ (write
# image journal) is never flushed. Two consequences, both silent:
#
#   1. The next start runs journal recovery (30-300s on a large instance).
#   2. Writes that had not been checkpointed are LOST. This is not theoretical
#      here - a Config Store change (the masthead model picker) was verified
#      applied, then reverted by a `docker compose up` that recreated the IRIS
#      container underneath it. No error appears anywhere; the value simply
#      reads back as its previous state.
#
# `iris stop IRIS quietly` flushes the WIJ and marks the databases clean, so
# the next start is instant and nothing is rolled back.
#
# Note that `stop_grace_period` alone does NOT fix this - IRIS ignores SIGTERM
# (and SIGUSR1/SIGUSR2), so a longer grace period just delays the same SIGKILL.

set -e

CONTAINER="${1:-dataintegrator-iris-1}"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "== flushing IRIS in $CONTAINER"
    docker exec "$CONTAINER" iris stop IRIS quietly || \
        echo "!! graceful stop failed - the next start will run journal recovery"
else
    echo "== $CONTAINER not running, nothing to flush"
fi

echo "== docker compose down"
docker compose --profile local-llm down "$@"
