#!/bin/sh
# Reset to a known-good, demo-ready state without a rebuild
# (IMPROVEMENTS_SPEC RR-1 / RR-3). Target: under two minutes, ending in a
# demo-verify.sh pass.
#
#   sh scripts/demo-reset.sh
#
# Sequence:
#   1. POST /clear-all         - pipelines and every wizard-built object
#   2. re-create the gateway connection and both foreign servers
#   3. re-mount the demo tables
#   4. RESEED postgres         - undoes demo-newday.sh. Without this the second
#                                demo of the day shows zero new rows.
#   5. restore the dropzone to exactly the intended file set
#   6. re-warm the LLM
#   7. run demo-verify.sh and exit on its result
#
# It does NOT stop or rebuild anything, and it does not touch the durable
# volumes. Nothing here needs the stack to come down.

set -e

IRIS_C="${IRIS_C:-dataintegrator-iris-1}"
PG_C="${PG_C:-dataintegrator-postgres-1}"
OLLAMA_C="${OLLAMA_C:-dataintegrator-ollama-1}"
BASE="${BASE:-http://localhost:52773}"
AUTH="${AUTH:-_SYSTEM:SYS}"
NS="${NS:-DATAINTEGRATOR}"
ROOT="$(dirname "$0")/.."

START=$(date +%s)
echo "== 1/7  clearing pipelines and wizard-built objects"
curl -s -u "$AUTH" -X POST "$BASE/dataintegrator/api/clear-all" | head -c 300
echo

# The SOURCES are restored before anything is mounted over them. A foreign
# table records the column shape it imported, so mounting first and reseeding
# afterwards leaves the mount describing a table that no longer exists in that
# form - it happens to work while the shape is unchanged, and stops working
# silently the first time the sample schema gains a column.
echo "== 2/7  reseeding postgres from postgres-init (undoes demo-newday.sh)"
docker exec -i "$PG_C" psql -U crm -d crm -q -c "DROP SCHEMA IF EXISTS sample CASCADE;" > /dev/null
docker exec -i "$PG_C" psql -U crm -d crm -q -v ON_ERROR_STOP=1 < "$ROOT/postgres-init/02_sample_schema.sql" > /dev/null
docker exec -i "$PG_C" psql -U crm -d crm -A -t -c \
  "SELECT 'seeded: ' || (SELECT count(*) FROM sample.employee) || ' employees, '
       || (SELECT count(*) FROM sample.customer) || ' customers, '
       || (SELECT count(*) FROM sample.orders) || ' orders'" | sed 's/^/     /'

echo "== 3/7  restoring the dropzone"
# demo-newday.sh drops timestamped files in; take them back out. The curated
# set is whatever is committed here minus those.
find "$ROOT/src-iris/dropzone" -name 'daily_sales_*.csv' -type f -print -delete | sed 's/^/     removed /'
if [ ! -f "$ROOT/src-iris/dropzone/daily_sales.csv" ]; then
    echo "     !! daily_sales.csv is missing from the dropzone - the CSV path will have nothing to mount"
fi

echo "== 4/7  re-creating the connection and the foreign servers"
printf 'do ##class(DataIntegrator.Setup).PrepareServers()\nhalt\n' \
  | docker exec -i "$IRIS_C" iris session IRIS -U "$NS" | tr -d '\r' | sed 's/^/     /'

# A SEPARATE session on purpose: a foreign server created in one process is not
# visible to the schema importer in that same process, and the mount fails with
# "SQLCODE -237: Failed to craft query string for schema import". Waiting inside
# the first session does not fix it - see DataIntegrator.Setup.PrepareServers().
echo "== 5/7  re-mounting the demo tables (new session - see the -237 note)"
printf 'do ##class(DataIntegrator.Setup).MountDemoTables()\nhalt\n' \
  | docker exec -i "$IRIS_C" iris session IRIS -U "$NS" | tr -d '\r' | sed 's/^/     /'

echo "== 6/7  re-warming the LLM"
MODEL=$(curl -s -u "$AUTH" "$BASE/dataintegrator/api/models" | sed -n 's/.*"active":"\([^"]*\)".*/\1/p')
MODEL=${MODEL:-dataintegrator-coder:latest}
docker exec -i "$OLLAMA_C" ollama run "$MODEL" "reply with the single word ready" > /dev/null 2>&1 \
  && echo "     $MODEL is resident and answering" \
  || echo "     !! $MODEL did not answer - check the ollama container"

echo "== 7/7  verifying"
echo "     (reset took $(( $(date +%s) - START ))s)"
echo
sh "$ROOT/scripts/demo-verify.sh"
