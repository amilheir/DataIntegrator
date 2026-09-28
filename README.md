# Data Integration — an IRIS AI wizard

AI-assisted, low-code data integration built entirely on **InterSystems IRIS** with the
**AI Hub EAP** (`%AI.Agent`). A user picks a source and describes the transformation they
want; IRIS discovers and profiles the source, scores the loading strategies, generates the
SQL and every artifact (Foreign Servers/Tables, landing/staging/target DDL, merge SQL,
validation rules), and deploys and runs the pipeline in the same instance — with a
real-time architecture graph rendered from a seq-replayable event log.

Two things are worth being precise about, because they are often conflated. Discovery and
strategy scoring are **deterministic**: `Tools.SourceDiscovery` reads JDBC/ODBC metadata
and infers CSV types, and `Tools.Strategy` scores the options by rule — the model only
narrates them. The **LLM** writes the transformation SQL and suggests merge keys
(`Agent.SqlGen`), recommends indexes, proposes MCP tools, and does the entity extraction
and chat in the Knowledge Base. Separately, `DataIntegrator.Agent.Architect` is a full
`%AI.Agent` carrying the 12-step wizard prompt and a composed toolset over all of the
above; it drives the same tools the UI does and is reachable at
`POST /runs/:runId/message`, though the five tabs call those tools directly rather than
going through it.

What the pipeline produces does not stop at a table. The same UI publishes those tables to
MCP clients as tools, and embeds their free text into vectors and a knowledge graph that
can be asked questions — all inside this one instance, with nothing copied anywhere.

The product is called **Data Integration**; the code package is `DataIntegrator`, and the
namespace is `DATAINTEGRATOR`.

```bash
sh scripts/demo-verify.sh    # READY, or exactly what is wrong
sh scripts/demo-reset.sh     # back to a known-good, demo-ready state
sh scripts/stop.sh           # the ONLY supported way to stop the stack
```

## Layout

```
docker-compose.yaml        IRIS (AI Hub EAP image) + webgateway + postgres + ollama
Modelfile.ornith           dataintegrator-ornith  \
Modelfile.gemma            dataintegrator-gemma    > the three masthead picker models
Modelfile.coder            dataintegrator-coder   /  (all 8192-context, spec §27.3)
Modelfile                  dataintegrator-qwen (9B; needs >8 GB VRAM — see Modelfile.coder)
mds/                       the specs and the per-tab build plans, each with its
                           measured results and the bugs found building it
src-iris/
  Dockerfile               build: load + compile DataIntegrator into DATAINTEGRATOR namespace
  iris.script              namespace setup + build-161+ compile ordering
  Installer.cls            DATAINTEGRATOR namespace, /dataintegrator + /dataintegrator/api web apps
  config.toml              iris-mcp-server sidecar: the MCP endpoints it serves
  cpf/cpfmerge.cpf         CPF merge (CallIn service)
  frontend/index.html      the whole UI: one self-contained file, no build step
  dropzone/                CSV source files the wizard can mount or bulk load
  src/DataIntegrator/
    Model/                 Pipeline · Node · Edge · Run · Event · Watermark ·
                           Production · PendingApproval
    Msg/                   ExtractBatch · LoadResult (interoperability messages)
    API/Dispatcher.cls     %CSP.REST endpoints (spec §15)
    WS/Hub.cls             %CSP.WebSocket, {runId,lastSeq} replay protocol (spec §14)
    Agent/                 Architect (%AI.Agent) · Service · ProviderFactory ·
                           SqlGen · GraphExtract (LINK-KG entity extraction)
    Tools/                 ForeignTable · Load · Indexing · Transformation ·
                           DataQuality · Catalog · Production · BulkLoad ·
                           CsvProfiling · RestSource · MLModel · Util
    Host/                  Interoperability hosts: ExtractService · Orchestrator ·
                           LoadOperation · SampleData{Operation,Tick}
    Runtime/Executor.cls   what a deployed pipeline actually runs
    MCP/Publisher.cls      publishes target tables as %AI.ToolSet queries on
                           /mcp/irisaihub, and owns the web app that serves them
    KG/                    Setup (schema + %Embedding.Config) · Embedder ·
                           Ingest (chunk → vector → graph) · Chat · Models
    ToolSet/               the worked %AI.ToolSet example the publisher is modelled on
    Policy/                Audit · Auth (blocking approval policy)
    Setup.cls              Config Store profiles, RBAC, demo preparation, smoke test
scripts/
  stop.sh / stop.ps1       graceful shutdown - the ONLY supported stop path
  demo-verify.sh           readiness: READY, or exactly what is wrong
  demo-reset.sh            back to a known-good, demo-ready state
  demo-newday.sh           add source rows so the incremental story is provable
  demo.ps1                 Windows entry point for the three demo scripts
  install-automl.sh        AutoML onto the durable path (reused iris-data volumes)
```

**The frontend is five tabs**, not a canvas stub:

| Tab | What it does |
|---|---|
| **Data Sources** | Standing configuration: gateway connections, foreign servers, and the tables mounted from them. Also bulk-loads a CSV/XLSX once into an `DATAINTEGRATOR.ext_*` table — no production, no schedule. Global — not tied to any one pipeline. |
| **ETL Interop** | Builds one ETL at a time from tables that already exist: pick tables → generate/edit the SQL → choose strategy, watermark and schedule → deploy, load, and optionally index. Owns the live flowchart and the results panel, which reports the whole integration time from the Extract's `TimeCreated` to the Load's `TimeProcessed`. |
| **ML Models** | IntegratedML workbench over any mounted table: create, train, validate, inspect metrics, predict. |
| **AI Tools** | Proposes one tool per question a target table can answer, lets you edit and try them, and publishes the ones you keep as an `%AI.ToolSet` on `/mcp/irisaihub` — reachable from Claude and any other MCP client. Nothing is exposed until you publish. |
| **Knowledge Base** | Two sections. **Embedding** turns a column of free text into vectors, and optionally mines entities and relationships from it (LINK-KG). **Chat & Knowledge graph** asks that corpus questions on the left and draws the graph it built on the right. |

A masthead toggle switches between **Technical** and **Executive** views of the same
application — same instance, same capabilities, different audience. Set the instance
default with `do ##class(DataIntegrator.Setup).SetDefaultView("executive")`.

## The Knowledge Base, in one paragraph

Text is chunked, embedded through Ollama into `VECTOR(FLOAT, 1024)` columns in the
`ETLW_KG` schema, and searched with `VECTOR_COSINE` over an HNSW index — `TOP n … ORDER BY
score DESC`, which is what actually activates that index. Extraction feeds each chunk the
canonical entities already found in the corpus, so the second chunk that mentions a thing
attaches to the node the first one created instead of inventing a second. Answering is
asynchronous: a question is a row the UI polls, because the model takes tens of seconds and
the Web Gateway does not wait that long.

Re-embedding the same column offers a choice. **Incremental** compares each row's text by
hash against what the corpus already holds and embeds only what is new or changed —
changed rows have their old chunks and facts replaced, not duplicated. **Redo** builds a
second knowledge base from scratch. With graph extraction on, batches are deliberately
small: extraction costs seconds to tens of seconds *per chunk*, and a batch that overruns
the gateway's 300 s ceiling is thrown away mid-flight.

## The local models

One Ollama container serves everything — the architect agent, the SQL generation, the
embeddings, the extraction and the chat. On an 8 GB card that means the small embedding
model stays resident and exactly one generation model sits beside it at a time:

| Model | Role |
|---|---|
| `leoipulsar/harrier-0.6b` | embeddings — 1024 dimensions, ~31 ms/row at batch 32 |
| `dataintegrator-coder` | SQL generation, and entity/relationship extraction (measured ~5× faster than gemma at that job) |
| `dataintegrator-gemma` | the conversational answer in the chat pane |
| `dataintegrator-ornith` | the third masthead picker option |

The masthead picker reports each model's **real** resident size read from `/api/ps`, not
the download size — the two differ by enough to matter on an 8 GB card.
