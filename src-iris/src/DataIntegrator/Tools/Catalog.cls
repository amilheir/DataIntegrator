/// Catalog tools (spec §10.2): persist pipeline DAG nodes/edges and agent
/// annotations. Every mutation appends an event, which is what drives the
/// real-time canvas. Read-only + catalog writes only — no DDL here, so no
/// auth gate (destructive verbs live in their own REQUIRESAUTH classes, P1+).
Class ETLWizard.Tools.Catalog Extends %AI.Tool [ DependsOn = (ETLWizard.Model.Node, ETLWizard.Model.Edge) ]
{

/// Record a pipeline artifact node in the catalog. kind must be one of:
/// source, foreign_server, foreign_table, rest_client, landing, staging,
/// transform_view, target, check, quarantine. sqlText is the exact DDL/DML
/// for the node ("" if none yet). Returns the created node id.
Method CatalogRecord(runId As %String, kind As %String, name As %String, sqlText As %String = "", configJson As %String = "") As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set node = ##class(ETLWizard.Model.Node).%New()
        Set node.Pipeline = run.Pipeline
        Set node.Kind = kind
        Set node.Name = name
        Set node.SqlText = sqlText
        Set node.ConfigJson = configJson
        Set node.GraphStatus = "configured"
        Set sc = node.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.created", node.%Id(),
            {"nodeId": (node.%Id()), "kind": (kind), "name": (name)})
        Return "Created node " _ node.%Id() _ " (" _ kind _ ": " _ name _ ")"
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Link two previously recorded nodes with a directed lineage edge.
/// fromName/toName are the node names used in CatalogRecord. label describes
/// the data movement (e.g. "JDBC", "Incremental Extract", "Merge/Upsert").
Method CatalogLink(runId As %String, fromName As %String, toName As %String, label As %String = "") As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set pipelineId = run.Pipeline.%Id()
        Set fromNode = ##class(ETLWizard.Model.Node).PipelineNameIdxOpen(pipelineId, fromName)
        If '$IsObject(fromNode) {
            Return "ERROR: node not found: " _ fromName
        }
        Set toNode = ##class(ETLWizard.Model.Node).PipelineNameIdxOpen(pipelineId, toName)
        If '$IsObject(toNode) {
            Return "ERROR: node not found: " _ toName
        }
        Set edge = ##class(ETLWizard.Model.Edge).%New()
        Set edge.Pipeline = run.Pipeline
        Set edge.FromNode = fromNode
        Set edge.ToNode = toNode
        Set edge.Label = label
        Set sc = edge.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "edge.created", edge.%Id(),
            {"edgeId": (edge.%Id()), "from": (fromNode.%Id()), "to": (toNode.%Id()), "label": (label)})
        Return "Created edge " _ fromName _ " -> " _ toName
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Update the graph status of a recorded node. status must be one of:
/// not_configured, configured, validated, generated, deployed, running,
/// succeeded, failed, warning.
Method UpdateNodeStatus(runId As %String, nodeName As %String, status As %String) As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set node = ##class(ETLWizard.Model.Node).PipelineNameIdxOpen(run.Pipeline.%Id(), nodeName)
        If '$IsObject(node) {
            Return "ERROR: node not found: " _ nodeName
        }
        Set node.GraphStatus = status
        Set sc = node.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", node.%Id(),
            {"nodeId": (node.%Id()), "name": (nodeName), "status": (status)})
        Return "Node " _ nodeName _ " -> " _ status
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Show a short annotation from the agent on the architecture canvas.
Method EmitNote(runId As %String, note As %String) As %String
{
    Try {
        Set sc = ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "",
            {"role": "agent", "text": (note)})
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Return "Note emitted"
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Persist the canonical pipeline metadata JSON (spec §12.2) on the Pipeline
/// and optionally advance its status (Draft, Generated, Deployed). Call this
/// after the strategy is confirmed and again after deployment.
Method SetPipelineMetadata(runId As %String, metadataJson As %String, status As %String = "") As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Try {
            Do ##class(%DynamicObject).%FromJSON(metadataJson)
        } Catch {
            Return "ERROR: metadataJson is not valid JSON"
        }
        Set pipeline = run.Pipeline
        Set pipeline.MetadataJson = metadataJson
        If status '= "" {
            Set pipeline.Status = status
        }
        Set sc = pipeline.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "plan.updated", "",
            {"pipelineId": (pipeline.%Id()), "status": (pipeline.Status)})
        Return "Pipeline metadata saved" _ $Select(status '= "": ", status " _ status, 1: "")
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Preview the Interoperability Production topology for this run's pipeline
/// (spec v2.2): which Business Service triggers extraction, the orchestrating
/// Business Process, and the load Business Operation. Read-only, no code.
Method PlanProduction(runId As %String) As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set err = ##class(ETLWizard.Runtime.Executor).ParsePlan(run.Pipeline, .baseName, .foreignTable, .wmColumn, .mode)
        If err '= "" {
            Return err
        }
        Return {"productionClass": ("ETLWizard.Prod." _ baseName),
                "items": [
                  {"name": "ExtractService", "role": "business_service", "class": "ETLWizard.Host.ExtractService",
                   "purpose": ("polls and extracts " _ foreignTable _ " (" _ mode _ ")"), "schedule": "CallInterval seconds"},
                  {"name": "Orchestrator", "role": "business_process", "class": "ETLWizard.Host.Orchestrator",
                   "purpose": "land -> stage -> validate -> route to load"},
                  {"name": "LoadOperation", "role": "business_operation", "class": "ETLWizard.Host.LoadOperation",
                   "purpose": ("merge/insert into ETLW_TARGET." _ baseName _ ", watermark, reconcile")}
                ]}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Lint a SQL statement before proposing it (spec §16.3, §6.3): flags
/// multiple statements, unexpected verbs, and the EXACT-vs-SQLUPPER collation
/// risk when foreign-table data is compared against local strings.
Method LintSql(sql As %String) As %String
{
    Try {
        Set warnings = []
        Set trimmed = $ZStrip(sql, "<>W")
        If $Extract(trimmed, *) = ";" {
            Set trimmed = $Extract(trimmed, 1, * - 1)
        }
        If trimmed [ ";" {
            Do warnings.%Push("multiple statements: tools execute exactly one statement")
        }
        Set verb = $ZConvert($Piece(trimmed, " ", 1), "U")
        If '$ListFind($ListBuild("SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "TRUNCATE", "MERGE", "THROUGH"), verb) {
            Do warnings.%Push("unexpected leading verb '" _ verb _ "'")
        }
        Set upper = $ZConvert(trimmed, "U")
        If (upper [ "ETLWIZARD.") && ((upper [ "ETLW_TARGET.") || (upper [ "ETLW_STAGING.")) &&
           (upper [ "=") && ('(upper [ "%SQLUPPER")) {
            Do warnings.%Push("collation risk: foreign tables default to EXACT collation while local tables are SQLUPPER - string joins/filters may silently mismatch; wrap both sides in %SQLUPPER(...)")
        }
        Return {"sql": (sql), "warnings": (warnings), "clean": (warnings.%Size() = 0)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Detect likely sensitive columns of a mounted foreign table and suggest a
/// masked SELECT list for the staging transform (spec §16.5, optional).
Method SuggestMasking(foreignTable As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = '" _ foreignTable _ "' ORDER BY ORDINAL_POSITION")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        Set sensitive = []
        Set selectList = ""
        Set found = 0
        While rs.%Next() {
            Set col = rs.%GetData(1)
            Set lower = $ZConvert(col, "L")
            Set kind = ""
            If (lower [ "email") || (lower [ "mail") {
                Set kind = "email"
            } ElseIf (lower [ "phone") || (lower [ "ssn") || (lower [ "tax") || (lower [ "card") || (lower [ "passport") {
                Set kind = "identifier"
            } ElseIf (lower [ "name") || (lower [ "address") || (lower [ "birth") || (lower = "dob") {
                Set kind = "personal"
            }
            If kind = "" {
                Set expr = col
            } ElseIf kind = "email" {
                Set expr = "CONCAT(LEFT(" _ col _ ", 2), '***@masked') AS " _ col
                Do sensitive.%Push({"column": (col), "kind": (kind)})
                Set found = found + 1
            } Else {
                Set expr = "'***' AS " _ col
                Do sensitive.%Push({"column": (col), "kind": (kind)})
                Set found = found + 1
            }
            Set selectList = selectList _ $Select(selectList = "": "", 1: ", ") _ expr
        }
        Return {"foreignTable": (foreignTable), "sensitiveColumns": (sensitive),
                "maskedSelectList": (selectList),
                "note": ($Select(found = 0: "no likely-sensitive columns detected", 1: "use maskedSelectList in the landing->staging transform to mask before landing"))}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Generate the pipeline documentation as Markdown (spec §24 docs generator):
/// metadata, strategy, watermark, every DAG node with its exact SQL/code
/// reference, lineage, production topology and recent runs. Written to
/// /opt/irisbuild/docs/<pipeline>.md (visible on the host under src-iris/docs).
Method GenerateDocs(runId As %String) As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set pipeline = run.Pipeline
        Set nl = $Char(10)
        Set md = "# Pipeline: " _ pipeline.Name _ nl _ nl
        Set md = md _ "Generated " _ $ZDateTime($ZTimeStamp, 3) _ " by the ETL Wizard docs generator." _ nl
        Set md = md _ "Status: **" _ pipeline.Status _ "** - Owner: " _ pipeline.Owner _ nl _ nl
        If pipeline.Description '= "" {
            Set md = md _ pipeline.Description _ nl _ nl
        }
        If pipeline.MetadataJson '= "" {
            Set md = md _ "## Metadata (spec 12.2)" _ nl _ nl _ "```json" _ nl _ pipeline.MetadataJson _ nl _ "```" _ nl _ nl
        }
        Set wm = ##class(ETLWizard.Model.Watermark).PipelineIdxOpen(pipeline.%Id())
        If $IsObject(wm) {
            Set md = md _ "## Watermark" _ nl _ nl _ "| Type | Column | Last value | Updated |" _ nl _ "|---|---|---|---|" _ nl
            Set md = md _ "| " _ wm.Type _ " | " _ wm.ColumnName _ " | " _ wm.LastValue _ " | " _ wm.UpdatedAt _ " |" _ nl _ nl
        }
        Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(pipeline.%Id())
        If $IsObject(prod) {
            Set md = md _ "## Interoperability Production" _ nl _ nl
            Set md = md _ "Class `" _ prod.ProductionClass _ "` - status " _ prod.Status _ nl _ nl
        }
        Set md = md _ "## Nodes" _ nl _ nl
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Node WHERE Pipeline = ? ORDER BY ID")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(pipeline.%Id())
        While rs.%Next() {
            Set node = ##class(ETLWizard.Model.Node).%OpenId(rs.ID)
            If '$IsObject(node) {
                Continue
            }
            Set md = md _ "### " _ node.Name _ " (" _ node.Kind _ ")" _ nl _ nl
            Set md = md _ "Status: " _ node.GraphStatus
            If node.HostRole '= "none" {
                Set md = md _ " - host role: " _ node.HostRole _ " (item " _ node.HostItemName _ ")"
            }
            If node.CodeRef '= "" {
                Set md = md _ " - code: `" _ node.CodeRef _ "`"
            }
            Set md = md _ nl _ nl
            If node.SqlText '= "" {
                Set md = md _ "```sql" _ nl _ node.SqlText _ nl _ "```" _ nl _ nl
            }
        }
        Set md = md _ "## Lineage" _ nl _ nl
        Set stmt2 = ##class(%SQL.Statement).%New()
        Set sc = stmt2.%Prepare("SELECT ID FROM ETLWizard_Model.Edge WHERE Pipeline = ? ORDER BY ID")
        If $$$ISOK(sc) {
            Set rs2 = stmt2.%Execute(pipeline.%Id())
            While rs2.%Next() {
                Set edge = ##class(ETLWizard.Model.Edge).%OpenId(rs2.ID)
                If '$IsObject(edge) {
                    Continue
                }
                Set md = md _ "- " _ edge.FromNode.Name _ " -> " _ edge.ToNode.Name _ " (" _ edge.Label _ ")" _ nl
            }
        }
        Set md = md _ nl _ "## Recent runs" _ nl _ nl _ "| Run | Status | Trigger | Started | Finished |" _ nl _ "|---|---|---|---|---|" _ nl
        Set stmt3 = ##class(%SQL.Statement).%New()
        Set sc = stmt3.%Prepare("SELECT TOP 10 ID FROM ETLWizard_Model.Run WHERE Pipeline = ? ORDER BY ID DESC")
        If $$$ISOK(sc) {
            Set rs3 = stmt3.%Execute(pipeline.%Id())
            While rs3.%Next() {
                Set r = ##class(ETLWizard.Model.Run).%OpenId(rs3.ID)
                If '$IsObject(r) {
                    Continue
                }
                Set md = md _ "| " _ r.%Id() _ " | " _ r.Status _ " | " _ r.Trigger _ " | " _ r.StartedAt _ " | " _ r.FinishedAt _ " |" _ nl
            }
        }
        // Write to the mounted docs directory
        Do ##class(%File).CreateDirectoryChain("/opt/irisbuild/docs")
        Set fileName = "/opt/irisbuild/docs/" _ $Translate(pipeline.Name, " /\", "___") _ ".md"
        Set file = ##class(%Stream.FileCharacter).%New()
        Set sc = file.LinkToFile(fileName)
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do file.Clear()
        Do file.Write(md)
        Set sc = file.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "",
            {"role": "agent", "text": ("Documentation generated: " _ fileName)})
        Return "Documentation written to " _ fileName _ " (" _ $Length(md) _ " chars)"
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Return the current pipeline DAG (nodes and edges) as JSON for the run.
Method GetPipelineGraph(runId As %String) As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set pipelineId = run.Pipeline.%Id()
        Set nodes = []
        Set edges = []
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Node WHERE Pipeline = ? ORDER BY ID")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(pipelineId)
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
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs2 = stmt2.%Execute(pipelineId)
        While rs2.%Next() {
            Set edge = ##class(ETLWizard.Model.Edge).%OpenId(rs2.ID)
            If '$IsObject(edge) {
                Continue
            }
            Do edges.%Push(edge.ToJSON())
        }
        Return {"pipelineId": (pipelineId), "nodes": (nodes), "edges": (edges)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

}
