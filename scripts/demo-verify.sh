#!/bin/sh
# One command that either prints READY or names exactly what is wrong
# (IMPROVEMENTS_SPEC RR-4). Everything else in that specification is verified
# through this script.
#
#   sh scripts/demo-verify.sh            # core checks
#   ML=1 sh scripts/demo-verify.sh       # also check the ML preconditions
#   VIEW=executive sh scripts/demo-verify.sh
#
# Exit code is the number of failures, so `if sh demo-verify.sh; then` works.
# Each failure prints ONE actionable line - never a stack trace.

IRIS_C="${IRIS_C:-dataintegrator-iris-1}"
PG_C="${PG_C:-dataintegrator-postgres-1}"
OLLAMA_C="${OLLAMA_C:-dataintegrator-ollama-1}"
BASE="${BASE:-http://localhost:52773}"
AUTH="${AUTH:-_SYSTEM:SYS}"
NS="${NS:-DATAINTEGRATOR}"
# Executive is the shipped default: the instance opens on the opening card for
# a business audience. Override for an engineering session: VIEW=technical ...
WANT_VIEW="${VIEW:-executive}"
ROOT="$(dirname "$0")/.."
# the dropzone file set the presenter intends to discuss (DA-4)
EXPECTED_FILES="daily_sales.csv ecommerce_sales_analytics_5000.csv online_retail.csv sales.csv"

FAILS=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; printf '        -> %s\n' "$2"; FAILS=$((FAILS + 1)); }
warn() { printf '  warn  %s\n' "$1"; }

api() { curl -s -u "$AUTH" --max-time 15 "$BASE/dataintegrator/api$1"; }
irisrun() { docker exec -i "$IRIS_C" iris session IRIS -U "$NS" 2>/dev/null; }
psql() { docker exec -i "$PG_C" psql -U crm -d crm -A -t -q -c "$1" 2>/dev/null; }

echo "== Data Integrator demo readiness"
echo

# ---------------------------------------------------------------- 1  IRIS up
if docker ps --format '{{.Names}}' | grep -qx "$IRIS_C"; then
    pass "IRIS container $IRIS_C is running"
    # PR-2: signs that the previous stop was not graceful. `iris stop IRIS
    # quietly` marks the databases clean; a SIGKILL leaves the WIJ dirty and
    # the next start recovers from the journal - silently rolling back
    # uncheckpointed Config Store writes.
    #
    # Every start prints "Recovery started" and runs a WIJ pass, clean or not.
    # The signal that distinguishes them is the pending-block count: "0 blocks
    # pending in this WIJ" is a clean stop; anything else was rolled forward
    # from a SIGKILL.
    if docker logs "$IRIS_C" 2>&1 | grep -i "blocks pending in this WIJ" | grep -qv "^ *0 blocks"; then
        warn "the last start ran journal recovery - the previous stop was not graceful."
        warn "     Config Store changes made before it may have been rolled back. Re-check them,"
        warn "     and always stop with scripts/stop.sh (or scripts/stop.ps1)."
    else
        pass "no unclean-shutdown markers in the IRIS start log"
    fi
    # IRIS's own state. It goes to "alert" on severity-2 messages and the
    # container then reports unhealthy - worth catching BEFORE a demo, because
    # the usual cause here is the collation-mismatch warning IRIS raises for
    # every wizard-built table (see DEMO_RUNBOOK section 5b).
    # Read the container's healthcheck result rather than exec'ing `iris list`:
    # that exec can block when run from inside this script, and the healthcheck
    # already runs /irisHealth.sh once a minute and records the answer.
    HEALTH=$(docker inspect "$IRIS_C" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
    if [ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "none" ]; then
        pass "IRIS healthcheck: $HEALTH"
    else
        warn "IRIS container healthcheck is '$HEALTH' - IRIS is not in a normal state."
        warn "     Usual cause here is the collation-mismatch warning IRIS raises for every"
        warn "     wizard-built table, which puts it in 'alert'. Not fatal, and it clears on"
        warn "     a graceful restart. See DEMO_RUNBOOK section 5c."
    fi
else
    fail "IRIS container $IRIS_C is not running" "docker compose up -d"
fi

# ------------------------------------------------------- 2  Web Gateway page
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -u "$AUTH" "$BASE/dataintegrator/index.html")
if [ "$CODE" = "200" ]; then
    pass "Web Gateway serves /dataintegrator/index.html"
else
    fail "the UI page returned HTTP $CODE" "check the webgateway container: docker compose logs webgateway"
fi

# ------------------------------------------------------- 3  REST dispatcher
if api /ping | grep -q '"status":"ok"'; then
    pass "REST dispatcher answers /ping"
else
    fail "GET /dataintegrator/api/ping did not answer ok" "check the licence key and the CSP application: docker logs $IRIS_C"
fi

# ------------------------------------------------- 4  PostgreSQL up + seeded
if docker ps --format '{{.Names}}' | grep -qx "$PG_C"; then
    CUST=$(psql "SELECT count(*) FROM sample.customer")
    ORD=$(psql "SELECT count(*) FROM sample.orders")
    EMP=$(psql "SELECT count(*) FROM sample.employee")
    CUST=${CUST:-0}; ORD=${ORD:-0}; EMP=${EMP:-0}
    if [ "$CUST" -ge 300 ] && [ "$CUST" -le 800 ] && [ "$ORD" -ge 3000 ] && [ "$ORD" -le 10000 ] && [ "$EMP" -ge 20 ]; then
        pass "postgres seeded: $EMP employees, $CUST customers, $ORD orders"
    else
        fail "sample data is outside the expected ranges (emp=$EMP cust=$CUST ord=$ORD)" \
             "reseed it: sh scripts/demo-reset.sh   (DA-1 wants 20-40 / 300-800 / 3000-10000)"
    fi
else
    fail "postgres container $PG_C is not running" "docker compose up -d postgres"
fi

# ------------------------------------------------------ 5  foreign servers
OPTS=$(api /wizard/options)
# count "via", not "mode": the response's `sources` array carries a "mode" on
# each of its four entries too, which inflated this by exactly four. "via" only
# appears on a foreign server.
FS=$(printf '%s' "$OPTS" | tr ',' '\n' | grep -c '"via"')
if [ "${FS:-0}" -ge 2 ]; then
    pass "$FS foreign server(s) configured"
else
    fail "fewer than two foreign servers are configured" \
         "re-create them: sh scripts/demo-reset.sh, or mount a source from the Data Sources tab"
fi

# ------------------------------------------------------ 6  mounted tables
# '{"name"' with the brace, not '"name"': a plain match also counts every SOURCE
# COLUMN called "name" - ext_customer has one, so this read 5 for 4 tables.
MOUNTED=$(api /mountable | tr ',' '\n' | grep -c '{"name"')
if [ "${MOUNTED:-0}" -ge 1 ]; then
    pass "$MOUNTED table(s) mounted and available to the wizard"
else
    fail "no mounted tables" "mount the demo tables from the Data Sources tab, or run scripts/demo-reset.sh"
fi

# ------------------------------------------- 7  Ollama up, resident, warm
if docker ps --format '{{.Names}}' | grep -qx "$OLLAMA_C"; then
    MODEL=$(printf '%s' "$(api /models)" | sed -n 's/.*"active":"\([^"]*\)".*/\1/p')
    MODEL=${MODEL:-dataintegrator-coder:latest}
    START=$(date +%s)
    OUT=$(docker exec -i "$OLLAMA_C" ollama run "$MODEL" "reply with the single word ready" 2>/dev/null)
    ELAPSED=$(( $(date +%s) - START ))
    if [ -n "$OUT" ]; then
        pass "LLM $MODEL answered a throwaway prompt in ${ELAPSED}s (pre-warmed)"
        # PR-1 (2): CONFIRM the GPU, do not infer it from how fast the reply
        # came. Silent CPU offload degrades tool-call FORMAT RELIABILITY, not
        # merely speed (spec 27.3) - a model that is 26% on the CPU can still
        # answer a one-word prompt quickly and then produce malformed tool
        # calls on the architect prompt.
        PS=$(docker exec -i "$OLLAMA_C" ollama ps 2>/dev/null | grep "^$MODEL" | head -1)
        PROC=$(printf '%s' "$PS" | grep -o '[0-9]*% *GPU' | head -1)
        CTX=$(printf '%s' "$PS" | awk '{print $(NF-1)}')
        if [ "$PROC" = "100% GPU" ]; then
            pass "model is 100% GPU-resident, context ${CTX:-unknown}"
        elif [ -n "$PROC" ]; then
            fail "model is only $PROC - the rest is on the CPU" \
                 "silent CPU offload degrades tool-call FORMAT reliability, not just speed. Free VRAM or pick a smaller model"
        else
            warn "could not read the processor split from 'ollama ps' - check it by hand"
        fi
        # the 4096 default silently truncates the ~4100-token architect prompt
        case "$CTX" in
            ''|*[!0-9]*) : ;;
            *) [ "$CTX" -lt 8192 ] && fail "model context is $CTX, not 8192" \
                 "below 8192 the architect prompt is silently truncated and the reply comes back EMPTY. Rebuild the picker models: docker compose --profile local-llm up ollama-init" ;;
        esac
    else
        fail "the LLM returned an empty reply" \
             "an empty reply is the num_ctx 4096 truncation signature - rebuild the picker models (docker compose --profile local-llm up ollama-init)"
    fi
else
    fail "ollama container $OLLAMA_C is not running" "docker compose --profile local-llm up -d"
fi

# ------------------------------------------- 8/9/10  governance + view
CFG=$(printf 'do ##class(DataIntegrator.Setup).PrintDemoConfig()\nhalt\n' | irisrun | tr -d '\r' | grep '^{')
DEV=$(printf '%s' "$CFG" | sed -n 's/.*"devMode":\([0-9]*\).*/\1/p')
TMO=$(printf '%s' "$CFG" | sed -n 's/.*"approvalTimeoutSecs":\([0-9]*\).*/\1/p')
DVIEW=$(printf '%s' "$CFG" | sed -n 's/.*"defaultView":"\([a-z]*\)".*/\1/p')

if [ "$DEV" = "0" ]; then
    pass "approvals enforced (devMode=0)"
else
    fail "approvals are NOT enforced (devMode=${DEV:-unset})" \
         "the governance claim is not true in this state. Fix: do ##class(DataIntegrator.Setup).EnableApprovals(900)"
fi
if [ "${TMO:-0}" -ge 900 ]; then
    pass "approval timeout ${TMO}s (survives a question from the audience)"
else
    fail "approval timeout is ${TMO:-300}s" \
         "a 5-minute timeout expires mid-demo. Fix: do ##class(DataIntegrator.Setup).EnableApprovals(900)"
fi
APPROVERS=$(printf '%s' "$CFG" | sed -n 's/.*"approverAccounts":\([0-9]*\).*/\1/p')
MATCHROLES=$(printf '%s' "$CFG" | sed -n 's/.*"appMatchRoles":"\([^"]*\)".*/\1/p')
if [ "${APPROVERS:-0}" -ge 1 ]; then
    pass "$APPROVERS account(s) hold DataIntegrator_Approver"
else
    fail "no account holds DataIntegrator_Approver" \
         "an approval card would have nobody who can resolve it. Fix: do ##class(DataIntegrator.Setup).CreateDemoUsers(\"<password>\")"
fi
# The web applications are installed with MatchRoles=":%All", so every request -
# authenticated or not - already holds every privilege. That is why the approval
# gate checks the named user's OWN roles (Policy.Auth.CanApprove) rather than
# $SYSTEM.Security.Check, which returns true for anybody here.
case "$MATCHROLES" in
    *%All*)
        warn "the web application grants :%All to every request (Installer.cls MatchRoles)."
        warn "     Approvals are still enforced - the gate reads the named user's own roles - but"
        warn "     nothing else on this instance is access-controlled. Do not claim otherwise." ;;
esac
if [ "$DVIEW" = "$WANT_VIEW" ]; then
    pass "default view is $DVIEW"
else
    fail "default view is ${DVIEW:-unset}, expected $WANT_VIEW" \
         "do ##class(DataIntegrator.Setup).SetDefaultView(\"$WANT_VIEW\")"
fi

# ------------------------------------------- 11/12  ML preconditions
if [ "${ML:-0}" = "1" ]; then
    AUTOML=/opt/irisbuild/data/mgr/python/iris_automl/Classifiers
    # MSYS_NO_PATHCONV: Git Bash rewrites a leading-slash argument into a
    # Windows path before docker sees it ("C:/Program Files/Git/opt/..."), and
    # every one of these checks would then fail for the wrong reason.
    export MSYS_NO_PATHCONV=1
    if docker exec "$IRIS_C" test -d "$AUTOML"; then
        pass "AutoML present on the durable path"
    else
        fail "AutoML is missing at $AUTOML" \
             "a reused iris-data volume does not pick it up from the image. Fix: sh scripts/install-automl.sh"
    fi
    STALE=""
    for f in modeloX.py my_model123.py testemodel.py; do
        docker exec "$IRIS_C" test -f "$AUTOML/$f" && STALE="$STALE $f"
    done
    if [ -z "$STALE" ]; then
        pass "no stale classifiers in Classifiers/"
    else
        fail "stale classifiers still installed:$STALE" \
             "they COMPETE in every training run (modeloX.py is the source of 'Decision TreeX'). Remove them from $AUTOML"
    fi
    # PR-3 (3): the demo model must already be TRAINED. Training live is a
    # variable-duration, silent operation and a poor stage risk.
    MODELS=$(api /ml/models)
    if printf '%s' "$MODELS" | grep -q '"name":"order_completion_risk"'; then
        if printf '%s' "$MODELS" | tr '}' '\n' | grep 'order_completion_risk' | grep -q '"trained":1'; then
            pass "demo model order_completion_risk is pre-trained"
        else
            fail "order_completion_risk exists but is NOT trained" \
                 "train it before the demo, never during it: POST /ml/train {\"name\":\"order_completion_risk\",\"table\":\"DATAINTEGRATOR.ext_daily_sales\"}"
        fi
    else
        fail "the demo model order_completion_risk does not exist" \
             "create and train it on DATAINTEGRATOR.ext_daily_sales predicting 'outcome' - see DEMO_RUNBOOK section 3.5"
    fi
    # the picker is on screen in Step 9; anything else in it is clutter
    NMODELS=$(printf '%s' "$MODELS" | tr ',' '\n' | grep -c '"name"')
    [ "${NMODELS:-0}" -gt 1 ] && warn "$NMODELS models exist - only order_completion_risk is part of the demo; the rest are visible clutter"
fi

# ------------------------------------------------------ 13  dropzone hygiene
ACTUAL=$(ls "$ROOT/src-iris/dropzone" 2>/dev/null | sort | tr '\n' ' ')
WANT=$(printf '%s\n' $EXPECTED_FILES | sort | tr '\n' ' ')
if [ "$ACTUAL" = "$WANT" ]; then
    pass "dropzone holds exactly the intended files"
else
    fail "dropzone contents differ from the intended set" \
         "have: $ACTUAL | want: $WANT   (demo-newday.sh adds files; scripts/demo-reset.sh restores the set)"
fi

# ------------------------------------------------------ 14  clean start
PIPES=$(api /pipelines | tr ',' '\n' | grep -c '"id"')
if [ "${PIPES:-0}" -eq 0 ]; then
    pass "no pipelines in the picker - clean start"
else
    fail "$PIPES pipeline(s) already exist" "sh scripts/demo-reset.sh"
fi

# ------------------------------------------------------ 15  secrets
FOUND=$(find "$ROOT" -maxdepth 3 \( -name '*.key' -o -name 'irispw.txt' \) 2>/dev/null)
if [ -z "$FOUND" ]; then
    pass "no credential material under the project tree"
else
    fail "credential material is inside the project tree" \
         "move it out and point .env at it (IRIS_KEY_PATH / IRIS_PW_FILE): $FOUND"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "READY"
else
    echo "NOT READY - $FAILS check(s) failed (see the -> lines above)"
fi
exit "$FAILS"
