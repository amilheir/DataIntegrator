/// One-time configuration helpers (spec §27.1). Run from a terminal in the
/// ETLWIZARD namespace after the container is up:
///
///   do ##class(ETLWizard.Setup).ConfigureLocalProfile()          // Ollama
///   do ##class(ETLWizard.Setup).ConfigureCloudProfile("anthropic","claude-sonnet-4-5","secret://AISecrets.anthropic#apikey")
///   do ##class(ETLWizard.Setup).SmokeTest()
Class ETLWizard.Setup Extends %RegisteredObject
{

/// Point AI.LLM.ETLWizard at a local Ollama endpoint (spec §27.1 Path A:
/// the nim provider speaks the OpenAI-compatible protocol Ollama serves).
/// Build the model first:  ollama create etlwizard-coder -f Modelfile.coder
/// IMPORTANT (verified on build 162): base_url MUST end with a trailing slash.
/// The provider joins relative segments ("models", "chat/completions") onto it
/// with URL-join semantics, so ".../v1" resolves to "/models" (404) while
/// ".../v1/" correctly resolves to "/v1/models".
/// The architect prompt (system + tool specs) is ~4K tokens on its own, so the
/// model must carry a context bigger than Ollama's 4096 default or the reply
/// comes back EMPTY (llama.cpp logs "truncated = 1"). Both etlwizard-coder and
/// the older etlwizard-qwen set num_ctx 8192 — build one before using this.
///
/// This profile and AI.LLM.ETLWizardSqlGen deliberately share one model. They
/// were split historically, but on an 8 GB card the 9B etlwizard-qwen build
/// (6.4 GB, 23% of layers on CPU) cannot be resident alongside the SqlGen
/// model, so every architect <-> SqlGen alternation evicted one and paid a
/// 5-18s reload. etlwizard-coder is 5.0 GB fully on GPU and serves both.
/// Re-split only if a benchmark on real pipelines shows the planning quality
/// is worth the reload cost.
/// verbose=0 suppresses the confirmation Write — required when calling this
/// from a REST handler, where anything written to the current device lands in
/// the response body ahead of the JSON and breaks the client's r.json().
ClassMethod ConfigureLocalProfile(baseUrl As %String = "http://host.docker.internal:11434/v1/", model As %String = "etlwizard-coder:latest", verbose As %Boolean = 1) As %Status
{
    Set sc = $$$OK
    Try {
        Try {
            Do ##class(%ConfigStore.Configuration).Delete("AI.LLM.ETLWizard")
        } Catch {
            // no previous entry — fine
        }
        Set config = {"model_provider": "nim", "model": (model), "base_url": (baseUrl)}
        Do ##class(%ConfigStore.Configuration).Create("AI", "LLM", "", "ETLWizard", config)
        If verbose {
            Write "AI.LLM.ETLWizard -> nim @ ", baseUrl, " model=", model, !
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// The models offered by the masthead picker in the frontend, newest first.
///
/// This is an ALLOWLIST, not a listing of whatever Ollama happens to hold. The
/// picker posts an id back to /models/select, so accepting arbitrary strings
/// would let a browser point the agents at any model — or any base_url — on the
/// host. Only ids appearing here are accepted.
///
/// "id" is the real Ollama tag; "label" is what the user sees. They differ
/// because every option is an 8192-context build (Modelfile.ornith /
/// Modelfile.gemma / Modelfile.coder) of the model named in the label. The
/// stock 4096 default silently truncates the ~4100-token architect prompt and
/// returns an EMPTY reply, and the OpenAI-compatible endpoint Ollama serves
/// cannot set num_ctx per request — so the context has to be baked into a
/// derived model. Build all three before exposing the picker:
///   ollama create etlwizard-ornith -f Modelfile.ornith
///   ollama create etlwizard-gemma  -f Modelfile.gemma
///   ollama create etlwizard-coder  -f Modelfile.coder
ClassMethod AgentModels() As %DynamicArray
{
    Return [
        {"id": "etlwizard-ornith:latest", "label": "ornith-1.5:9b"},
        {"id": "etlwizard-gemma:latest", "label": "gemma4:e4b"},
        {"id": "etlwizard-coder:latest", "label": "qwen2.5-coder:7b"}
    ]
}

/// The picker's default, used when no profile is set yet.
Parameter DEFAULTAGENTMODEL = "etlwizard-gemma:latest";

/// Model id currently serving the agents, read from the architect profile.
/// Returns "" if the profile is missing or names something not in AgentModels().
ClassMethod GetAgentModel() As %String
{
    Try {
        Set sc = ##class(%ConfigStore.Configuration).GetDetails("AI.LLM.ETLWizard", .details, 0, 1)
        If $$$ISERR(sc) {
            Return ""
        }
        Set current = details."model"
        Set models = ..AgentModels()
        Set iter = models.%GetIterator()
        While iter.%GetNext(, .entry) {
            If entry.id = current {
                Return current
            }
        }
    } Catch {
    }
    Return ""
}

/// Point BOTH agent profiles at one of the AgentModels() ids.
///
/// The architect (AI.LLM.ETLWizard) and the SQL/index agents
/// (AI.LLM.ETLWizardSqlGen) deliberately move together: on an 8 GB card two
/// different models cannot both stay resident, so a split makes every
/// architect <-> SqlGen alternation evict one and pay a 5-18s reload.
ClassMethod SetAgentModel(id As %String, Output error As %String) As %Boolean
{
    Set error = ""
    Set baseUrl = "http://ollama:11434/v1/"
    Try {
        Set models = ..AgentModels()
        Set found = 0
        Set iter = models.%GetIterator()
        While iter.%GetNext(, .entry) {
            If entry.id = id {
                Set found = 1
                Quit
            }
        }
        If 'found {
            Set error = "unknown model: " _ id
            Return 0
        }
        // Keep whatever base_url is already configured — a host-installed
        // Ollama uses host.docker.internal, the compose profile uses "ollama".
        Try {
            Set sc = ##class(%ConfigStore.Configuration).GetDetails("AI.LLM.ETLWizard", .details, 0, 1)
            If $$$ISOK(sc), details."base_url" '= "" {
                Set baseUrl = details."base_url"
            }
        } Catch {
        }
        // verbose=0: this runs inside a REST handler, and a Write here would
        // corrupt the JSON response body
        Set sc = ..ConfigureLocalProfile(baseUrl, id, 0)
        If $$$ISERR(sc) {
            Set error = $system.Status.GetErrorText(sc)
            Return 0
        }
        Set sc = ..ConfigureSqlGenProfile(id, baseUrl, 0)
        If $$$ISERR(sc) {
            Set error = $system.Status.GetErrorText(sc)
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

/// Point AI.LLM.ETLWizard at a cloud provider. apiKeyRef should be a secret
/// reference (secret://Collection.item#key) — never a raw key (spec §16.4).
ClassMethod ConfigureCloudProfile(providerName As %String, model As %String, apiKeyRef As %String) As %Status
{
    Set sc = $$$OK
    Try {
        Try {
            Do ##class(%ConfigStore.Configuration).Delete("AI.LLM.ETLWizard")
        } Catch {
            // no previous entry — fine
        }
        Set config = {"model_provider": (providerName), "model": (model), "api_key": (apiKeyRef)}
        Do ##class(%ConfigStore.Configuration).Create("AI", "LLM", "", "ETLWizard", config)
        Write "AI.LLM.ETLWizard -> ", providerName, " model=", model, !
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// Point SQL generation and the index advisor at their own, faster model.
/// Falls back to AI.LLM.ETLWizard if unset.
///
/// Model choice is about output length, not tokens/sec. Benchmarked on the
/// index-advisor prompt (431 in, ~150 tokens of JSON is the whole answer):
///   qwen2.5-coder:7b       148 out   12.7s  valid JSON
///   gemma4:e4b-it-q4_K_M  1503 out   56.3s  JSON buried in markdown prose
///   etlwizard-qwen         3072 out  3m35s  rambled past the cap, no JSON
/// gemma4 is the fastest per token (32 tok/s, fully on GPU) and still the
/// slowest wall-clock, because it writes 10x more than the task needs — which
/// is what pushed this past the Web Gateway timeout. A small code model treats
/// "respond with ONLY the JSON array" literally.
/// Uses the 8192-context build (Modelfile.coder) rather than stock
/// qwen2.5-coder:7b, whose 4096 default silently truncates the larger prompts.
/// verbose=0 suppresses the confirmation Write — see ConfigureLocalProfile.
ClassMethod ConfigureSqlGenProfile(model As %String = "etlwizard-coder:latest", baseUrl As %String = "http://ollama:11434/v1/", verbose As %Boolean = 1) As %Status
{
    Set sc = $$$OK
    Try {
        Try {
            Do ##class(%ConfigStore.Configuration).Delete("AI.LLM.ETLWizardSqlGen")
        } Catch {
        }
        Set config = {"model_provider": "nim", "model": (model), "base_url": (baseUrl)}
        Do ##class(%ConfigStore.Configuration).Create("AI", "LLM", "", "ETLWizardSqlGen", config)
        If verbose {
            Write "AI.LLM.ETLWizardSqlGen -> ", model, " @ ", baseUrl, !
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// Create/replace a SQL Gateway JDBC connection (spec §4.2) — the named
/// connection CREATE FOREIGN SERVER ... CONNECTION '<name>' refers to.
/// Password note: dev/demo only; production uses externally-managed gateway
/// connections + secret references (spec §16.4).
ClassMethod CreateGatewayConnection(name As %String = "pg_crm_connection", url As %String = "jdbc:postgresql://postgres:5432/crm", user As %String = "crm", password As %String = "crm", driver As %String = "org.postgresql.Driver", classpath As %String = "/opt/irisbuild/jdbc/postgresql-42.7.4.jar") As %Status
{
    Set sc = $$$OK
    Try {
        Set old = ##class(%Library.SQLConnection).NameIndexOpen(name)
        If $IsObject(old) {
            $$$ThrowOnError(##class(%Library.SQLConnection).%DeleteId(old.%Id()))
        }
        Set conn = ##class(%Library.SQLConnection).%New()
        Set conn.Name = name
        Set conn.isJDBC = 1
        Set conn.driver = driver
        Set conn.URL = url
        Set conn.Usr = user
        Set conn.pwd = password
        Set conn.classpath = classpath
        Set sc = conn.%Save()
        If $$$ISOK(sc) {
            Write "SQL Gateway connection '", name, "' -> ", url, !
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// Create/replace a SQL Gateway connection of either kind, for the wizard's
/// "new connection" form (spec §4.2).
///   kind "jdbc" -> url (jdbc:...) + driver class + classpath (driver jar)
///   kind "odbc" -> dsn (a system DSN defined on the IRIS host)
/// The credentials are stored in the IRIS SQL Gateway registry, which is how
/// IRIS reaches external databases; they are never echoed back to the client.
/// Returns "" on success or an error message.
ClassMethod CreateGatewayConnectionAny(name As %String, kind As %String = "jdbc", url As %String = "", dsn As %String = "", user As %String = "", password As %String = "", driver As %String = "", classpath As %String = "") As %String
{
    Try {
        Set name = $ZStrip(name, "<>W")
        If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
            Return "ERROR: connection name must be letters, digits and underscores"
        }
        Set kind = $ZConvert($ZStrip(kind, "<>W"), "L")
        If kind = "jdbc" {
            If $ZStrip(url, "<>W") = "" {
                Return "ERROR: a JDBC URL is required (e.g. jdbc:postgresql://host:5432/db)"
            }
            If $ZStrip(driver, "<>W") = "" {
                Return "ERROR: a JDBC driver class is required (e.g. org.postgresql.Driver)"
            }
        } ElseIf kind = "odbc" {
            If $ZStrip(dsn, "<>W") = "" {
                Return "ERROR: an ODBC DSN name is required"
            }
        } Else {
            Return "ERROR: kind must be jdbc or odbc"
        }
        Set old = ##class(%Library.SQLConnection).NameIndexOpen(name)
        If $IsObject(old) {
            $$$ThrowOnError(##class(%Library.SQLConnection).%DeleteId(old.%Id()))
        }
        Set conn = ##class(%Library.SQLConnection).%New()
        Set conn.Name = name
        Set conn.Usr = user
        Set conn.pwd = password
        If kind = "jdbc" {
            Set conn.isJDBC = 1
            Set conn.URL = url
            Set conn.driver = driver
            Set conn.classpath = classpath
        } Else {
            Set conn.isJDBC = 0
            Set conn.DSN = dsn
        }
        Set sc = conn.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// One-shot P1 demo configuration: LLM profile (compose ollama) + the
/// pg_crm_connection gateway entry for the compose postgres service.
ClassMethod ConfigureP1Demo() As %Status
{
    Set sc = ..ConfigureLocalProfile("http://ollama:11434/v1/")
    If $$$ISERR(sc) {
        Return sc
    }
    Return ..CreateGatewayConnection()
}

/// RBAC (spec §16.1): create the ETLWizard.Approve resource and the three
/// roles. ETLWizard_User = run wizard + preview (no extra resource);
/// ETLWizard_Approver = resolve approval cards; ETLWizard_Admin = both plus
/// %Gateway_Object:USE for JDBC foreign tables.
/// Approval enforcement is on unless dev mode: set ^ETLWizard("devMode") = 1
/// to allow unauthenticated dev use (the default shipped state).
ClassMethod CreateRoles() As %Status
{
    Set sc = $$$OK
    Try {
        New $NAMESPACE
        Set $NAMESPACE = "%SYS"
        If '##class(Security.Resources).Exists("ETLWizard.Approve") {
            $$$ThrowOnError(##class(Security.Resources).Create("ETLWizard.Approve", "Approve ETL Wizard destructive tool calls", "", 0))
        }
        If '##class(Security.Roles).Exists("ETLWizard_User") {
            $$$ThrowOnError(##class(Security.Roles).Create("ETLWizard_User", "Run the ETL wizard, preview artifacts", ""))
        }
        If '##class(Security.Roles).Exists("ETLWizard_Approver") {
            $$$ThrowOnError(##class(Security.Roles).Create("ETLWizard_Approver", "Approve DDL/deploy approval cards", "ETLWizard.Approve:USE"))
        }
        If '##class(Security.Roles).Exists("ETLWizard_Admin") {
            $$$ThrowOnError(##class(Security.Roles).Create("ETLWizard_Admin", "ETL Wizard administration", "ETLWizard.Approve:USE,%Gateway_Object:USE"))
        }
        Write "Roles ETLWizard_User / ETLWizard_Approver / ETLWizard_Admin ready", !
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/* ===================================================================
   Presentation and governance configuration (IMPROVEMENTS_SPEC §1.1, §3)

   All of it lives in ^ETLWizard(...) so an instance can be pointed at a
   different audience without a redeployment, and so scripts/demo-verify.sh
   can assert the shipped state from outside.
   =================================================================== */
/// Fallback when ^ETLWizard("defaultView") has never been set: the product
/// behaves exactly as it always has.
Parameter DEFAULTVIEW = "technical";

/// Which view a browser with no session choice of its own opens in:
/// "technical" (every control, full vocabulary) or "executive" (narrative
/// first, engineering detail withdrawn). Served on GET /wizard/options.
ClassMethod GetDefaultView() As %String
{
    Set view = $ZConvert($Get(^ETLWizard("defaultView"), ..#DEFAULTVIEW), "L")
    If (view '= "technical") && (view '= "executive") {
        Set view = ..#DEFAULTVIEW
    }
    Return view
}

/// Set the instance-wide default view. Returns "" or an error message.
///   do ##class(ETLWizard.Setup).SetDefaultView("executive")
ClassMethod SetDefaultView(view As %String) As %String
{
    Set view = $ZConvert($ZStrip(view, "<>W"), "L")
    If (view '= "technical") && (view '= "executive") {
        Return "ERROR: view must be technical or executive"
    }
    Set ^ETLWizard("defaultView") = view
    Return ""
}

/// The business scenario the Executive view narrates: the question being
/// answered, the sources in business language, and the tab labels. Held as
/// JSON in ^ETLWizard("scenario") so the story is configurable without editing
/// markup. Defaults describe the shipped sample data (DA-1).
ClassMethod Scenario() As %DynamicObject
{
    Set default = {
        // Two words on purpose: the masthead splits the title, rendering the first
        // word in ink and the rest in the teal italic. Generic to the discipline
        // rather than to this instance - and it drops "Demo", which is what a
        // business audience should not be reading off the wall (UX-4 / VD-1).
        "title": "Data Integrator",
        // The question is rendered as HTML, so an entity is fine here. The
        // sources and the note below are ESCAPED by the opening card, so they
        // must be plain ASCII - an "&mdash;" there would print literally.
        "question": "From scattered systems to one current platform.",
        // The three lines under the headline mirror the Executive tab labels
        // (Connect / Build / Predict), so the card previews the flow the room
        // is about to watch rather than listing inputs. Plain ASCII: the
        // opening card ESCAPES these, so an entity would print literally.
        "sources": ["Connect - reach data where it already lives, nothing copied",
                    "Build - describe the outcome; IRIS writes the pipeline and runs it",
                    "Predict - train models on the result, without leaving the platform"],
        "tabs": {"sources": "Connect", "etl": "Build", "ml": "Predict"},
        // The theme Executive view opens on, verified on the room's hardware
        // (IMPROVEMENTS_SPEC VD-4). Dark themes frequently wash out on
        // conference-room projectors, so light is the default until a
        // measurement on the actual projector says otherwise.
        "execTheme": "light",
        "eapNote": "InterSystems IRIS Data Platform"
    }
    Set raw = $Get(^ETLWizard("scenario"), "")
    If raw = "" {
        Return default
    }
    Try {
        Set custom = ##class(%DynamicObject).%FromJSON(raw)
        // merge over the defaults so a partial override cannot blank a field
        Set iter = custom.%GetIterator()
        While iter.%GetNext(.key, .value) {
            Do default.%Set(key, value)
        }
    } Catch {
        // malformed override: fall back rather than break the options endpoint
    }
    Return default
}

/// Replace the scenario. Pass a JSON string; keys omitted keep their defaults.
/// Returns "" or an error message.
ClassMethod SetScenario(json As %String) As %String
{
    Try {
        Do ##class(%DynamicObject).%FromJSON(json)
    } Catch ex {
        Return "ERROR: not valid JSON - " _ ex.DisplayString()
    }
    Set ^ETLWizard("scenario") = json
    Return ""
}

/// Turn approval enforcement ON (IMPROVEMENTS_SPEC SG-1).
///
/// The blocking approval policy in ETLWizard.Policy.Auth is fully implemented,
/// but ^ETLWizard("devMode") defaults to 1 and the dispatcher skips the
/// ETLWizard.Approve:USE check while it is set - so in the shipped
/// configuration nothing requires a human to approve anything, and the
/// governance claim is not true of the default instance.
///
/// The timeout defaults to 900s, not the policy's 300s: a five-minute timeout
/// expires while the presenter is answering a question from the audience.
ClassMethod EnableApprovals(timeoutSecs As %Integer = 900) As %Status
{
    Set sc = $$$OK
    Try {
        If timeoutSecs < 900 {
            Set timeoutSecs = 900
        }
        Set sc = ..CreateRoles()
        If $$$ISERR(sc) {
            Return sc
        }
        Set ^ETLWizard("devMode") = 0
        Set ^ETLWizard("approvalTimeoutSecs") = timeoutSecs
        Write "Approvals ENFORCED - devMode=0, approvalTimeoutSecs=", timeoutSecs, !
        Write "Resolving an approval now requires ETLWizard.Approve:USE (role ETLWizard_Approver).", !
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// Back to the unguarded development default. Never leave an instance here for
/// a demo that makes a governance claim.
ClassMethod DisableApprovals() As %Status
{
    Set ^ETLWizard("devMode") = 1
    Write "Approvals NOT enforced - devMode=1 (development default)", !
    Return $$$OK
}

/// Two accounts with genuinely different capability (IMPROVEMENTS_SPEC SG-4):
/// demo_analyst can drive the wizard but cannot resolve an approval;
/// demo_engineer can. Held in reserve for a security-led audience - this is an
/// answer to a question, not a step in the main flow.
ClassMethod CreateDemoUsers(password As %String = "") As %Status
{
    Set sc = $$$OK
    Try {
        If password = "" {
            Return $$$ERROR($$$GeneralError, "pass a password: do ##class(ETLWizard.Setup).CreateDemoUsers(""...."")")
        }
        New $NAMESPACE
        Set $NAMESPACE = "%SYS"
        For i = 1:1:2 {
            Set name = $Case(i, 1: "demo_analyst", 2: "demo_engineer")
            Set role = $Case(i, 1: "ETLWizard_User", 2: "ETLWizard_Approver")
            Set full = $Case(i, 1: "ETL Wizard demo analyst", 2: "ETL Wizard demo engineer")
            If ##class(Security.Users).Exists(name) {
                $$$ThrowOnError(##class(Security.Users).Delete(name))
            }
            // Only the ETLWizard role is granted here: whatever role the web
            // application itself is secured with has to be added on top, and
            // that differs between a Web Gateway front end and a private web
            // server. Add it with Security.Users.AddRoles() if login fails.
            $$$ThrowOnError(##class(Security.Users).Create(name, role, password, full))
            Write "user ", name, " -> ", role, !
        }
        Write "demo_analyst must be REFUSED when approving; demo_engineer must succeed.", !
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/* ===================================================================
   Demo preparation (IMPROVEMENTS_SPEC RR-1)

   POST /clear-all removes every pipeline and every wizard-built object, which
   is thorough - and destroys the demo preparation with it: the foreign servers
   and the mounted tables go too, and nothing puts them back. This does.
   =================================================================== */
/// Step 1 of 2: the gateway connection and the two foreign servers.
///
/// MUST be followed by MountDemoTables() IN A SEPARATE PROCESS. A foreign
/// server created in this process is not visible to the schema importer here:
/// the mount fails with "SQLCODE -237: Failed to craft query string for schema
/// import", and the identical statement succeeds from a fresh session. Waiting
/// does not help - it is process-local metadata, not a timing race. Verified on
/// build 125U. scripts/demo-reset.sh therefore makes two `iris session` calls.
ClassMethod PrepareServers(dropzone As %String = "/opt/irisbuild/dropzone") As %Status
{
    Set sc = $$$OK
    Try {
        Set sc = ..CreateGatewayConnection()
        If $$$ISERR(sc) {
            Return sc
        }
        Set runId = ..DemoRunId()
        Set ft = ##class(ETLWizard.Tools.ForeignTable).%New()
        Write ft.CreateForeignServer(runId, "SRC_POSTGRES", "JDBC", "pg_crm_connection"), !
        Write ft.CreateForeignServer(runId, "SRC_DROPZONE", "CSV", dropzone), !
        Write "Foreign servers ready. Now run MountDemoTables() in a NEW session.", !
    } Catch ex {
        Set sc = ex.AsStatus()
        Write "PrepareServers error: ", ex.DisplayString(), !
    }
    Return sc
}

/// Step 2 of 2: the four demo mounts. Run this in a session of its own, after
/// PrepareServers() - see the note there.
ClassMethod MountDemoTables() As %Status
{
    Set sc = $$$OK
    Try {
        Set runId = ..DemoRunId()
        Set ft = ##class(ETLWizard.Tools.ForeignTable).%New()

        // The demo's three source tables. Auto-import only: supplying an
        // explicit column list to CREATE FOREIGN TABLE over JDBC silently
        // yields zero rows.
        Do ..MountJdbc(ft, runId, "ext_customer", "SRC_POSTGRES", "sample.customer")
        Do ..MountJdbc(ft, runId, "ext_employee", "SRC_POSTGRES", "sample.employee")
        Do ..MountJdbc(ft, runId, "ext_orders", "SRC_POSTGRES", "sample.orders")

        // The daily-sales file, shaped to join against sample.customer.
        // `outcome` is the binary form of `status`, and it is what the
        // pre-trained demo model predicts. status has three values, two of
        // which (pending / cancelled) are generated by the same rule and are
        // therefore indistinguishable from each other by ANY model - training
        // on it caps accuracy below the majority-class baseline and makes the
        // ML segment argue against itself on screen.
        Set defs = "sale_ref VARCHAR(20), customer_id INTEGER, customer_name VARCHAR(200), " _
                   "region VARCHAR(40), sale_date VARCHAR(10), item VARCHAR(200), " _
                   "quantity INTEGER, unit_price NUMERIC(10,2), line_total NUMERIC(12,2), " _
                   "status VARCHAR(20), outcome VARCHAR(20)"
        Write ft.CreateForeignTableCsv(runId, "ext_daily_sales", "SRC_DROPZONE", "daily_sales.csv", defs, 1), !
        Write "Demo sources ready.", !
    } Catch ex {
        Set sc = ex.AsStatus()
        Write "MountDemoTables error: ", ex.DisplayString(), !
    }
    Return sc
}

/// A run to hang mount events off, on the same hidden pipeline the Data
/// Sources tab uses. Runs are cheap; one per preparation keeps the events for
/// that preparation on their own stream.
ClassMethod DemoRunId() As %String [ Internal ]
{
    Set name = "__data_sources__"
    Set pipelineId = ##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT TOP 1 ID FROM ETLWizard_Model.Pipeline WHERE Name = ? ORDER BY ID", name)
    If pipelineId = "" {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%New()
        Set pipeline.Name = name
        Set pipeline.Description = "Internal: owns tables mounted from the Data Sources tab"
        $$$ThrowOnError(pipeline.%Save())
    } Else {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(pipelineId)
    }
    Set run = ##class(ETLWizard.Model.Run).%New()
    Set run.Pipeline = pipeline
    // Trigger is a VALUELIST (wizard/schedule/manual); "sources" is not a member
    Set run.Trigger = "wizard"
    $$$ThrowOnError(run.%Save())
    Return run.%Id()
}

/// Mount one JDBC foreign table and report the outcome.
ClassMethod MountJdbc(ft As ETLWizard.Tools.ForeignTable, runId As %String, localName As %String, serverName As %String, remoteTable As %String) [ Internal ]
{
    Set res = ft.CreateForeignTableJdbc(runId, localName, serverName, remoteTable)
    If res [ "SQLCODE -237" {
        Set res = res _ " <- run PrepareServers() and MountDemoTables() in SEPARATE sessions"
    }
    Write res, !
}

/// Everything scripts/demo-verify.sh (RR-4) needs to assert, as one JSON line.
/// Written, not returned, so it can be read straight off a terminal session.
ClassMethod PrintDemoConfig()
{
    Set json = {}
    Set json.devMode = +$Get(^ETLWizard("devMode"), 1)
    Set json.approvalTimeoutSecs = +$Get(^ETLWizard("approvalTimeoutSecs"), ##class(ETLWizard.Policy.Auth).#DEFAULTTIMEOUT)
    Set json.defaultView = ..GetDefaultView()
    Set json.agentModel = ..GetAgentModel()
    // Governance facts the verify script asserts (IMPROVEMENTS_SPEC SG-1/SG-4).
    // appMatchRoles is reported because ":%All" on the web application hands
    // every request - authenticated or not - every privilege, which is what
    // made the old $SYSTEM.Security.Check() approval gate a no-op.
    Set json.appMatchRoles = ""
    Set json.approverAccounts = 0
    Try {
        New $NAMESPACE
        Set $NAMESPACE = "%SYS"
        If $$$ISOK(##class(Security.Applications).Get("/etlwizard/api", .app)) {
            Set json.appMatchRoles = $Get(app("MatchRoles"))
        }
        // LIKE, not %STARTSWITH: Security.Users.Roles is a length-prefixed
        // list, so the role name is never at offset 1 even for a single role.
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COUNT(*) FROM Security.Users WHERE Roles LIKE ? OR Roles LIKE ?",
            "%ETLWizard_Approver%", "%ETLWizard_Admin%")
        If rs.%Next() {
            Set json.approverAccounts = +rs.%GetData(1)
        }
    } Catch {
    }
    Write json.%ToJSON(), !
}

/// P0 exit-criteria check (spec §21): agent init + one tool round-trip.
/// Creates a scratch pipeline/run, asks the agent to record a node via the
/// catalog tool, and prints the resulting event log.
ClassMethod SmokeTest() As %Status
{
    Set sc = $$$OK
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%New()
        Set pipeline.Name = "smoketest-" _ $Translate($ZDateTime($ZTimeStamp, 3), " :", "-")
        $$$ThrowOnError(pipeline.%Save())

        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        Set run.Trigger = "manual"
        $$$ThrowOnError(run.%Save())
        Set runId = run.%Id()

        $$$ThrowOnError(##class(ETLWizard.Model.Event).Append(runId, "run.started", "", {"smoke": true}))

        Write "Run ", runId, " created. Invoking agent...", !
        Set sc = ##class(ETLWizard.Agent.Service).ChatTurn(runId,
            "Record a catalog node of kind 'source' named 'smoke_source', then emit a note saying hello.")
        If $$$ISERR(sc) {
            Write "Agent turn failed: ", $System.Status.GetErrorText(sc), !
        }

        Write !, "Event log:", !
        Set stmt = ##class(%SQL.Statement).%New()
        $$$ThrowOnError(stmt.%Prepare("SELECT Seq, Type, PayloadJson FROM ETLWizard_Model.Event WHERE Run = ? ORDER BY Seq"))
        Set rs = stmt.%Execute(runId)
        While rs.%Next() {
            Write rs.Seq, "  ", rs.Type, "  ", $Extract(rs.PayloadJson, 1, 120), !
        }
    } Catch ex {
        Set sc = ex.AsStatus()
        Write "SmokeTest error: ", $System.Status.GetErrorText(sc), !
    }
    Return sc
}

}
