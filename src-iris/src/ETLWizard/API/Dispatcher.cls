/// Wizard / pipeline / run REST endpoints (spec §15).
/// Served at /etlwizard/api (see Installer.cls).
Class ETLWizard.API.Dispatcher Extends %CSP.REST
{

Parameter HandleCorsRequest = 1;

Parameter CONVERTINPUTSTREAM = 1;

Parameter CHARSET = "utf-8";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/ping" Method="GET" Call="Ping"/>
  <Route Url="/sources" Method="GET" Call="GetSources"/>
  <Route Url="/wizard/session" Method="POST" Call="StartWizardSession"/>
  <Route Url="/runs/:runId/message" Method="POST" Call="PostMessage"/>
  <Route Url="/runs/:runId/approvals/:approvalId" Method="POST" Call="ResolveApproval"/>
  <Route Url="/runs/:runId/events" Method="GET" Call="GetEvents"/>
  <Route Url="/pipelines" Method="GET" Call="ListPipelines"/>
  <Route Url="/tables" Method="GET" Call="ListDataTables"/>
  <Route Url="/tables/drop" Method="POST" Call="DropDataTable"/>
  <Route Url="/clear-all" Method="POST" Call="ClearAll"/>
  <Route Url="/models" Method="GET" Call="ListModels"/>
  <Route Url="/models/select" Method="POST" Call="SelectModel"/>
  <Route Url="/sources/session" Method="POST" Call="SourcesSession"/>
  <Route Url="/mountable" Method="GET" Call="ListMountable"/>
  <Route Url="/ml/models" Method="GET" Call="MLList"/>
  <Route Url="/ml/columns" Method="POST" Call="MLColumns"/>
  <Route Url="/ml/create" Method="POST" Call="MLCreate"/>
  <Route Url="/ml/train" Method="POST" Call="MLTrain"/>
  <Route Url="/ml/status" Method="POST" Call="MLStatus"/>
  <Route Url="/ml/validate" Method="POST" Call="MLValidate"/>
  <Route Url="/ml/metrics" Method="POST" Call="MLMetrics"/>
  <Route Url="/ml/predict" Method="POST" Call="MLPredict"/>
  <Route Url="/ml/graph" Method="POST" Call="MLGraph"/>
  <Route Url="/ml/drop" Method="POST" Call="MLDrop"/>
  <Route Url="/ml/settings" Method="POST" Call="MLSettings"/>
  <Route Url="/ml/custom" Method="GET" Call="MLCustomList"/>
  <Route Url="/ml/custom/read" Method="POST" Call="MLCustomRead"/>
  <Route Url="/ml/custom/save" Method="POST" Call="MLCustomSave"/>
  <Route Url="/ml/custom/delete" Method="POST" Call="MLCustomDelete"/>
  <Route Url="/kg/candidates" Method="GET" Call="KGCandidates"/>
  <Route Url="/kg/profile" Method="POST" Call="KGProfile"/>
  <Route Url="/kg/start" Method="POST" Call="KGStart"/>
  <Route Url="/kg/corpus" Method="GET" Call="KGList"/>
  <Route Url="/kg/models" Method="GET" Call="KGModels"/>
  <Route Url="/kg/models/select" Method="POST" Call="KGSelectModel"/>
  <Route Url="/kg/search" Method="POST" Call="KGSearch"/>
  <Route Url="/kg/ask" Method="POST" Call="KGAsk"/>
  <Route Url="/kg/ask/:id" Method="GET" Call="KGAskPoll"/>
  <Route Url="/kg/corpus/:id" Method="GET" Call="KGStatus"/>
  <Route Url="/kg/corpus/:id/run" Method="POST" Call="KGRun"/>
  <Route Url="/kg/corpus/:id/cancel" Method="POST" Call="KGCancel"/>
  <Route Url="/kg/corpus/:id/drop" Method="POST" Call="KGDrop"/>
  <Route Url="/kg/corpus/:id/graph" Method="GET" Call="KGGraph"/>
  <Route Url="/mcp/publishable" Method="GET" Call="MCPPublishable"/>
  <Route Url="/mcp/propose" Method="POST" Call="MCPPropose"/>
  <Route Url="/mcp/publish" Method="POST" Call="MCPPublish"/>
  <Route Url="/mcp/published" Method="GET" Call="MCPPublished"/>
  <Route Url="/mcp/test" Method="POST" Call="MCPTest"/>
  <Route Url="/mcp/unpublish" Method="POST" Call="MCPUnpublish"/>
  <Route Url="/mcp/clear" Method="POST" Call="MCPClear"/>
  <Route Url="/pipeline/:id" Method="GET" Call="GetPipeline"/>
  <Route Url="/pipeline/:id" Method="DELETE" Call="DeletePipeline"/>
  <Route Url="/pipeline/:id/rename" Method="POST" Call="RenamePipeline"/>
  <Route Url="/pipeline/:id/graph" Method="GET" Call="GetGraph"/>
  <Route Url="/pipeline/:id/run" Method="POST" Call="RunPipeline"/>
  <Route Url="/pipeline/:id/runs" Method="GET" Call="GetRuns"/>
  <Route Url="/pipeline/:id/docs" Method="POST" Call="GeneratePipelineDocs"/>
  <Route Url="/pipeline/:id/production" Method="POST" Call="ProductionAction"/>
  <Route Url="/pipeline/:id/production" Method="GET" Call="GetProduction"/>
  <Route Url="/demo/customers" Method="GET" Call="DemoCustomers"/>
  <Route Url="/wizard/options" Method="GET" Call="WizardOptions"/>
  <Route Url="/gateway/create" Method="POST" Call="GatewayCreate"/>
  <Route Url="/wizard/:runId/connect" Method="POST" Call="WizardConnect"/>
  <Route Url="/wizard/:runId/discover" Method="POST" Call="WizardDiscover"/>
  <Route Url="/wizard/:runId/table-details" Method="POST" Call="WizardTableDetails"/>
  <Route Url="/wizard/:runId/mount" Method="POST" Call="WizardMount"/>
  <Route Url="/wizard/:runId/recommend" Method="POST" Call="WizardRecommend"/>
  <Route Url="/wizard/:runId/deploy" Method="POST" Call="WizardDeploy"/>
  <Route Url="/wizard/:runId/load" Method="POST" Call="WizardLoad"/>
  <Route Url="/wizard/:runId/transform-generate" Method="POST" Call="WizardTransformGenerate"/>
  <Route Url="/wizard/:runId/transform-preview" Method="POST" Call="WizardTransformPreview"/>
  <Route Url="/wizard/:runId/suggest-key" Method="POST" Call="WizardSuggestKey"/>
  <Route Url="/wizard/:runId/transform-deploy" Method="POST" Call="WizardTransformDeploy"/>
  <Route Url="/wizard/:runId/rest-probe" Method="POST" Call="WizardRestProbe"/>
  <Route Url="/wizard/:runId/rest-mount" Method="POST" Call="WizardRestMount"/>
  <Route Url="/wizard/:runId/index-recommend" Method="POST" Call="WizardIndexRecommend"/>
  <Route Url="/wizard/:runId/index-apply" Method="POST" Call="WizardIndexApply"/>
  <Route Url="/wizard/:runId/mounted" Method="GET" Call="WizardMounted"/>
  <Route Url="/wizard/:runId/upload" Method="POST" Call="WizardUpload"/>
  <Route Url="/wizard/:runId/bulk-deploy" Method="POST" Call="WizardBulkDeploy"/>
</Routes>
}

/// Write a %DynamicObject/%DynamicArray as the JSON response body.
ClassMethod WriteJSON(json As %DynamicAbstractObject, statusCode As %String = "200 OK") As %Status
{
    Set %response.ContentType = "application/json"
    Set %response.Status = statusCode
    Write json.%ToJSON()
    Return $$$OK
}

/// Error responses carry a business-readable first line where the failure is
/// one we recognise, and ALWAYS carry the raw text (IMPROVEMENTS_SPEC EH-3).
///
/// The frontend renders `error` as the headline and `detail` behind a
/// "details" disclosure. Diagnostic information is never discarded: when
/// nothing matches, `error` is the raw text exactly as before, so no existing
/// consumer changes behaviour.
ClassMethod WriteError(message As %String, statusCode As %String = "500 Internal Server Error") As %Status
{
    Set plain = ..ExplainError(message)
    If plain = "" {
        Return ..WriteJSON({"error": (message)}, statusCode)
    }
    Return ..WriteJSON({"error": (plain), "detail": (message)}, statusCode)
}

/// Map a recurring failure onto one plain sentence, or "" when unrecognised.
/// Each entry here is a failure this project has actually produced.
///
/// Matching is on the SQLCODE first, deliberately. This instance emits
/// LOCALISED error text - a missing foreign server reports "Servidor externo
/// ... nao encontrado", not "Foreign server ... not found" - so English
/// substring matching silently stops working the moment the locale differs.
/// SQLCODEs, class names, privilege names and driver names do not translate.
/// The English phrases below are a secondary net for messages this project
/// composes itself, which are always English.
ClassMethod ExplainError(raw As %String) As %String [ Internal ]
{
    Set t = $ZConvert(raw, "L")
    Set code = ..SqlCodeOf(t)

    // --- language-independent: SQLCODE ---------------------------------
    If code = -245 {
        Return "That data source is not registered on this instance. Mount it from the Data Sources tab, or pick a source that is already configured."
    }
    If code = -237 {
        Return "The data source was created moments ago and is not usable yet from this process. Try the mount again - it succeeds on the second attempt."
    }
    If code = -201 {
        Return "Something with that name already exists. Choose a different name, or drop the existing object first."
    }
    If code = -119 {
        Return "Rows with that key are already in the target. An append-only load re-inserts every row each run: a recomputed result wants Merge/Upsert or Full reload instead."
    }
    If code = -400 {
        Return "The database rejected that statement. If a schema name was involved, note that any name beginning ETLWIZARD conflicts with the code package - the layer schemas are ETLW_LANDING, ETLW_STAGING and ETLW_TARGET."
    }
    If code = -30 {
        Return "That table or view does not exist. It may have been dropped, or the name may be misspelled."
    }
    If code = -29 {
        Return "A column named in the statement does not exist on that table. Re-run Preview to pick up the current column list."
    }

    // --- language-independent: names that never translate ---------------
    If (t [ "%gateway_object") || (t [ "gateway_object:use") {
        Return "This account is not allowed to reach external databases. It needs the %Gateway_Object:USE privilege (role ETLWizard_Admin)."
    }
    If (t [ "etlwizard.approve") || (t [ "lacks etlwizard.approve") {
        Return "This account cannot approve changes. Approvals require the ETLWizard_Approver role - sign in as the approver, or ask them to resolve the card."
    }
    If (t [ "no suitable driver") || (t [ "classnotfound") {
        Return "The JDBC driver for that database is not installed. Drop the driver jar into src-iris/jdbc and give its path on the connection."
    }

    // --- English only: messages this project composes itself -------------
    If t [ "invalid local table name" {
        Return "That name is not usable as a table name. Use letters, digits and underscores only - no spaces, dots or punctuation."
    }
    If (t [ "connection refused") || (t [ "unknownhost") || (t [ "could not connect") || (t [ "communications link failure") {
        Return "The source database did not answer. Check it is running and that the connection's host, port and credentials are right."
    }
    If (t [ "external language server") || (t [ "java gateway") || (t [ "jvm") || (t [ "gateway is not running") {
        Return "The Java gateway that serves JDBC connections is not available. It starts on demand - retry, and if it keeps failing check the External Language Server in the Management Portal."
    }
    If (t [ "timed out") || (t [ "timeout") {
        Return "The operation took longer than the gateway allows. It is probably still running on the server - check the run history in a moment."
    }
    Return ""
}

/// The SQLCODE carried by an error message, or "" if it carries none.
/// Handles both shapes this project produces:
///   "SQLCODE -237: Failed to craft..."      (composed by our own tools)
///   "ERRO #5540: SQLCODE: -245  Mensagem:"  (raised by IRIS, any locale)
/// The lowercase token "sqlcode" is the same in both, and the digits after it
/// do not translate.
ClassMethod SqlCodeOf(lowerText As %String) As %String [ Internal ]
{
    If lowerText '[ "sqlcode" {
        Return ""
    }
    Set tail = $Piece(lowerText, "sqlcode", 2)
    // skip past a ":" and any spaces, then read "-<digits>"
    Set tail = $ZStrip(tail, "<W")
    If $Extract(tail) = ":" {
        Set tail = $ZStrip($Extract(tail, 2, *), "<W")
    }
    If $Extract(tail) '= "-" {
        Return ""
    }
    Set digits = ""
    For i = 2:1:$Length(tail) {
        Set ch = $Extract(tail, i)
        If (ch < "0") || (ch > "9") {
            Quit
        }
        Set digits = digits _ ch
    }
    If digits = "" {
        Return ""
    }
    Return -digits
}

/// Parse the JSON request body; returns "" on parse failure.
ClassMethod ReadBody() As %DynamicObject
{
    Set body = ""
    Try {
        If $IsObject(%request.Content) {
            Set body = ##class(%DynamicObject).%FromJSON(%request.Content)
        }
    } Catch {
        Set body = ""
    }
    Return body
}

/// Modification time of the served index.html, used by the page to notice that
/// the UI it is running is no longer the UI on disk.
ClassMethod UiVersion() As %String [ Internal ]
{
    Try {
        Return ##class(%File).GetFileDateModified("/opt/irisbuild/frontend/index.html")
    } Catch {
        Return ""
    }
}

ClassMethod Ping() As %Status
{
    Return ..WriteJSON({"status":"ok", "namespace":($Namespace), "version":($ZVersion),
                        "uiVersion":(..UiVersion())})
}

/// Allowed source types + capability metadata (spec §3.1)
ClassMethod GetSources() As %Status
{
    Set json = {"sources": [
        {"type":"PostgreSQL", "accessMethod":"ForeignTable", "wrapper":"JDBC", "mvp":"MVP-1"},
        {"type":"CSV",        "accessMethod":"ForeignTable", "wrapper":"FILE", "mvp":"MVP-1"},
        {"type":"JDBC",       "accessMethod":"ForeignTable", "wrapper":"JDBC", "mvp":"MVP-2"},
        {"type":"IRIS",       "accessMethod":"ForeignTable", "wrapper":"JDBC", "mvp":"MVP-2"},
        {"type":"REST",       "accessMethod":"GeneratedClient", "wrapper":"", "mvp":"MVP-2"}
    ]}
    Return ..WriteJSON(json)
}

/// Start a wizard run: creates Pipeline + Run, appends run.started (spec §15).
ClassMethod StartWizardSession() As %Status
{
    Set sc = $$$OK
    Try {
        Set body = ..ReadBody()
        Set name = ""
        Set description = ""
        Set owner = ""
        If $IsObject(body) {
            Set name = body.name
            Set description = body.description
            Set owner = body.owner
        }
        If name = "" {
            Set name = "pipeline-" _ $Translate($ZDateTime($ZTimeStamp, 3), " :", "-")
        }

        Set pipeline = ##class(ETLWizard.Model.Pipeline).%New()
        Set pipeline.Name = name
        Set pipeline.Description = description
        Set pipeline.Owner = owner
        Set sc = pipeline.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc), "400 Bad Request")
        }

        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        Set run.Trigger = "wizard"
        Set sc = run.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }

        Set sc = ##class(ETLWizard.Model.Event).Append(run.%Id(), "run.started", "",
            {"pipelineId": (pipeline.%Id()), "pipelineName": (name), "trigger": "wizard"})
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }

        Return ..WriteJSON({"pipelineId": (pipeline.%Id()), "runId": (run.%Id())}, "201 Created")
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// User wizard input / chat turn — invokes the agent (spec §15).
ClassMethod PostMessage(runId As %String) As %Status
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return ..WriteError("run not found: " _ runId, "404 Not Found")
        }
        Set body = ..ReadBody()
        Set text = ""
        If $IsObject(body) {
            Set text = body.text
        }
        If text = "" {
            Return ..WriteError("body must be {""text"": ""...""}", "400 Bad Request")
        }
        Set sc = ##class(ETLWizard.Agent.Service).ChatTurn(runId, text)
        If $$$ISERR(sc) {
            // Error is already recorded as a run.error event; report it to the caller too
            Return ..WriteJSON({"ok": false, "error": ($System.Status.GetErrorText(sc))})
        }
        Return ..WriteJSON({"ok": true})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Approve/reject a pending destructive tool call (spec §10.3, §15).
ClassMethod ResolveApproval(runId As %String, approvalId As %String) As %Status
{
    Try {
        Set approval = ##class(ETLWizard.Model.PendingApproval).%OpenId(approvalId)
        If '$IsObject(approval) {
            Return ..WriteError("approval not found: " _ approvalId, "404 Not Found")
        }
        If approval.Run.%Id() '= runId {
            Return ..WriteError("approval does not belong to run " _ runId, "400 Bad Request")
        }
        If approval.Status '= "pending" {
            Return ..WriteError("approval already resolved: " _ approval.Status, "409 Conflict")
        }
        // RBAC (spec §16.1): resolving approvals requires the ETLWizard_Approver
        // role unless dev mode is on (^ETLWizard("devMode") = 1, the shipped
        // default).
        //
        // This asks Policy.Auth.CanApprove(), NOT $SYSTEM.Security.Check() —
        // the privilege check is defeated by the web application's
        // MatchRoles=":%All", which hands every request %All. See the doc
        // comment on CanApprove for the verified failure.
        If '+$Get(^ETLWizard("devMode"), 1) {
            If '##class(ETLWizard.Policy.Auth).CanApprove(.why) {
                Return ..WriteError("Approval refused: " _ why _ ".", "403 Forbidden")
            }
        }
        Set body = ..ReadBody()
        Set approve = 0
        Set comment = ""
        If $IsObject(body) {
            Set approve = +body.approve
            Set comment = body.comment
        }
        Set approval.Status = $Select(approve: "approved", 1: "rejected")
        Set approval.Comment = comment
        Set approval.ResolvedBy = $Username
        Set approval.ResolvedAt = $ZDateTime($ZTimeStamp, 3, , 3)
        Set sc = approval.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set sc = ##class(ETLWizard.Model.Event).Append(runId, "approval.resolved", "",
            {"approvalId": (approvalId), "status": (approval.Status), "comment": (comment)})
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Return ..WriteJSON(approval.ToJSON())
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Event backfill / SSE fallback: GET /runs/:id/events?after=seq (spec §14.1, §15)
ClassMethod GetEvents(runId As %String) As %Status
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return ..WriteError("run not found: " _ runId, "404 Not Found")
        }
        Set after = +$Get(%request.Data("after", 1), 0)
        // `agent.delta` is the answer being typed; the `agent.note` that follows
        // is the same answer, whole. This endpoint is the RELIABLE catch-up
        // path, so it serves the record and not the typing - a client replaying
        // here would otherwise render the answer twice. The WS hub applies the
        // same rule to its replay pass. ?deltas=1 for anything inspecting the
        // raw log.
        Set withDeltas = +$Get(%request.Data("deltas", 1), 0)
        Set events = []
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Event WHERE Run = ? AND Seq > ? " _
            $Select(withDeltas: "", 1: "AND Type <> 'agent.delta' ") _ "ORDER BY Seq")
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set rs = stmt.%Execute(runId, after)
        If rs.%SQLCODE < 0 {
            Return ..WriteError("SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message)
        }
        While rs.%Next() {
            Set ev = ##class(ETLWizard.Model.Event).%OpenId(rs.ID)
            If '$IsObject(ev) {
                Continue
            }
            Do events.%Push(ev.ToJSON())
        }
        Return ..WriteJSON({"runId": (runId), "events": (events)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// The schemas the wizard creates data in. Nothing outside this list can be
/// listed or dropped through the API, whatever a caller asks for.
ClassMethod DataSchemas() As %List [ Internal ]
{
    Return $ListBuild("ETLW_LANDING", "ETLW_STAGING", "ETLW_TARGET", "ETLWIZARD")
}

/// Every table the wizard built: the landing/staging/target tables it owns
/// outright, plus the mounted sources in ETLWIZARD (foreign tables and
/// ODBC-linked views). Row counts only for local tables — counting a foreign
/// table would hit the remote source just to draw a dropdown.
ClassMethod ListDataTables() As %Status
{
    Try {
        // which ETLWIZARD names are foreign tables, so each row can say what it is
        Set foreign = ","
        Set fr = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.FOREIGN_TABLES WHERE TABLE_SCHEMA = 'ETLWIZARD'")
        While fr.%Next() {
            Set foreign = foreign _ $ZConvert(fr.%GetData(1), "U") _ ","
        }
        Set list = []
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES " _
            "WHERE TABLE_SCHEMA IN ('ETLW_LANDING','ETLW_STAGING','ETLW_TARGET','ETLWIZARD') " _
            "ORDER BY TABLE_SCHEMA, TABLE_NAME")
        While rs.%Next() {
            Set schema = rs.%GetData(1), name = rs.%GetData(2), type = rs.%GetData(3)
            Set isForeign = (foreign [ ("," _ $ZConvert(name, "U") _ ","))
            Set kind = $Case(schema,
                "ETLW_LANDING": "landing",
                "ETLW_STAGING": "staging",
                "ETLW_TARGET": "target",
                : $Select(isForeign: "foreign table", $ZConvert(type, "U") = "VIEW": "linked view", 1: "table"))
            Set rows = ""
            If schema '= "ETLWIZARD" {
                Set rows = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ schema _ "." _ name)
                If $Extract(rows, 1, 5) = "ERROR" {
                    Set rows = ""
                }
            }
            Do list.%Push({"schema": (schema), "name": (name), "kind": (kind),
                           "rows": (rows), "full": (schema _ "." _ name)})
        }
        Return ..WriteJSON({"tables": (list)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Drop one table the wizard built. body {"schema": "...", "name": "..."}.
/// The DDL depends on what the object actually is — a foreign table, an
/// ODBC-linked view (whose generated link class goes too), or a plain table.
ClassMethod DropDataTable() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set schema = $ZConvert($ZStrip(body.%Get("schema", ""), "<>W"), "U")
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        If $ListFind(..DataSchemas(), schema) = 0 {
            Return ..WriteError("refusing to drop outside the wizard's own schemas", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
            Return ..WriteError("invalid table name", "400 Bad Request")
        }
        Set type = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            schema, name)
        If ($Extract(type, 1, 5) = "ERROR") || (type = "") {
            Return ..WriteError(schema _ "." _ name _ " not found", "404 Not Found")
        }
        Set err = ..DropOne(schema, name, ($ZConvert(type, "U") = "VIEW"), .kind)
        If err '= "" {
            Return ..WriteError(err)
        }
        Return ..WriteJSON({"dropped": (schema _ "." _ name), "kind": (kind)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Every pipeline, newest first — the header's pipeline picker.
ClassMethod ListPipelines() As %Status
{
    Try {
        Set list = []
        // the hidden Data Sources pipeline is plumbing, not something the user
        // deploys or runs — keep it out of the picker
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT ID, Name, Status, CreatedAt, CASE WHEN MetadataJson IS NULL THEN 0 ELSE 1 END AS deployed " _
            "FROM ETLWizard_Model.Pipeline WHERE Name <> '" _ ..#SOURCESPIPELINE _ "' ORDER BY ID DESC")
        While rs.%Next() {
            Do list.%Push({"id": (rs.%GetData(1)), "name": (rs.%GetData(2)), "status": (rs.%GetData(3)),
                           "createdAt": (rs.%GetData(4)), "deployed": (+rs.%GetData(5))})
        }
        Return ..WriteJSON({"pipelines": (list)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Name of the hidden Pipeline that owns Data Sources mounts.
///
/// The Data Sources tab has no pipeline of its own — mounting a table there is
/// a standing act, not part of building one ETL. But every mount endpoint
/// records a Node against a Run, and a Run needs a Pipeline. Rather than make
/// the mount path pipeline-optional (it is used by five different source
/// types), Data Sources gets one reusable hidden Pipeline. ListPipelines
/// filters it out so it never appears in the picker.
Parameter SOURCESPIPELINE = "__data_sources__";

/// Return a Run bound to the shared Data Sources pipeline, creating both on
/// first use. Lets the Data Sources tab call the existing /wizard/:runId/*
/// mount endpoints unchanged.
ClassMethod SourcesSession() As %Status
{
    Try {
        Set name = ..#SOURCESPIPELINE
        Set pipelineId = ""
        Set stmt = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt.%Prepare("SELECT TOP 1 ID FROM ETLWizard_Model.Pipeline WHERE Name = ? ORDER BY ID")) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Set pipelineId = rs.%GetData(1)
            }
        }
        If pipelineId = "" {
            Set pipeline = ##class(ETLWizard.Model.Pipeline).%New()
            Set pipeline.Name = name
            Set pipeline.Description = "Internal: owns tables mounted from the Data Sources tab"
            Set sc = pipeline.%Save()
            If $$$ISERR(sc) {
                Return ..WriteError($System.Status.GetErrorText(sc))
            }
            Set pipelineId = pipeline.%Id()
        } Else {
            Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(pipelineId)
        }
        // One Run per browser session is fine — Runs are cheap and keeping them
        // separate keeps each mount's events on its own stream.
        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        // Trigger is a VALUELIST (wizard/schedule/manual) — "sources" is not a
        // member, and Run rejects it at save time
        Set run.Trigger = "wizard"
        Set sc = run.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Return ..WriteJSON({"runId": (run.%Id()), "pipelineId": (pipelineId)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Every ETLWIZARD table with its columns — the same payload as
/// /wizard/:runId/mounted but with no run, so the ETL Interop tab can offer
/// source tables before any pipeline exists. Nothing is pre-ticked.
ClassMethod ListMountable() As %Status
{
    Try {
        Set tables = []
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLWIZARD' ORDER BY TABLE_NAME")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute()
            While rs.%Next() {
                Set nm = rs.%GetData(1)
                Set cols = []
                Set stmt2 = ##class(%SQL.Statement).%New()
                If $$$ISOK(stmt2.%Prepare("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")) {
                    Set rs2 = stmt2.%Execute(nm)
                    While rs2.%Next() {
                        Do cols.%Push(rs2.%GetData(1))
                    }
                }
                Do tables.%Push({"name": (nm), "own": 0, "columns": (cols)})
            }
        }
        Return ..WriteJSON({"foreignTables": (tables)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Rename an ETL. The name is chosen on the table-selection step, but the
/// pipeline is created earlier (on the first table tick, so profiling has a run
/// to write events to) — so a name typed after that has to be applied here.
/// Safe before deploy: staging/target tables and production hosts are all
/// derived from the name at transform-deploy time, not at creation.
ClassMethod RenamePipeline(id As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        Set pipeline.Name = name
        Set sc = pipeline.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc), "400 Bad Request")
        }
        Return ..WriteJSON({"ok": 1, "id": (id), "name": (name)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// ---- ML Models tab (ml-models-tab-plan.md) --------------------------------
/// All reads come from INFORMATION_SCHEMA.ML_* via ETLWizard.Tools.MLModel;
/// nothing about a model is stored by this application.
ClassMethod MLList() As %Status
{
    Try {
        Return ..WriteJSON({"models": (##class(ETLWizard.Tools.MLModel).ListModels())})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Columns of a table, with date/time ones flagged so the frontend can offer
/// only valid time columns for a time-series model.
ClassMethod MLColumns() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        If table = "" {
            Return ..WriteError("table is required", "400 Bad Request")
        }
        Return ..WriteJSON({"columns": (##class(ETLWizard.Tools.MLModel).TableColumns(table))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLCreate() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        Set withCols = $ZStrip(body.%Get("withColumns", ""), "<>W")
        Set timeCol = $ZStrip(body.%Get("timeColumn", ""), "<>W")
        Set using = body.%Get("using")
        // targets is a list: PREDICTING takes one column, so several columns
        // means several models - see MLModel.CreateBatch
        Set targets = body.%Get("targets")
        If '$IsObject(targets) {
            Set single = $ZStrip(body.%Get("target", ""), "<>W")
            Set targets = []
            If single '= "" {
                Do targets.%Push(single)
            }
        }
        If (name = "") || (table = "") || (targets.%Size() = 0) {
            Return ..WriteError("name, table and at least one target column are required", "400 Bad Request")
        }
        Set results = ##class(ETLWizard.Tools.MLModel).CreateBatch(name, table, targets, withCols, timeCol, using)
        // report every column, not just the first failure, so a partial batch is
        // visible rather than looking like a total loss
        Set made = 0, firstError = ""
        Set it = results.%GetIterator()
        While it.%GetNext(.i, .row) {
            If row.ok {
                Set made = made + 1
            } ElseIf firstError = "" {
                Set firstError = row.error
            }
        }
        If made = 0 {
            Return ..WriteError($Select(firstError '= "": firstError, 1: "no models were created"))
        }
        Return ..WriteJSON({"ok": 1, "created": (made), "models": (results)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Starts training and returns immediately — see MLModel.TrainAsync for why
/// this must not be synchronous.
ClassMethod MLTrain() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.MLModel).TrainAsync(name, table, body.%Get("using"), .error) {
            Return ..WriteError(error)
        }
        Return ..WriteJSON({"ok": 1, "started": 1, "name": (name)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLStatus() As %Status
{
    Try {
        Set body = ..ReadBody()
        Set name = $Select($IsObject(body): $ZStrip(body.%Get("name", ""), "<>W"), 1: "")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Return ..WriteJSON(##class(ETLWizard.Tools.MLModel).Status(name))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLValidate() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        If (name = "") || (table = "") {
            Return ..WriteError("name and table are required", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.MLModel).Validate(name, table, .error, .excluded) {
            Return ..WriteError(error)
        }
        // excluded rows are worth saying out loud: the metrics are computed over
        // fewer rows than the table holds, and silently scoring a smaller set is
        // exactly the kind of thing that makes a number impossible to reconcile
        Return ..WriteJSON({"ok": 1, "excluded": (+$Get(excluded)),
                            "metrics": (##class(ETLWizard.Tools.MLModel).Metrics(name))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLMetrics() As %Status
{
    Try {
        Set body = ..ReadBody()
        Set name = $Select($IsObject(body): $ZStrip(body.%Get("name", ""), "<>W"), 1: "")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Return ..WriteJSON({"metrics": (##class(ETLWizard.Tools.MLModel).Metrics(name))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLPredict() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        Set forClass = $ZStrip(body.%Get("forClass", ""), "<>W")
        Set maxRows = +body.%Get("maxRows", 10)
        If (name = "") || (table = "") {
            Return ..WriteError("name and table are required", "400 Bad Request")
        }
        Set result = ##class(ETLWizard.Tools.MLModel).Predict(name, table, forClass, maxRows, .error)
        If error '= "" {
            Return ..WriteError(error)
        }
        Return ..WriteJSON(result)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLGraph() As %Status
{
    Try {
        Set body = ..ReadBody()
        Set name = $Select($IsObject(body): $ZStrip(body.%Get("name", ""), "<>W"), 1: "")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Return ..WriteJSON(##class(ETLWizard.Tools.MLModel).Graph(name))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// The USING settings stored on a model definition, so the train step can show
/// what a run will use instead of asking for it a second time.
ClassMethod MLSettings() As %Status
{
    Try {
        Set body = ..ReadBody()
        Set name = $Select($IsObject(body): $ZStrip(body.%Get("name", ""), "<>W"), 1: "")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Return ..WriteJSON({"name": (name),
                            "settings": (##class(ETLWizard.Tools.MLModel).DefinitionSettings(name))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLCustomList() As %Status
{
    Try {
        Return ..WriteJSON({"models": (##class(ETLWizard.Tools.MLModel).ListCustomModels())})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Source of one installed custom model, so the UI can show and edit it.
ClassMethod MLCustomRead() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set slug = $ZStrip(body.%Get("slug", ""), "<>W")
        Set kind = $ZStrip(body.%Get("kind", "classification"), "<>W")
        If slug = "" {
            Return ..WriteError("slug is required", "400 Bad Request")
        }
        Return ..WriteJSON({"slug": (slug), "kind": (kind),
                            "source": (##class(ETLWizard.Tools.MLModel).ReadCustomModel(slug, kind))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Installs the model and hands back the USING settings that name it, so the
/// frontend can go straight on to creating a model with it selected.
ClassMethod MLCustomSave() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set slug = $ZStrip(body.%Get("slug", body.%Get("file", "")), "<>W")
        Set kind = $ZStrip(body.%Get("kind", "classification"), "<>W")
        Set source = body.%Get("source", "")
        If (slug = "") || (source = "") {
            Return ..WriteError("slug and source are required", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.MLModel).SaveCustomModel(slug, kind, source, .error, .modelName) {
            Return ..WriteError(error)
        }
        Return ..WriteJSON({
            "ok": 1,
            "slug": (slug),
            "kind": (kind),
            "modelName": (modelName),
            "using": (##class(ETLWizard.Tools.MLModel).CustomUsing(kind, slug, modelName))
        })
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLCustomDelete() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set slug = $ZStrip(body.%Get("slug", body.%Get("file", "")), "<>W")
        Set kind = $ZStrip(body.%Get("kind", "classification"), "<>W")
        If slug = "" {
            Return ..WriteError("slug is required", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.MLModel).DeleteCustomModel(slug, kind, .error) {
            Return ..WriteError(error)
        }
        Return ..WriteJSON({"ok": 1})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod MLDrop() As %Status
{
    Try {
        Set body = ..ReadBody()
        Set name = $Select($IsObject(body): $ZStrip(body.%Get("name", ""), "<>W"), 1: "")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        If '##class(ETLWizard.Tools.MLModel).Drop(name, .error) {
            Return ..WriteError(error)
        }
        Return ..WriteJSON({"ok": 1, "name": (name)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Models offered by the masthead picker, with the active one flagged. The
/// list is a server-side allowlist (ETLWizard.Setup.AgentModels) — it is not
/// "whatever Ollama has pulled".
ClassMethod ListModels() As %Status
{
    Try {
        Set active = ##class(ETLWizard.Setup).GetAgentModel()
        If active = "" {
            Set active = ##class(ETLWizard.Setup).#DEFAULTAGENTMODEL
        }
        Set list = []
        Set models = ##class(ETLWizard.Setup).AgentModels()
        Set iter = models.%GetIterator()
        While iter.%GetNext(, .entry) {
            Do list.%Push({"id": (entry.id), "label": (entry.label), "active": (''(entry.id = active))})
        }
        Return ..WriteJSON({"models": (list), "active": (active)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Switch both agent profiles to the posted model id: {"model": "..."}.
/// Takes effect on the next agent call — nothing is cached in the session.
ClassMethod SelectModel() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set id = $ZStrip(body.%Get("model", ""), "<>W")
        If id = "" {
            Return ..WriteError("model is required")
        }
        If '##class(ETLWizard.Setup).SetAgentModel(id, .error) {
            Return ..WriteError(error)
        }
        Return ..WriteJSON({"ok": 1, "active": (id)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Delete a pipeline: its graph (nodes/edges), runs and events, watermark, and
/// its items in the shared production. The DATA it built — foreign tables and
/// the ETLW_LANDING/STAGING/TARGET tables — is deliberately left alone; drop
/// those yourself if you want them gone.
ClassMethod DeletePipeline(id As %String) As %Status
{
    Try {
        Set err = ..PurgePipeline(id, .info)
        If err '= "" {
            Return ..WriteError(err, $Select(err [ "not found": "404 Not Found", 1: "500 Internal Server Error"))
        }
        Set info.note = "tables and foreign tables built by this pipeline were kept"
        Return ..WriteJSON(info)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Delete one pipeline's definition: production items, runs, events, graph and
/// watermark. Returns "" and fills .info, or an error message. The data it
/// built is not touched — that is DropDataTable's job.
ClassMethod PurgePipeline(id As %String, Output info As %DynamicObject) As %String [ Internal ]
{
    Set info = {}
    Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
    If '$IsObject(pipeline) {
        Return "pipeline not found: " _ id
    }
    Set name = pipeline.Name
    Set removed = []

    // production items first: stop scheduling something whose plan is going away
    Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(id)
    If $IsObject(prod) {
        Set items = ##class(ETLWizard.Tools.Production).RemovePipelineItems(id)
        If items '= "" {
            Do removed.%Push({"productionItems": (items)})
        }
        Do ##class(ETLWizard.Model.Production).%DeleteId(prod.%Id())
    }

    // events hang off runs, so clear them per run before deleting the runs
    Set rs = ##class(%SQL.Statement).%ExecDirect(,
        "SELECT ID FROM ETLWizard_Model.Run WHERE Pipeline = ?", id)
    Set runs = 0, events = 0
    While rs.%Next() {
        Set runId = rs.%GetData(1)
        Set ev = ##class(%SQL.Statement).%ExecDirect(,
            "DELETE FROM ETLWizard_Model.Event WHERE Run = ?", runId)
        Set events = events + ev.%ROWCOUNT
        Set runs = runs + 1
    }
    Do ##class(%SQL.Statement).%ExecDirect(, "DELETE FROM ETLWizard_Model.Run WHERE Pipeline = ?", id)
    Do ##class(%SQL.Statement).%ExecDirect(, "DELETE FROM ETLWizard_Model.Edge WHERE Pipeline = ?", id)
    Do ##class(%SQL.Statement).%ExecDirect(, "DELETE FROM ETLWizard_Model.Node WHERE Pipeline = ?", id)
    Do ##class(%SQL.Statement).%ExecDirect(, "DELETE FROM ETLWizard_Model.Watermark WHERE Pipeline = ?", id)

    Set sc = ##class(ETLWizard.Model.Pipeline).%DeleteId(id)
    If $$$ISERR(sc) {
        Return $System.Status.GetErrorText(sc)
    }
    Set info = {"deleted": (id), "name": (name), "runs": (runs), "events": (events), "removed": (removed)}
    Return ""
}

/// Wipe the workspace: every pipeline definition AND every table the wizard
/// built. Foreign servers and SQL Gateway connections are left in place (they
/// are connection setup, not wizard output), as is the sample-data feed in the
/// production, which belongs to no pipeline.
ClassMethod ClearAll() As %Status
{
    Try {
        Set pipelines = 0, runs = 0, dropped = [], failed = []
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM ETLWizard_Model.Pipeline")
        Set ids = ""
        While rs.%Next() {
            Set ids = ids _ $ListBuild(rs.%GetData(1))
        }
        For i = 1:1:$ListLength(ids) {
            Set err = ..PurgePipeline($List(ids, i), .info)
            If err = "" {
                Set pipelines = pipelines + 1
                Set runs = runs + info.runs
            }
        }
        // views before the tables they might sit on, foreign tables before the
        // servers they belong to
        For pass = 1:1:2 {
            Set tr = ##class(%SQL.Statement).%ExecDirect(,
                "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES " _
                "WHERE TABLE_SCHEMA IN ('ETLW_LANDING','ETLW_STAGING','ETLW_TARGET','ETLWIZARD') " _
                "ORDER BY TABLE_SCHEMA, TABLE_NAME")
            While tr.%Next() {
                Set schema = tr.%GetData(1), name = tr.%GetData(2), type = tr.%GetData(3)
                Set isView = ($ZConvert(type, "U") = "VIEW")
                If (pass = 1) && 'isView {
                    Continue
                }
                If (pass = 2) && isView {
                    Continue
                }
                If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
                    Continue
                }
                Set err = ..DropOne(schema, name, isView, .kind)
                If err = "" {
                    Do dropped.%Push(schema _ "." _ name)
                } Else {
                    Do failed.%Push({"table": (schema _ "." _ name), "error": (err)})
                }
            }
        }
        // Every published MCP tool reads one of the tables just dropped, so
        // leaving them published would leave an endpoint whose every call
        // fails. Unpublish rather than serve broken tools.
        Set mcp = ##class(ETLWizard.MCP.Publisher).Clear()
        // Knowledge bases are built FROM those tables, so they go with them.
        Set kgCleared = 0
        Try {
            Set kgCleared = ##class(ETLWizard.KG.Ingest).DropAll()
        } Catch {
        }
        Return ..WriteJSON({"pipelines": (pipelines), "runs": (runs),
                            "tablesDropped": (dropped.%Size()), "dropped": (dropped), "failed": (failed),
                            "mcpCleared": (mcp.%Get("cleared", 0)), "kgCleared": (kgCleared),
                            "note": "SQL Gateway connections, foreign servers and the sample-data feed were kept"})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Drop one wizard-owned object with the DDL its kind needs. Returns "" or an
/// error message; .kind reports what it turned out to be.
ClassMethod DropOne(schema As %String, name As %String, isView As %Boolean, Output kind As %String) As %String [ Internal ]
{
    Set isForeign = +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.FOREIGN_TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
        schema, name)
    If isForeign {
        Set kind = "foreign table"
        Return ##class(ETLWizard.Tools.Util).RunDDL("DROP FOREIGN TABLE " _ schema _ "." _ name)
    }
    If isView {
        // an ODBC mount is a view over ETLWizard.Link.<name>: drop both
        Set kind = "linked view"
        Set err = ##class(ETLWizard.Tools.Util).RunDDL("DROP VIEW " _ schema _ "." _ name)
        If err = "" {
            Do ##class(%SYSTEM.OBJ).Delete("ETLWizard.Link." _ $Translate(name, "_", ""), "-d")
        }
        Return err
    }
    Set kind = "table"
    Return ##class(ETLWizard.Tools.Util).RunDDL("DROP TABLE " _ schema _ "." _ name)
}

ClassMethod GetPipeline(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        Set json = pipeline.ToJSON()
        // Additive (IMPROVEMENTS_SPEC UX-3): freshness and target facts the
        // results panel needs. Purely extra keys - no existing consumer of this
        // response changes shape. Each block is guarded on its own: a pipeline
        // with no watermark, or whose target has been dropped by hand, must
        // still return the pipeline rather than a 500.
        Do ..AddWatermark(id, json)
        Do ..AddTargetFacts(json)
        Do ..AddIntegrationTiming(json)
        Return ..WriteJSON(json)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// json.watermark = Watermark.ToJSON() for this pipeline, if one exists.
ClassMethod AddWatermark(id As %String, json As %DynamicObject) [ Internal ]
{
    Try {
        Set wm = ##class(ETLWizard.Model.Watermark).PipelineIdxOpen(id)
        If $IsObject(wm) {
            Set json.watermark = wm.ToJSON()
        }
    } Catch {
        // no watermark, or the index is not resolvable - omit the field rather
        // than substitute a value the panel would display as if it were real
    }
}

/// json.target = {table, rowCount, quarantineTable, quarantineRows, sample}.
/// Reads the target named in the pipeline's own metadata (meta.layers.target);
/// omits any field it cannot actually read.
/// End-to-end integration time, measured the way the production actually ran:
/// from the Extract business service creating the first message of a session to
/// the Load business operation finishing the last one.
///
/// One session = one pass of the pipeline, and it carries exactly four message
/// headers: Extract->Orchestrate, Orchestrate->Load, and the two responses back.
/// So the two ends are unambiguous:
///   start = TimeCreated   of the message whose SOURCE is <base>_Extract
///   end   = TimeProcessed of the message whose TARGET is <base>_Load
/// Anything wider (min/max over the whole session) would fold the response
/// legs back in and report a longer run than the data movement took.
///
/// Reports the most recent completed pass plus an average over the last ten, so
/// a single slow run reads as a single slow run rather than as the new normal.
/// Omitted entirely when the pipeline has never run through a production - an
/// absent figure is honest, a zero would not be.
ClassMethod AddIntegrationTiming(json As %DynamicObject) [ Internal ]
{
    Try {
        Set table = ""
        If $IsObject(json.%Get("metadata", "")), $IsObject(json.metadata.%Get("layers", "")) {
            Set table = json.metadata.layers.%Get("target", "")
        }
        If table = "" {
            Return
        }
        Set base = $Piece(table, ".", 2)
        If '##class(ETLWizard.Tools.Util).ValidIdent(base) {
            Return
        }
        Set extractItem = base _ "_Extract", loadItem = base _ "_Load"
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP 10 e.SessionId, e.TimeCreated, l.TimeProcessed " _
            "FROM Ens.MessageHeader e, Ens.MessageHeader l " _
            "WHERE l.SessionId = e.SessionId AND e.SourceConfigName = ? AND l.TargetConfigName = ? " _
            "ORDER BY e.SessionId DESC")
        If $$$ISERR(sc) {
            Return
        }
        Set rs = stmt.%Execute(extractItem, loadItem)
        Set recent = [], total = 0, n = 0
        Set latestId = "", latestStart = "", latestEnd = "", latestSecs = ""
        While rs.%Next() {
            Set sid = rs.%GetData(1), startAt = rs.%GetData(2), endAt = rs.%GetData(3)
            // TimeProcessed is empty while a pass is still in flight, and stays
            // empty on one that failed before the Load completed. Neither has an
            // end-to-end time to report.
            If (startAt = "") || (endAt = "") {
                Continue
            }
            Set secs = ..ElapsedSeconds(startAt, endAt)
            If secs < 0 {
                Continue
            }
            Do recent.%Push({"sessionId": (sid), "startedAt": (startAt),
                             "finishedAt": (endAt), "seconds": (secs)})
            Set total = total + secs, n = n + 1
            If latestId = "" {
                Set latestId = sid, latestStart = startAt, latestEnd = endAt, latestSecs = secs
            }
        }
        If n = 0 {
            Return
        }
        Set json.integration = {
            "seconds": (latestSecs),
            "startedAt": (latestStart),
            "finishedAt": (latestEnd),
            "sessionId": (latestId),
            "extractItem": (extractItem),
            "loadItem": (loadItem),
            "sampled": (n),
            "averageSeconds": ($Number(total / n, 3)),
            "recent": (recent)
        }
    } Catch {
        // no production, no Ens tables, or a header shape we do not recognise:
        // omit the field rather than show a duration that is not measured
    }
}

/// Seconds between two %TimeStamp values, to the millisecond.
/// $ZDateTimeH(.., 3, 1, 3) yields "days,seconds.fff", which subtracts cleanly
/// across a midnight boundary where comparing the time parts alone would not.
ClassMethod ElapsedSeconds(startAt As %String, endAt As %String) As %Numeric [ Internal ]
{
    Try {
        Set h1 = $ZDateTimeH(startAt, 3, 1, 3), h2 = $ZDateTimeH(endAt, 3, 1, 3)
        Set secs = (($Piece(h2, ",", 1) - $Piece(h1, ",", 1)) * 86400) +
                   ($Piece(h2, ",", 2) - $Piece(h1, ",", 2))
        Return $Number(secs, 3)
    } Catch {
        Return -1
    }
}

ClassMethod AddTargetFacts(json As %DynamicObject) [ Internal ]
{
    Try {
        Set table = ""
        If $IsObject(json.%Get("metadata", "")), $IsObject(json.metadata.%Get("layers", "")) {
            Set table = json.metadata.layers.%Get("target", "")
        }
        If table = "" {
            Return
        }
        Set schema = $Piece(table, ".", 1)
        Set base = $Piece(table, ".", 2)
        If '##class(ETLWizard.Tools.Util).ValidIdent(base) {
            Return
        }
        Set target = {"table": (table)}
        Set exists = +##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            schema, base)
        If 'exists {
            Set json.target = target
            Return
        }
        Set target.rowCount = +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ table)
        // Rejected rows are reported even when zero: a visible 0 is a stronger
        // governance statement than an absent field. Absent means "no
        // quarantine table exists", which is a different thing and says so.
        Set qTable = "ETLW_AUDIT." _ base _ "_quarantine"
        Set qExists = +##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLW_AUDIT' AND TABLE_NAME = ?",
            base _ "_quarantine")
        If qExists {
            Set target.quarantineTable = qTable
            Set target.quarantineRows = +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ qTable)
        }
        // top rows of the target, so the panel can show the business result
        // itself rather than only counts
        Set columns = [], rows = []
        // %SelectMode 1 (ODBC), not the default 0 (logical). A %TimeStamp column
        // read in logical mode comes back as 1154705814002363000, and that is
        // what the panel would put on screen next to the business result. The
        // same distinction bit the watermark, which was being PERSISTED in
        // logical form.
        Set stmt = ##class(%SQL.Statement).%New()
        Set stmt.%SelectMode = 1
        Set rs = ""
        If $$$ISOK(stmt.%Prepare("SELECT TOP 5 * FROM " _ table)) {
            Set rs = stmt.%Execute()
        }
        If $IsObject(rs) {
            Set meta = rs.%GetMetadata()
            For c = 1:1:meta.columnCount {
                Do columns.%Push(meta.columns.GetAt(c).colName)
            }
            While rs.%Next() {
                Set row = []
                For c = 1:1:meta.columnCount {
                    Do row.%Push(rs.%GetData(c))
                }
                Do rows.%Push(row)
            }
            Set target.sample = {"columns": (columns), "rows": (rows)}
        }
        Set json.target = target
    } Catch {
        // a dropped or unreadable target must not fail the pipeline read
    }
}

/// Generate the pipeline's markdown documentation and hand it back to the
/// caller (IMPROVEMENTS_SPEC BS-4). Catalog.GenerateDocs() already writes the
/// full document — metadata, watermark, production class, and every node with
/// its exact DDL — to /opt/irisbuild/docs; it is unchanged here. This reads the
/// file back so the browser can offer it as a download, and reports the
/// server-side path for the leave-behind copy.
ClassMethod GeneratePipelineDocs(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        // the docs generator hangs off a run, so use the pipeline's latest
        Set runId = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT TOP 1 ID FROM ETLWizard_Model.Run WHERE Pipeline = ? ORDER BY ID DESC", id)
        If runId = "" {
            Return ..WriteError("pipeline has no runs yet - nothing to document", "409 Conflict")
        }
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Set res = cat.GenerateDocs(runId)
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Set file = "/opt/irisbuild/docs/" _ $Translate(pipeline.Name, " /\", "___") _ ".md"
        Set markdown = ""
        Try {
            Set stream = ##class(%Stream.FileCharacter).%New()
            $$$ThrowOnError(stream.LinkToFile(file))
            While 'stream.AtEnd {
                Set markdown = markdown _ stream.Read(32000)
            }
        } Catch {
            // the document is on the server either way; say so without the body
        }
        Return ..WriteJSON({"pipeline": (pipeline.Name), "file": (file),
                            "message": (res), "markdown": (markdown)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Manual execution of a deployed pipeline (spec §15) — no LLM involved.
/// Creates the Run, JOBs the executor, and returns the runId immediately so
/// the caller can subscribe to the live canvas before execution proceeds.
ClassMethod RunPipeline(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        If pipeline.MetadataJson = "" {
            Return ..WriteError("pipeline has no deployed metadata - complete the wizard first", "409 Conflict")
        }
        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        Set run.Trigger = "manual"
        Set sc = run.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Job ##class(ETLWizard.Runtime.Executor).Execute(id, run.%Id())
        Return ..WriteJSON({"pipelineId": (id), "runId": (run.%Id()), "status": "started"}, "202 Accepted")
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Production lifecycle without the agent (spec v2.2 step 13):
/// body {"action": "generate" | "start" | "stop" | "runnow", "callIntervalSecs": 300}.
/// Uses the same tool methods the agent calls, on a fresh manual Run.
ClassMethod ProductionAction(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        Set body = ..ReadBody()
        Set action = ""
        Set interval = 300
        Set pool = 1
        If $IsObject(body) {
            Set action = $ZConvert(body.%Get("action", ""), "L")
            Set interval = +body.%Get("callIntervalSecs", 300)
            Set pool = +body.%Get("poolSize", 1)
        }
        If '$ListFind($ListBuild("generate", "start", "stop", "runnow"), action) {
            Return ..WriteError("action must be generate | start | stop | runnow", "400 Bad Request")
        }
        // Anchor tool calls on a run for the event stream
        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        Set run.Trigger = "manual"
        Set sc = run.%Save()
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set tool = ##class(ETLWizard.Tools.Production).%New()
        If action = "generate" {
            Set result = tool.GenerateProduction(run.%Id(), interval, "", pool)
        } ElseIf action = "start" {
            Set result = tool.ApplyProduction(run.%Id())
        } ElseIf action = "stop" {
            Set result = tool.StopProduction(run.%Id())
        } Else {
            Set result = tool.RunProductionNow(run.%Id())
        }
        Set ok = $Extract(result, 1, 5) '= "ERROR"
        // Finalize the anchor run so it doesn't linger as "running"
        Set run.Status = $Select(ok: "succeeded", 1: "failed")
        Set run.FinishedAt = $ZDateTime($ZTimeStamp, 3, , 3)
        Do run.%Save()
        Return ..WriteJSON({"ok": (ok), "runId": (run.%Id()), "result": (result)},
            $Select(ok: "200 OK", 1: "500 Internal Server Error"))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Production status for a pipeline (spec v2.2 §12.1).
ClassMethod GetProduction(id As %String) As %Status
{
    Try {
        Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(id)
        If '$IsObject(prod) {
            Return ..WriteError("no production generated for pipeline " _ id, "404 Not Found")
        }
        Set json = prod.ToJSON()
        Set json.actuallyRunning = ##class(Ens.Director).IsProductionRunning(prod.ProductionClass)
        Return ..WriteJSON(json)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Wrap a tool-method result string: ERROR -> 500, JSON -> object, else message.
ClassMethod ToolResult(res As %String) As %Status [ Internal ]
{
    If $Extract(res, 1, 5) = "ERROR" {
        Return ..WriteError(res)
    }
    Try {
        Return ..WriteJSON(##class(%DynamicAbstractObject).%FromJSON(res))
    } Catch {
        Return ..WriteJSON({"message": (res)})
    }
}

/// Dropdown data for the form wizard (spec §15 "callable outside the agent"):
/// source types, SQL Gateway connections, dropzone CSV files, strategies.
ClassMethod WizardOptions() As %Status
{
    Try {
        Set connections = []
        Set stmt = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt.%Prepare("SELECT Connection_Name AS Name, URL FROM %Library.sys_SQLConnection WHERE isJDBC = 1 ORDER BY Connection_Name")) {
            Set rs = stmt.%Execute()
            While rs.%Next() {
                Do connections.%Push({"name": (rs.%GetData(1)), "url": (rs.%GetData(2))})
            }
        }
        Set odbcConnections = []
        Set stmt0 = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt0.%Prepare("SELECT Connection_Name AS Name, DSN FROM %Library.sys_SQLConnection WHERE isJDBC = 0 ORDER BY Connection_Name")) {
            Set rs0 = stmt0.%Execute()
            While rs0.%Next() {
                Do odbcConnections.%Push({"name": (rs0.%GetData(1)), "dsn": (rs0.%GetData(2))})
            }
        }
        Set csvFiles = []
        Set frs = ##class(%ResultSet).%New("%File:FileSet")
        If $$$ISOK(frs.Execute("/opt/irisbuild/dropzone", "*.csv")) {
            While frs.Next() {
                Do csvFiles.%Push(frs.Get("ItemName"))
            }
        }
        // Foreign servers are what discovery actually reads — a server wraps a
        // connection, and its name is unrelated to the connection's. Offering
        // connections as "sources" produces
        // "Foreign server 'ETLWIZARD.<conn>' not found", so the Data Sources
        // picker is built from these instead. PARAMETERS carries
        // CONNECTION="..." for JDBC and HOST="..." for CSV; surface it so the
        // user can tell two servers on the same database apart.
        Set foreignServers = []
        Set stmtFs = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmtFs.%Prepare("SELECT SERVER_NAME, FOREIGN_DATA_WRAPPER, PARAMETERS FROM INFORMATION_SCHEMA.FOREIGN_SERVERS WHERE SERVER_SCHEMA = 'ETLWIZARD' ORDER BY SERVER_NAME")) {
            Set rsFs = stmtFs.%Execute()
            While rsFs.%Next() {
                Set wrapper = rsFs.%GetData(2)
                Set params = rsFs.%GetData(3)
                Set mode = $Select(wrapper [ "Csv": "csv", 1: "jdbc")
                // pull CONNECTION="x" / HOST="x" out of the parameter blob
                Set via = ""
                Set key = $Select(mode = "csv": "HOST=""", 1: "CONNECTION=""")
                If params [ key {
                    Set via = $Piece($Piece(params, key, 2), """", 1)
                }
                Do foreignServers.%Push({"name": (rsFs.%GetData(1)), "mode": (mode), "via": (via)})
            }
        }
        Return ..WriteJSON({
            "foreignServers": (foreignServers),
            // Audience presentation (IMPROVEMENTS_SPEC §1.1). The frontend
            // already fetches this response exactly once, so carrying the view
            // default and the scenario here introduces no new request.
            "defaultView": (##class(ETLWizard.Setup).GetDefaultView()),
            "scenario": (##class(ETLWizard.Setup).Scenario()),
            // MySQL and SQLServer were removed: their presets pointed at driver
            // jars that are not shipped, so picking them failed at connect time
            // with a driver-not-found error. "JDBC" is the generic entry - the
            // whole JDBC path is vendor-neutral, so any database with an ANSI
            // information_schema works by typing its driver/URL/jar.
            "sources": [
                {"type": "PostgreSQL", "mode": "jdbc"},
                {"type": "IRIS", "mode": "jdbc"},
                {"type": "JDBC", "mode": "jdbc"},
                {"type": "CSV", "mode": "csv"}
            ],
            "gatewayConnections": (connections),
            "odbcConnections": (odbcConnections),
            "csvFiles": (csvFiles),
            "csvDirectory": "/opt/irisbuild/dropzone",
            "strategies": [
                {"id": "full", "label": "Full Load", "executor": 1, "needsWatermark": 0},
                {"id": "incremental_timestamp", "label": "Incremental Timestamp + Merge/Upsert", "executor": 1, "needsWatermark": 1},
                {"id": "incremental_numeric", "label": "Incremental Numeric Watermark + Merge/Upsert", "executor": 1, "needsWatermark": 1},
                {"id": "append_only", "label": "Append-Only", "executor": 0, "needsWatermark": 1},
                {"id": "snapshot", "label": "Snapshot", "executor": 0, "needsWatermark": 0},
                {"id": "csv_arrival", "label": "CSV Incremental by File Arrival", "executor": 0, "needsWatermark": 0}
            ],
            "historyPolicies": ["latest_state", "snapshot", "append_audit"]})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Create the foreign server for the chosen source (form step 3 — the click
/// is the human approval; no LLM involved).
ClassMethod WizardConnect(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set ft = ##class(ETLWizard.Tools.ForeignTable).%New()
        Set wrapper = $Select($ZConvert(body.mode, "L") = "csv": "CSV", 1: "JDBC")
        Set targetRef = $Select(wrapper = "CSV": body.%Get("directory", "/opt/irisbuild/dropzone"), 1: body.connection)
        Set res = ft.CreateForeignServer(runId, body.serverName, wrapper, targetRef)
        If $Extract(res, 1, 5) '= "ERROR" {
            Set disc = ##class(ETLWizard.Tools.SourceDiscovery).%New()
            If wrapper = "JDBC" {
                Set test = disc.TestConnection(body.serverName)
                If $Extract(test, 1, 5) = "ERROR" {
                    Return ..WriteError("server created but connection test failed: " _ test)
                }
            }
        }
        Return ..ToolResult(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// List what can be mounted: remote schemas/tables (JDBC), the ODBC catalog
/// (schemas first, then the tables of the chosen schema), or dropzone files (CSV).
ClassMethod WizardDiscover(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If $ZConvert(body.mode, "L") = "csv" {
            Set csv = ##class(ETLWizard.Tools.CsvProfiling).%New()
            // blank => the dropzone default
            Do csv.SetDirectory(body.%Get("directory", ""))
            Return ..ToolResult(csv.ListCsvFiles())
        }
        Set disc = ##class(ETLWizard.Tools.SourceDiscovery).%New()
        If $ZConvert(body.mode, "L") = "odbc" {
            // no foreign server exists for ODBC — walk the driver's catalog.
            // schemaName absent => level 1 (schemas), present => level 2 (tables)
            Set schema = body.%Get("schemaName", "")
            If schema = "" {
                Return ..ToolResult(disc.DiscoverOdbcSchemas(body.connection))
            }
            Return ..ToolResult(disc.DiscoverOdbcTables(body.connection, schema))
        }
        Return ..ToolResult(disc.DiscoverSchema(body.serverName))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Details for one chosen table/file: columns, PK, watermark candidates,
/// row estimate + sample (JDBC) or inferred column types (CSV).
ClassMethod WizardTableDetails(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If $ZConvert(body.mode, "L") = "csv" {
            Set csv = ##class(ETLWizard.Tools.CsvProfiling).%New()
            Do csv.SetDirectory(body.%Get("directory", ""))
            Set inspect = csv.InspectCsv(body.fileName, 3)
            Set infer = csv.InferCsvTypes(body.fileName)
            Set out = {}
            Try {
                Set out.inspect = ##class(%DynamicObject).%FromJSON(inspect)
            } Catch {
                Set out.inspect = inspect
            }
            Try {
                Set out.types = ##class(%DynamicObject).%FromJSON(infer)
            } Catch {
                Set out.types = infer
            }
            Return ..WriteJSON(out)
        }
        Set disc = ##class(ETLWizard.Tools.SourceDiscovery).%New()
        Set out = {}
        Set out.columns = ..ParseOr(disc.DiscoverColumns(body.serverName, body.schemaName, body.tableName))
        Set out.pk = ..ParseOr(disc.DiscoverPrimaryKey(body.serverName, body.schemaName, body.tableName))
        Set out.watermarks = ..ParseOr(disc.DetectWatermarks(body.serverName, body.schemaName, body.tableName))
        Set out.rowCount = ..ParseOr(disc.EstimateRows(body.serverName, body.schemaName, body.tableName))
        Set out.sample = ..ParseOr(disc.SampleRows(body.serverName, body.schemaName, body.tableName, 5))
        Return ..WriteJSON(out)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Turn a request body's {schedule:{days:[...],times:[...]}} into an Ens schedule
/// spec (or "" when no schedule / interval mode). Returns "ERROR: ..." on a bad
/// schedule.
ClassMethod ScheduleSpecFromBody(body As %DynamicObject) As %String [ Internal ]
{
    If '$IsObject(body.schedule) {
        Return ""
    }
    Set days = "", times = ""
    If $IsObject(body.schedule.days) {
        Set it = body.schedule.days.%GetIterator()
        While it.%GetNext(.i, .v) { Set days = days _ $Select(days = "": "", 1: ",") _ v }
    }
    If $IsObject(body.schedule.times) {
        Set it2 = body.schedule.times.%GetIterator()
        While it2.%GetNext(.j, .w) { Set times = times _ $Select(times = "": "", 1: ",") _ w }
    }
    If times = "" {
        Return ""
    }
    Return ##class(ETLWizard.Tools.Production).BuildSchedule(days, times)
}

ClassMethod ParseOr(res As %String) [ Internal ]
{
    Try {
        Return ##class(%DynamicAbstractObject).%FromJSON(res)
    } Catch {
        Return res
    }
}

/// Mount the foreign table (form step 5).
ClassMethod WizardMount(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set ft = ##class(ETLWizard.Tools.ForeignTable).%New()
        If $ZConvert(body.mode, "L") = "csv" {
            Set defs = body.%Get("columnDefs", "")
            If defs = "" {
                Set csv = ##class(ETLWizard.Tools.CsvProfiling).%New()
                Set infer = ..ParseOr(csv.InferCsvTypes(body.fileName))
                If $IsObject(infer) {
                    Set defs = infer.columnDefs
                }
            }
            Set res = ft.CreateForeignTableCsv(runId, body.localName, body.serverName, body.fileName, defs, 1)
        } ElseIf $ZConvert(body.mode, "L") = "odbc" {
            Set schema = body.%Get("schemaName", "public")
            Set pk = body.%Get("primaryKeys", "")
            If pk = "" {
                // the picker sends whatever SQLPrimaryKeys reported; fall back to
                // asking the driver again rather than failing the mount outright
                Set discPk = ##class(ETLWizard.Tools.SourceDiscovery).%New()
                Set conn = discPk.OdbcConnect(body.connection, .cerr)
                If cerr = "" {
                    Set pk = discPk.OdbcPrimaryKeyList(conn, schema, body.tableName)
                    Do conn.Disconnect()
                }
            }
            Set res = ft.CreateLinkedTableOdbc(runId, body.localName, body.connection,
                schema, body.tableName, pk)
        } Else {
            Set res = ft.CreateForeignTableJdbc(runId, body.localName, body.serverName, body.schemaName _ "." _ body.tableName)
        }
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Set disc = ##class(ETLWizard.Tools.SourceDiscovery).%New()
        Return ..WriteJSON({"message": (res), "test": (..ParseOr(disc.TestForeignTable(body.localName, 3)))})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Scored strategy recommendation from structured facts (form step 6).
ClassMethod WizardRecommend(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set strat = ##class(ETLWizard.Tools.Strategy).%New()
        Return ..ToolResult(strat.RecommendStrategy(body.%ToJSON()))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Create layers + persist the §12.2 metadata as Deployed (form step 7).
ClassMethod WizardDeploy(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Set res = ld.CreateLayerTables(runId, body.baseName, body.foreignTable, body.pkColumns)
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Set strategy = body.%Get("strategy", "incremental_timestamp")
        Set loadType = $Case(strategy, "full": "full", "snapshot": "snapshot",
            "append_only": "append", "csv_arrival": "csv_arrival", : "incremental")
        Set meta = {}
        Set meta.pipelineName = body.%Get("pipelineName", body.baseName)
        Set meta.source = {"type": (body.%Get("sourceType", "JDBC")), "foreignTable": ("ETLWIZARD." _ body.foreignTable)}
        If body.%Get("watermarkColumn", "") '= "" {
            Set meta.source.watermark = {"type": ($Select(strategy = "incremental_numeric": "numeric", 1: "timestamp")), "column": (body.watermarkColumn)}
        }
        // csv_arrival re-runs remount a per-file foreign table, so the executor
        // and production need the server + column definitions in the metadata.
        If body.%Get("csvServer", "") '= "" {
            Set meta.source.csvServer = body.csvServer
        }
        If body.%Get("columnDefs", "") '= "" {
            Set meta.source.columnDefs = body.columnDefs
        }
        Set meta.loadStrategy = {"type": (loadType), "mode": ($Select(loadType = "incremental": "merge", 1: loadType)), "historyPolicy": (body.%Get("historyPolicy", "latest_state"))}
        Set meta.layers = {"landing": ("ETLW_LANDING." _ body.baseName _ "_raw"),
                           "staging": ("ETLW_STAGING." _ body.baseName _ "_delta"),
                           "target": ("ETLW_TARGET." _ body.baseName)}
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Set res2 = cat.SetPipelineMetadata(runId, meta.%ToJSON(), "Deployed")
        If $Extract(res2, 1, 5) = "ERROR" {
            Return ..WriteError(res2)
        }
        // Every pipeline joins the shared production ETLWizard.Prod.Main as its
        // own item group (<base>_Extract/_Orchestrate/_Load), scheduled on the
        // poll interval. All strategies are executor-supported now.
        Set prodTool = ##class(ETLWizard.Tools.Production).%New()
        Set prodMsg = prodTool.GenerateProduction(runId, +body.%Get("pollSeconds", 300), "", +body.%Get("poolSize", 1))
        If $Extract(prodMsg, 1, 5) '= "ERROR" {
            Set applyMsg = prodTool.ApplyProduction(runId)
            If $Extract(applyMsg, 1, 5) = "ERROR" {
                Set prodMsg = prodMsg _ " / " _ applyMsg
            }
        }
        Return ..WriteJSON({"layers": (res), "metadata": (res2), "production": (prodMsg),
            "executorSupported": 1})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Execute the chosen strategy once (form step 8 "Run initial load") —
/// dispatches to the same gated tool methods, human click = approval.
ClassMethod WizardLoad(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Set strategy = body.%Get("strategy", "incremental_timestamp")
        If strategy = "full" {
            Set res = ld.RunFullLoad(runId, body.baseName, body.foreignTable)
        } ElseIf strategy = "snapshot" {
            Set res = ld.RunSnapshotLoad(runId, body.baseName, body.foreignTable)
        } ElseIf strategy = "append_only" {
            Set res = ld.RunAppendOnlyLoad(runId, body.baseName, body.foreignTable, body.%Get("watermarkColumn", ""))
        } ElseIf strategy = "csv_arrival" {
            Set res = ld.RunCsvArrivalLoad(runId, body.baseName, body.csvServerName, body.columnDefs)
        } Else {
            Set res = ld.RunIncrementalLoad(runId, body.baseName, body.foreignTable, body.watermarkColumn)
        }
        Return ..ToolResult(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Create a SQL Gateway connection (JDBC or ODBC) from the wizard, then smoke
/// test it so the user gets immediate feedback. Credentials are stored in the
/// IRIS gateway registry and are never returned to the client.
ClassMethod GatewayCreate() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = body.%Get("name", "")
        Set err = ##class(ETLWizard.Setup).CreateGatewayConnectionAny(
            name, body.%Get("kind", "jdbc"), body.%Get("url", ""), body.%Get("dsn", ""),
            body.%Get("user", ""), body.%Get("password", ""),
            body.%Get("driver", ""), body.%Get("classpath", ""))
        If err '= "" {
            Return ..WriteError(err, "400 Bad Request")
        }
        // Smoke test: mount a throwaway foreign server over it and SELECT 1
        Set probe = "etlw_probe_" _ $Increment(^ETLWizard.ProbeSeq)
        Set tested = 0
        Set testMsg = "created (not tested)"
        Set ddlErr = ##class(ETLWizard.Tools.Util).RunDDL(
            "CREATE FOREIGN SERVER ETLWIZARD." _ probe _ " FOREIGN DATA WRAPPER JDBC CONNECTION '" _ name _ "'")
        If ddlErr = "" {
            Set res = ##class(ETLWizard.Tools.Util).Through(probe, "SELECT 1", 1)
            If $Extract(res, 1, 5) = "ERROR" {
                Set testMsg = "created, but the connection test failed: " _ $Extract(res, 1, 200)
            } Else {
                Set tested = 1
                Set testMsg = "created and tested OK"
            }
            Do ##class(ETLWizard.Tools.Util).RunDDL("DROP FOREIGN SERVER ETLWIZARD." _ probe)
        }
        Return ..WriteJSON({"name": (name), "tested": (tested), "message": (testMsg)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// List the foreign tables mounted so far in this run's pipeline — so the
/// transform builder can show what's available to join.
ClassMethod WizardMounted(runId As %String) As %Status
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return ..WriteError("run not found: " _ runId, "404 Not Found")
        }
        // this pipeline's own mounts (pre-selected in the picker)
        Set own = ""
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT Name FROM ETLWizard_Model.Node WHERE Pipeline = ? AND Kind = 'foreign_table' ORDER BY ID")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(run.Pipeline.%Id())
            While rs.%Next() {
                Set own = own _ $ListBuild($Piece(rs.%GetData(1), ".", *))
            }
        }
        // every ETLWIZARD table is joinable, so offer them all with their columns
        Set tables = []
        Set stmt2 = ##class(%SQL.Statement).%New()
        Set sc = stmt2.%Prepare("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLWIZARD' ORDER BY TABLE_NAME")
        If $$$ISOK(sc) {
            Set rs2 = stmt2.%Execute()
            While rs2.%Next() {
                Set nm = rs2.%GetData(1)
                Set cols = []
                Set stmt3 = ##class(%SQL.Statement).%New()
                If $$$ISOK(stmt3.%Prepare("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")) {
                    Set rs3 = stmt3.%Execute(nm)
                    While rs3.%Next() {
                        Do cols.%Push(rs3.%GetData(1))
                    }
                }
                Do tables.%Push({"name": (nm), "own": ($Select($ListFind(own, nm) > 0: 1, 1: 0)), "columns": (cols)})
            }
        }
        Return ..WriteJSON({"foreignTables": (tables)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Generate/refine the transform SELECT from business logic in plain words,
/// using the local LLM profile. Pass currentSql to ADJUST the existing SQL —
/// that is what makes multi-prompt refinement work.
ClassMethod WizardTransformGenerate(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set instruction = body.%Get("instruction", "")
        If $ZStrip(instruction, "<>W") = "" {
            Return ..WriteError("describe what the transformation should do", "400 Bad Request")
        }
        // JOB it: a local model can outlast the gateway timeout. The result
        // arrives on the event stream as `sqlgen.result`.
        Job ##class(ETLWizard.Agent.SqlGen).GenerateAsync(runId, instruction,
            body.%Get("currentSql", ""), body.%Get("tables", ""))
        Return ..WriteJSON({"status": "generating"}, "202 Accepted")
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Preview a custom transform SELECT (columns + sample), deterministic.
ClassMethod WizardTransformPreview(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Return ..ToolResult(ld.PreviewTransform(body.sql, +body.%Get("maxRows", 10)))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Suggest a primary key for the transform result (strategy step). Deterministic
/// for aggregations (GROUP BY grain) and id-columns; only touches the LLM when
/// neither applies. Returns {primaryKey, reason, source}.
ClassMethod WizardSuggestKey(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set json = ##class(ETLWizard.Agent.SqlGen).SuggestKey(runId, body.%Get("sql", ""), body.%Get("tables", ""))
        Return ..WriteJSON(##class(%DynamicObject).%FromJSON(json))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Build + deploy + first-load a custom-transform pipeline (multi-source join,
/// cleansing, derivation, aggregation, filtering — all in SQL). Adds it to the
/// shared production like any other pipeline.
ClassMethod WizardTransformDeploy(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set base = body.baseName
        Set tsql = body.sql
        Set pk = $ZStrip(body.%Get("pkColumns", ""), "<>W")
        Set wantStrategy = body.%Get("strategy", "incremental")
        // Append-only accumulates rows, so a unique primary key on the target
        // guarantees a collision on the second run. Refuse up front rather than
        // deploy a production that fails on every poll.
        If (pk '= "") && ((wantStrategy = "append") || (wantStrategy = "append_only")) {
            Return ..WriteError("Append-only keeps adding rows, so a primary key (" _ pk _
                ") will clash on the next run. Either choose Merge/Upsert (keeps one row per key) " _
                "or Full reload, or clear the primary key to make this a true append log.",
                "400 Bad Request")
        }
        // comma-separated source list, so the graph gets a node per source table
        Set sourcesCsv = ""
        If $IsObject(body.sources) {
            Set it = body.sources.%GetIterator()
            While it.%GetNext(.si, .sv) {
                Set sourcesCsv = sourcesCsv _ $Select(sourcesCsv = "": "", 1: ",") _ sv
            }
        }
        // strategy: merge (has PK) | full | append
        Set strategy = body.%Get("strategy", "incremental")
        Set loadType = $Case(strategy, "full": "full", "append_only": "append", "append": "append",
            "snapshot": "snapshot", : "incremental")
        // load-config detail for the graph box (only the values that are set)
        Set wm = $ZStrip(body.%Get("watermarkColumn", ""), "<>W")
        Set poll = +body.%Get("pollSeconds", 0)
        Set stratLabel = $Case(loadType, "full": "Full reload", "append": "Append-only",
            "snapshot": "Snapshot", : "Merge/Upsert")
        Set cfg = ""
        If pk '= "" { Set cfg = cfg _ "Primary key: " _ pk }
        Set cfg = cfg _ $Select(cfg = "": "", 1: "|") _ "Strategy: " _ stratLabel
        If wm '= "" { Set cfg = cfg _ "|Watermark: " _ wm }
        If poll { Set cfg = cfg _ "|Call interval: " _ poll _ "s" }
        If +body.%Get("poolSize", 1) > 1 { Set cfg = cfg _ "|Pool size: " _ +body.%Get("poolSize", 1) }
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Set res = ld.DeployTransform(runId, base, tsql, pk, sourcesCsv, cfg)
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Set meta = {}
        Set meta.pipelineName = body.%Get("pipelineName", base)
        Set meta.transform = {"sql": (tsql)}
        If $IsObject(body.sources) {
            Set meta.transform.sources = body.sources
        }
        If body.%Get("watermarkColumn", "") '= "" {
            Set meta.transform.watermarkColumn = body.watermarkColumn
        }
        // The load path reads the key back from here to quarantine rows it
        // cannot key (DA-5), so it has to be persisted, not just used for DDL.
        If pk '= "" {
            Set meta.transform.pkColumns = pk
        }
        Set meta.loadStrategy = {"type": (loadType), "historyPolicy": (body.%Get("historyPolicy", "latest_state"))}
        Set meta.layers = {"staging": ("ETLW_STAGING." _ base _ "_delta"), "target": ("ETLW_TARGET." _ base)}
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Set res2 = cat.SetPipelineMetadata(runId, meta.%ToJSON(), "Deployed")
        If $Extract(res2, 1, 5) = "ERROR" {
            Return ..WriteError(res2)
        }
        // Indexes BEFORE the first load: the target is still empty here, so
        // CREATE INDEX is instant and the load maintains them as it inserts —
        // no second pass over the rows with %BuildIndices.
        Set indexMsg = ""
        If $IsObject(body.%Get("indexes", "")) || +body.%Get("tableColumnar", 0) {
            Set spec = {}
            Set spec.tableColumnar = +body.%Get("tableColumnar", 0)
            Set spec.indexes = body.%Get("indexes", [])
            Set idxTool = ##class(ETLWizard.Tools.Indexing).%New()
            Set indexMsg = ..ParseOr(idxTool.CreateIndexes(runId, base, spec.%ToJSON()))
        }

        // Validate the schedule BEFORE loading, so a bad schedule still fails
        // fast without having moved any data.
        Set scheduleSpec = ..ScheduleSpecFromBody(body)
        If $Extract(scheduleSpec, 1, 5) = "ERROR" {
            Return ..WriteError(scheduleSpec, "400 Bad Request")
        }

        // FIRST LOAD, THEN THE PRODUCTION - and the order matters.
        //
        // ApplyProduction starts the Extract service, whose adapter polls
        // IMMEDIATELY. With the production applied first, that poll performs
        // the real first load and advances the watermark; the wizard's own load
        // then finds nothing to do and reports rowsLoaded = 0. The per-base
        // lock keeps the data correct, but the number shown to the user is the
        // loser of the race - and that number is the headline of the deploy
        // step ("First load moved N rows into ETLW_TARGET.<base>").
        // Verified: an incremental pipeline over 6,024 orders reported 0.
        Set loadRes = ld.RunTransformLoad(runId, base, tsql, loadType, body.%Get("watermarkColumn", ""))

        // shared production item group (interval OR wall-clock schedule)
        Set prodTool = ##class(ETLWizard.Tools.Production).%New()
        Set prodMsg = prodTool.GenerateProduction(runId, +body.%Get("pollSeconds", 300), scheduleSpec, +body.%Get("poolSize", 1))
        If $Extract(prodMsg, 1, 5) '= "ERROR" {
            Do prodTool.ApplyProduction(runId)
        }
        Set loadObj = ""
        Try { Set loadObj = ##class(%DynamicObject).%FromJSON(loadRes) } Catch { Set loadObj = loadRes }
        Return ..WriteJSON({"deploy": (res), "production": (prodMsg), "load": (loadObj),
                            "indexes": (indexMsg)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Fetch one page of a REST endpoint and report what came back: the detected
/// data path, a sample, and an inferred column map. Read-only — this is the
/// per-endpoint "Test" button, and nothing is created until the user saves.
ClassMethod WizardRestProbe(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set url = $ZStrip(body.%Get("url", ""), "<>W")
        If url = "" {
            Return ..WriteError("url is required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.Tools.RestSource).ProbeEndpoint(url,
            body.%Get("dataPath", ""), body.%Get("headers", ""))
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Return ..WriteJSON(..ParseOr(res))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Mount the chosen endpoints: land each one's pages and expose it as
/// ETLWIZARD.<base>_<endpoint>. The wizard then treats them as ordinary
/// tables, so the existing transform step joins them into one target.
ClassMethod WizardRestMount(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set base = $ZStrip(body.%Get("baseName", ""), "<>W")
        If '##class(ETLWizard.Tools.Util).ValidIdent(base) {
            Return ..WriteError("invalid baseName", "400 Bad Request")
        }
        Set eps = body.%Get("endpoints", [])
        If '$IsObject(eps) || (eps.%Size() = 0) {
            Return ..WriteError("at least one endpoint is required", "400 Bad Request")
        }
        Set mounted = [], failed = []
        Set it = eps.%GetIterator()
        While it.%GetNext(.i, .ep) {
            Set name = ep.%Get("name", "endpoint" _ (i + 1))
            Set res = ##class(ETLWizard.Tools.RestSource).MountEndpoint(runId, base, name, ep.%ToJSON())
            If $Extract(res, 1, 5) = "ERROR" {
                Do failed.%Push({"endpoint": (name), "error": (res)})
            } Else {
                Set info = ..ParseOr(res)
                Set info.endpoint = name
                Do mounted.%Push(info)
            }
        }
        If mounted.%Size() = 0 {
            Return ..WriteError("no endpoint could be mounted: " _ failed.%ToJSON())
        }
        Return ..WriteJSON({"mounted": (mounted), "failed": (failed)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Recommend indexes for the deployed target table (wizard's last step).
/// Read-only — profiles the target, applies the type rules, and lets the local
/// model revise them against what the column names mean.
ClassMethod WizardIndexRecommend(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set tool = ##class(ETLWizard.Tools.Indexing).%New()
        Set res = tool.RecommendIndexes(runId, body.%Get("baseName", ""),
            body.%Get("pkColumns", ""), body.%Get("watermarkColumn", ""))
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Set out = ..ParseOr(res)
        Set out.existing = ..ParseOr(tool.ListTargetIndexes(body.%Get("baseName", "")))
        Return ..WriteJSON(out)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Build the indexes the user ticked (and, if chosen, convert the target to
/// columnar storage). The click is the human approval — no LLM involved.
ClassMethod WizardIndexApply(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set spec = {}
        Set spec.tableColumnar = +body.%Get("tableColumnar", 0)
        Set spec.indexes = body.%Get("indexes", [])
        Set tool = ##class(ETLWizard.Tools.Indexing).%New()
        Set res = tool.CreateIndexes(runId, body.%Get("baseName", ""), spec.%ToJSON())
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        Return ..WriteJSON(..ParseOr(res))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Upload a file to the dropzone for bulk load. The raw file bytes are the
/// request body (Content-Type application/octet-stream); the file name comes
/// from the X-Filename header. Streamed to disk, so there is no size cap. If
/// .xlsx, convert to .csv via openpyxl. Returns {csvFile, columnDefs, columns}.
ClassMethod WizardUpload(runId As %String) As %Status
{
    Try {
        Set fn = $ZStrip(%request.GetCgiEnv("HTTP_X_FILENAME"), "<>W")
        If fn = "" {
            Return ..WriteError("X-Filename header required", "400 Bad Request")
        }
        If (fn [ "/") || (fn [ "\") || (fn [ "..") {
            Return ..WriteError("fileName must be a bare file name", "400 Bad Request")
        }
        Set ext = $ZConvert($Piece(fn, ".", *), "L")
        If (ext '= "csv") && (ext '= "xlsx") {
            Return ..WriteError("only .csv or .xlsx files are supported", "400 Bad Request")
        }
        Set path = "/opt/irisbuild/dropzone/" _ fn
        Set fs = ##class(%Stream.FileBinary).%New()
        Set fs.Filename = path
        Set sc = fs.CopyFromAndSave(%request.Content)
        If $$$ISERR(sc) {
            Return ..WriteError("could not save file: " _ $System.Status.GetErrorText(sc))
        }
        Set note = ""
        Set csvFile = fn
        If ext = "xlsx" {
            Set conv = ##class(ETLWizard.Tools.BulkLoad).XlsxToCsv(fn)
            If $Extract(conv, 1, 5) = "ERROR" {
                Return ..WriteError(conv)
            }
            Set csvFile = conv
            Set note = "converted " _ fn _ " -> " _ csvFile
        }
        // Repair the file shapes the loader cannot read (whole-line quoting,
        // header names that are not identifiers) BEFORE inferring columns, so
        // the inferred names and the file's header agree - they must, because
        // LOAD DATA matches them by name.
        Set nerr = ##class(ETLWizard.Tools.BulkLoad).NormalizeCsv(csvFile, ",", .cleanFile, .cleanNote)
        If $Extract(nerr, 1, 5) = "ERROR" {
            Return ..WriteError($Extract(nerr, 8, *))
        }
        If cleanFile '= "" {
            Set csvFile = cleanFile
            Set note = note _ $Select(note = "": "", 1: "; ") _ cleanNote
        }
        Set inf = ..ParseOr(##class(ETLWizard.Tools.BulkLoad).InferColumns(csvFile))
        Set out = {}
        Set out.csvFile = csvFile
        Set out.note = note
        If $IsObject(inf) {
            Set out.columnDefs = inf.columnDefs
            Set out.columns = inf.columns
        }
        Return ..WriteJSON(out)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Build target, validate + first-load a file via LOAD [BULK] DATA, add it to
/// the shared production. Body: {baseName, csvFile, columnDefs, strategy, bulk,
/// header, separator, pollSeconds, pipelineName}.
ClassMethod WizardBulkDeploy(runId As %String) As %Status
{
    Try {
        Set body = ..ReadBody()
        Set base = body.baseName
        Set fileName = body.csvFile
        Set columnDefs = body.columnDefs
        Set strategy = body.%Get("strategy", "full")
        Set bulk = +body.%Get("bulk", 1)
        Set header = +body.%Get("header", 1)
        Set separator = body.%Get("separator", ",")
        // A file can reach here without passing through /upload (a re-deploy, or
        // a file dropped into the dropzone by hand), so repair it here too.
        // NormalizeCsv is a no-op on a file that is already loadable.
        Set normalizeNote = ""
        Set nerr = ##class(ETLWizard.Tools.BulkLoad).NormalizeCsv(fileName, separator, .cleanFile, .cleanNote)
        If ($Extract(nerr, 1, 5) '= "ERROR") && (cleanFile '= "") {
            Set fileName = cleanFile
            Set normalizeNote = cleanNote
        }
        Set res = ##class(ETLWizard.Tools.BulkLoad).Deploy(runId, base, fileName, columnDefs, strategy, bulk, header, separator)
        If $Extract(res, 1, 5) = "ERROR" {
            Return ..WriteError(res)
        }
        // metadata for no-LLM re-run via the executor / production
        Set meta = {}
        Set meta.pipelineName = body.%Get("pipelineName", base)
        Set meta.source = {"mode": "bulk", "file": (fileName), "columnDefs": (columnDefs),
            "strategy": (strategy), "bulk": (bulk), "header": (header), "separator": (separator)}
        Set meta.loadStrategy = {"type": "bulk"}
        // The ingested file is a SOURCE, so it is recorded as one. Writing a
        // `target` here would put it in front of the Knowledge Base tab and the
        // results panel as though an ETL had produced it.
        Set meta.layers = {"source": (##class(ETLWizard.Tools.BulkLoad).SourceTableName(base))}
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Set res2 = cat.SetPipelineMetadata(runId, meta.%ToJSON(), "Deployed")
        If $Extract(res2, 1, 5) = "ERROR" {
            Return ..WriteError(res2)
        }
        // NO PRODUCTION for a bulk load. The other strategies poll a source
        // that changes underneath them; an uploaded file does not. A business
        // service on a 300s interval would re-import the same file forever -
        // harmless under Full reload, a duplicate every five minutes under
        // Append. Re-importing is a deliberate act: upload again.
        Set loadObj = ..ParseOr(res)
        Return ..WriteJSON({"deploy": ("bulk load"), "load": (loadObj),
                            "note": (normalizeNote),
                            "production": "not created - one-off file import"})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

// ------------------------------------------------- Knowledge Graph tab
//
// Thin wrappers over ETLWizard.KG.Ingest (mds/knowledge-graph-tab-plan.md).
// Ingestion is driven one batch per request rather than one long call: a batch
// is seconds, a full run can be hours, and the webgateway gives up at ~60s.

ClassMethod KGCandidates() As %Status
{
    Try {
        Return ..WriteJSON({"tables": (##class(ETLWizard.KG.Ingest).ListCandidates()),
                            "chatModel": (##class(ETLWizard.KG.Setup).GetChatModel()),
                            "extractModel": (##class(ETLWizard.KG.Setup).GetExtractModel())})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGProfile() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.KG.Ingest).Profile(body.%Get("table", ""), body.%Get("column", ""))
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGStart() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        // The schema is created on demand: a fresh install has no ETLW_KG until
        // someone actually wants one.
        Set err = ##class(ETLWizard.KG.Setup).Install(0)
        If $Extract(err, 1, 5) = "ERROR" {
            Return ..WriteError($Extract(err, 8, *))
        }
        Set res = ##class(ETLWizard.KG.Ingest).Start(body)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGList() As %Status
{
    Try {
        Return ..WriteJSON({"corpora": (##class(ETLWizard.KG.Ingest).List())})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGStatus(id As %String) As %Status
{
    Try {
        Set res = ##class(ETLWizard.KG.Ingest).Status(id)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "404 Not Found")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// One batch. The frontend calls this in a loop so progress is visible and the
/// run can be stopped between batches.
ClassMethod KGRun(id As %String) As %Status
{
    Try {
        Set res = ##class(ETLWizard.KG.Ingest).RunBatch(id)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGCancel(id As %String) As %Status
{
    Try {
        Return ..WriteJSON(##class(ETLWizard.KG.Ingest).Cancel(id))
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGDrop(id As %String) As %Status
{
    Try {
        Set res = ##class(ETLWizard.KG.Ingest).Drop(id)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error)
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGGraph(id As %String) As %Status
{
    Try {
        Set limit = +$Get(%request.Data("limit", 1), 200)
        Set res = ##class(ETLWizard.KG.Ingest).Graph(id, limit)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error)
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGSearch() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.KG.Ingest).Search(body.%Get("corpusId", ""),
            body.%Get("question", ""), +body.%Get("topN", 8))
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Queue a question. Returns immediately with an id to poll - the answering
/// model takes tens of seconds and the gateway would time out on a direct call.
ClassMethod KGAsk() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.KG.Chat).Ask(body.%Get("corpusId", ""), body.%Get("question", ""))
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGAskPoll(id As %String) As %Status
{
    Try {
        Set res = ##class(ETLWizard.KG.Chat).Poll(id)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "404 Not Found")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Models available in Ollama, annotated with what each will do to VRAM.
/// A model that does not fit still answers - it just offloads to CPU and runs
/// an order of magnitude slower, with no error. This is where that becomes
/// visible, at the moment of choosing.
ClassMethod KGModels() As %Status
{
    Try {
        Return ..WriteJSON(##class(ETLWizard.KG.Models).List())
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

ClassMethod KGSelectModel() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set role = $ZStrip(body.%Get("role", "chat"), "<>W")
        Set model = $ZStrip(body.%Get("model", ""), "<>W")
        If role = "extract" {
            Set err = ##class(ETLWizard.KG.Setup).SetExtractModel(model)
        } Else {
            Set err = ##class(ETLWizard.KG.Setup).SetChatModel(model)
        }
        If err '= "" {
            Return ..WriteError(err, "400 Bad Request")
        }
        Return ..WriteJSON({"role": (role), "model": (model)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

// ------------------------------------------------------------------ MCP tab
//
// Publishing target tables as MCP tools (mds/mcp-tab-plan.md). Every route is
// a thin wrapper over ETLWizard.MCP.Publisher, which owns the validation - the
// published tools are reachable by an MCP client with no approval step, so the
// guard belongs in one place and not in the request handler.

/// Target tables available to publish.
ClassMethod MCPPublishable() As %Status
{
    Try {
        Return ..WriteJSON({"tables": (##class(ETLWizard.MCP.Publisher).ListPublishable())})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Default tool specs for one table, for the user to edit before publishing.
ClassMethod MCPPropose() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set table = $ZStrip(body.%Get("table", ""), "<>W")
        If table = "" {
            Return ..WriteError("table is required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.MCP.Publisher).ProposeTools(table)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Publish the given tool specs. A validation failure is the user's mistake,
/// so it comes back as a 400 with the reason, not a 500.
ClassMethod MCPPublish() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set tools = body.%Get("tools")
        If '$IsObject(tools) || (tools.%Size() = 0) {
            Return ..WriteError("pick at least one tool to publish", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.MCP.Publisher).Publish(tools)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// What the endpoint currently serves, plus the spec it was built from.
ClassMethod MCPPublished() As %Status
{
    Try {
        Return ..WriteJSON(##class(ETLWizard.MCP.Publisher).Published())
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Run one published tool in process - the same path an MCP client takes.
ClassMethod MCPTest() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set args = body.%Get("args")
        If '$IsObject(args) {
            Set args = {}
        }
        // A spec sent as `tool` is tested as it stands, published or not - the
        // tab's Test button acts on what is in the textareas, which is the only
        // thing that makes testing an edit meaningful.
        Set tool = body.%Get("tool")
        If $IsObject(tool) {
            Set res = ##class(ETLWizard.MCP.Publisher).PreviewTool(tool, args)
            If res.%Get("error", "") '= "" {
                Return ..WriteError(res.error, "400 Bad Request")
            }
            Return ..WriteJSON(res)
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        If name = "" {
            Return ..WriteError("name or tool is required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.MCP.Publisher).TestTool(name, args)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Drop one tool and republish the rest.
ClassMethod MCPUnpublish() As %Status
{
    Try {
        Set body = ..ReadBody()
        If '$IsObject(body) {
            Return ..WriteError("JSON body required", "400 Bad Request")
        }
        Set name = $ZStrip(body.%Get("name", ""), "<>W")
        If name = "" {
            Return ..WriteError("name is required", "400 Bad Request")
        }
        Set res = ##class(ETLWizard.MCP.Publisher).Unpublish(name)
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error, "400 Bad Request")
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Publish nothing - the endpoint stops offering tools.
ClassMethod MCPClear() As %Status
{
    Try {
        Set res = ##class(ETLWizard.MCP.Publisher).Clear()
        If res.%Get("error", "") '= "" {
            Return ..WriteError(res.error)
        }
        Return ..WriteJSON(res)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Demo cursor-paginated REST source for the REST Cursor Incremental Load
/// strategy (spec §7): GET /demo/customers?after=0&size=4 ->
/// {"data":[...], "nextCursor": <lastId> | null}. Serves ETLW_TARGET.customer.
ClassMethod DemoCustomers() As %Status
{
    Try {
        Set after = +$Get(%request.Data("after", 1), 0)
        Set size = +$Get(%request.Data("size", 1), 4)
        If (size < 1) || (size > 50) {
            Set size = 4
        }
        Set data = []
        Set lastId = ""
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP " _ size _ " customer_id, name, email, updated_at " _
            "FROM ETLW_TARGET.customer WHERE customer_id > ? ORDER BY customer_id")
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set rs = stmt.%Execute(after)
        While rs.%Next() {
            Do data.%Push({"customer_id": (rs.%GetData(1)), "name": (rs.%GetData(2)),
                           "email": (rs.%GetData(3)), "updated_at": (rs.%GetData(4))})
            Set lastId = rs.%GetData(1)
        }
        Set json = {}
        Set json.data = data
        If (lastId '= "") && (data.%Size() = size) {
            Set json.nextCursor = lastId
        } Else {
            Set json.nextCursor = ""
        }
        Return ..WriteJSON(json)
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Run history for a pipeline (spec §15), newest first.
ClassMethod GetRuns(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        Set runs = []
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP 50 ID FROM ETLWizard_Model.Run WHERE Pipeline = ? ORDER BY ID DESC")
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set rs = stmt.%Execute(id)
        While rs.%Next() {
            Set run = ##class(ETLWizard.Model.Run).%OpenId(rs.ID)
            If '$IsObject(run) {
                Continue
            }
            Set json = run.ToJSON()
            Try {
                Set json.stats = ##class(%DynamicObject).%FromJSON(run.StatsJson)
            } Catch {
            }
            Do runs.%Push(json)
        }
        Return ..WriteJSON({"pipelineId": (id), "runs": (runs)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

/// Graph JSON projection of the pipeline DAG (spec §14.3, §15)
ClassMethod GetGraph(id As %String) As %Status
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(id)
        If '$IsObject(pipeline) {
            Return ..WriteError("pipeline not found: " _ id, "404 Not Found")
        }
        Set nodes = []
        Set edges = []

        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Node WHERE Pipeline = ? ORDER BY ID")
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set rs = stmt.%Execute(id)
        If rs.%SQLCODE < 0 {
            Return ..WriteError("SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message)
        }
        While rs.%Next() {
            Set node = ##class(ETLWizard.Model.Node).%OpenId(rs.ID)
            If '$IsObject(node) {
                Continue
            }
            Do nodes.%Push(node.ToJSON())
        }

        Set stmt2 = ##class(%SQL.Statement).%New()
        Set sc = stmt2.%Prepare("SELECT ID FROM ETLWizard_Model.Edge WHERE Pipeline = ? ORDER BY ID")
        If $$$ISERR(sc) {
            Return ..WriteError($System.Status.GetErrorText(sc))
        }
        Set rs2 = stmt2.%Execute(id)
        If rs2.%SQLCODE < 0 {
            Return ..WriteError("SQLCODE " _ rs2.%SQLCODE _ ": " _ rs2.%Message)
        }
        While rs2.%Next() {
            Set edge = ##class(ETLWizard.Model.Edge).%OpenId(rs2.ID)
            If '$IsObject(edge) {
                Continue
            }
            Do edges.%Push(edge.ToJSON())
        }

        Return ..WriteJSON({"pipelineId": (id), "nodes": (nodes), "edges": (edges)})
    } Catch ex {
        Return ..WriteError(ex.DisplayString())
    }
}

}
