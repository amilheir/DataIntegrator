# Graceful shutdown for the Data Integrator stack - PowerShell equivalent of stop.sh
# (IMPROVEMENTS_SPEC PR-2). The primary environment is Windows; stop.sh is sh.
#
#   powershell -ExecutionPolicy Bypass -File scripts\stop.ps1
#
# Use this INSTEAD of `docker compose down` / `docker compose stop`.
#
# Why: `docker stop` sends SIGTERM, and IRIS does not trap it in the default
# entrypoint, so Docker SIGKILLs it after the grace period. The WIJ (write image
# journal) is never flushed. Two consequences, both silent:
#
#   1. The next start runs journal recovery (30-300s on a large instance).
#   2. Writes that had not been checkpointed are LOST. This is not theoretical
#      here - a Config Store change (the masthead model picker) was verified
#      applied, then reverted by a `docker compose up` that recreated the IRIS
#      container underneath it. No error appears anywhere; the value simply
#      reads back as its previous state.
#
# `iris stop IRIS quietly` flushes the WIJ and marks the databases clean, so the
# next start is instant and nothing is rolled back.
#
# stop_grace_period alone does NOT fix this - IRIS ignores SIGTERM (and
# SIGUSR1/SIGUSR2), so a longer grace period just delays the same SIGKILL.

param(
    [string]$Container = "dataintegrator-iris-1",
    [string[]]$ComposeArgs = @()
)

$ErrorActionPreference = "Stop"

$running = docker ps --format "{{.Names}}"
if ($running -contains $Container) {
    Write-Output "== flushing IRIS in $Container"
    docker exec $Container iris stop IRIS quietly
    if ($LASTEXITCODE -ne 0) {
        Write-Output "!! graceful stop failed - the next start will run journal recovery"
    }
} else {
    Write-Output "== $Container not running, nothing to flush"
}

Write-Output "== docker compose down"
docker compose --profile local-llm down @ComposeArgs
