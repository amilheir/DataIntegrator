#!/bin/bash
# Runs once IRIS is up (iris-main -a, see docker-compose.yaml). Brings a fresh
# stack to "ready to use" with no manual step after `docker compose up`:
#   1. warn about required external files that are missing (gitignored, so a
#      fresh clone lacks them) - they are never fetched, only reported
#   2. the gateway connection, both foreign servers and the demo mounts - but
#      only on a fresh iris-data volume; an existing one keeps what it has
#   3. /tmp/dataintegrator-ready, which the compose healthcheck waits for
#
# The seeding runs in the background and this script always exits 0: iris-main
# must not block on it or treat a slow Postgres as a failed start.

LOG=/opt/irisbuild/data/startup.log
NS=DATAINTEGRATOR

# Required external files: path, then what breaks without it.
REQUIRED="
/opt/irisbuild/jdbc/postgresql-42.7.4.jar|JDBC sources (SRC_POSTGRES, ext_customer/employee/orders) will not mount - put the PostgreSQL JDBC 42.7.4 jar in src-iris/jdbc/
/opt/irisbuild/dropzone/daily_sales.csv|the CSV demo mount ext_daily_sales will be empty - put daily_sales.csv in src-iris/dropzone/
"

# Foreground, so the warnings also reach `docker compose logs iris`.
echo "$REQUIRED" | while IFS='|' read -r f why; do
    [ -z "$f" ] && continue
    [ -s "$f" ] || echo "WARNING: missing $f - $why" | tee -a "$LOG"
done

seed() {
    rm -f /tmp/dataintegrator-ready
    echo "== $(date -Is) startup seeding"

    # Postgres runs its init scripts before it accepts TCP, so a reachable port
    # also means the demo schema exists.
    for i in $(seq 1 120); do
        (exec 3<>/dev/tcp/postgres/5432) 2>/dev/null && break
        sleep 2
    done

    MOUNTED=$(printf 'write "MOUNTED=",$SYSTEM.SQL.Schema.TableExists("DATAINTEGRATOR.ext_customer"),!\nhalt\n' \
        | iris session IRIS -U "$NS" | tr -d '\r' | sed -n 's/^MOUNTED=//p')
    if [ "$MOUNTED" = "1" ]; then
        echo "demo tables already mounted - leaving the volume as it is"
    else
        # Two sessions on purpose: a foreign server created in one process is
        # not visible to the schema importer in that same process (SQLCODE -237).
        # See DataIntegrator.Setup.PrepareServers().
        printf 'do ##class(DataIntegrator.Setup).PrepareServers()\nhalt\n' | iris session IRIS -U "$NS"
        printf 'do ##class(DataIntegrator.Setup).MountDemoTables()\nhalt\n' | iris session IRIS -U "$NS"
    fi

    touch /tmp/dataintegrator-ready
    echo "== $(date -Is) ready"
}

seed >> "$LOG" 2>&1 &
exit 0
