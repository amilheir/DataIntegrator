#!/bin/sh
# One-shot model provisioning for the ollama service (docker-compose.yaml,
# service ollama-init). Pulls the base models and builds the three 8192-context
# masthead picker models from the Modelfiles, plus the Knowledge Base embedding
# model. Idempotent: anything already present is skipped, so after the first
# run this finishes in seconds.
#
# First run downloads roughly 25 GB. The default picker model is done first,
# so the wizard can generate before the rest have finished.

set -u
export OLLAMA_HOST="${OLLAMA_HOST:-ollama:11434}"

until ollama list > /dev/null 2>&1; do
    echo "waiting for $OLLAMA_HOST"
    sleep 2
done

have() { ollama show "$1" > /dev/null 2>&1; }

build() {   # build <picker model> <Modelfile>
    if have "$1"; then
        echo "$1 present"
        return
    fi
    base=$(tr -d '\r' < "/modelfiles/$2" | sed -n 's/^FROM[[:space:]]*//p' | head -1)
    have "$base" || ollama pull "$base" || { echo "!! pull $base failed"; return 1; }
    ollama create "$1" -f "/modelfiles/$2" || { echo "!! create $1 failed"; return 1; }
}

RC=0
# Order: ETLWizard.Setup DEFAULTAGENTMODEL first, then the rest of the picker.
build etlwizard-gemma  Modelfile.gemma  || RC=1
build etlwizard-coder  Modelfile.coder  || RC=1
build etlwizard-ornith Modelfile.ornith || RC=1

# ETLWizard.KG.Setup EMBEDMODEL
EMBED="${EMBEDDING_MODEL:-leoipulsar/harrier-0.6b:latest}"
have "$EMBED" && echo "$EMBED present" || ollama pull "$EMBED" || RC=1

ollama list
exit $RC
