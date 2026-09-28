/// Runtime execution of a deployed pipeline (spec §13) — replays the
/// persisted pipeline definition with NO LLM involvement. Uses the very same
/// Load/DataQuality tool methods the agent calls, so events, row counts and
/// checks are produced identically and any watching canvas sees the same
/// live run (spec §23.5).
/// Invoked via JOB from the REST layer (manual) and from ETLWizard.Sched.Task
/// (scheduled, P4).
Class ETLWizard.Runtime.Executor Extends %RegisteredObject
{

/// Execute one run of a deployed pipeline. runId must reference an existing
/// Run in status "running" (created by the caller so it can hand the id to
/// the canvas before execution starts).
ClassMethod Execute(pipelineId As %String, runId As %String) As %Status
{
    Set sc = $$$OK
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(pipelineId)
        If '$IsObject(pipeline) {
            Return $$$ERROR($$$GeneralError, "Pipeline not found: " _ pipelineId)
        }
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return $$$ERROR($$$GeneralError, "Run not found: " _ runId)
        }

        Do ##class(ETLWizard.Model.Event).Append(runId, "run.started", "",
            {"pipelineId": (pipelineId), "pipelineName": (pipeline.Name), "trigger": (run.Trigger), "llm": false})

        // Derive the execution plan from the canonical metadata (spec §12.2)
        Set err = ..ParsePlan(pipeline, .baseName, .foreignTable, .wmColumn, .mode, .csvServer, .columnDefs, .transformSql)
        If err '= "" {
            Return ..Fail(pipeline, run, err)
        }

        Set pipeline.Status = "Running"
        Do pipeline.%Save()

        // Same execution path as the agent tools and the production — one dispatch
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Set statsJson = ld.RunPlan(runId, baseName, foreignTable, mode, wmColumn, csvServer, columnDefs, transformSql)
        If $Extract(statsJson, 1, 5) = "ERROR" {
            Return ..Fail(pipeline, run, statsJson)
        }
        Set stats = ##class(%DynamicObject).%FromJSON(statsJson)

        Set run.StatsJson = statsJson
        Set run.Status = "succeeded"
        Set run.FinishedAt = $ZDateTime($ZTimeStamp, 3, , 3)
        Do run.%Save()
        Set pipeline.Status = "Succeeded"
        Do pipeline.%Save()

        Do ##class(ETLWizard.Model.Event).Append(runId, "run.finished", "",
            {"status": "succeeded", "stats": (stats)})
    } Catch ex {
        Set sc = ex.AsStatus()
        Try {
            Do ..Fail(pipeline, run, "ERROR: " _ $System.Status.GetErrorText(sc))
        } Catch {
        }
    }
    Return sc
}

/// Extract baseName / foreignTable / watermark column / mode from the
/// pipeline's §12.2 metadata. Returns "" or an error message.
ClassMethod ParsePlan(pipeline As ETLWizard.Model.Pipeline, Output baseName As %String, Output foreignTable As %String, Output wmColumn As %String, Output mode As %String, Output csvServer As %String, Output columnDefs As %String, Output transformSql As %String) As %String [ Internal ]
{
    Set baseName = ""
    Set foreignTable = ""
    Set wmColumn = ""
    Set mode = "incremental"
    Set csvServer = ""
    Set columnDefs = ""
    Set transformSql = ""
    Try {
        If pipeline.MetadataJson = "" {
            Return "ERROR: pipeline has no metadata - deploy it first (SetPipelineMetadata)"
        }
        Set meta = ##class(%DynamicObject).%FromJSON(pipeline.MetadataJson)

        // target "ETLW_TARGET.customer" -> baseName "customer"
        Set target = ""
        If $IsObject(meta.layers) {
            Set target = meta.layers.%Get("target", "")
        }
        Set baseName = $Piece(target, ".", *)
        If baseName = "" {
            Return "ERROR: metadata.layers.target missing"
        }

        // Custom transform: staging comes from a SELECT (may join many sources),
        // so a single foreignTable is not required.
        If $IsObject(meta.transform) {
            Set transformSql = meta.transform.%Get("sql", "")
        }

        // source.foreignTable "ETLWIZARD.ext_customer" -> "ext_customer"
        Set ftFull = ""
        If $IsObject(meta.source) {
            Set ftFull = meta.source.%Get("foreignTable", "")
        }
        Set foreignTable = $Piece(ftFull, ".", *)
        If $IsObject(meta.loadStrategy) {
            Set mode = $ZConvert(meta.loadStrategy.%Get("type", "incremental"), "L")
        }
        // Bulk file load needs no foreign table / transform / watermark — it
        // re-reads the dropzone file into the target via LOAD [BULK] DATA.
        If mode = "bulk" {
            Return ""
        }
        If (foreignTable = "") && (transformSql = "") {
            Return "ERROR: metadata needs source.foreignTable or transform.sql"
        }
        If $IsObject(meta.source) {
            If $IsObject(meta.source.watermark) {
                Set wmColumn = meta.source.watermark.%Get("column", "")
            }
            Set csvServer = meta.source.%Get("csvServer", "")
            Set columnDefs = meta.source.%Get("columnDefs", "")
        }
        // A transform may carry an optional watermark column
        If (transformSql '= "") && $IsObject(meta.transform) {
            Set wmColumn = meta.transform.%Get("watermarkColumn", "")
        }
        // Only a single-source incremental merge hard-requires a watermark.
        // Transforms merge without one; append/full/snapshot/csv_arrival need none.
        If (mode = "incremental") && (wmColumn = "") && (transformSql = "") {
            Return "ERROR: metadata.source.watermark.column missing for incremental strategy"
        }
        If (mode = "csv_arrival") && ((csvServer = "") || (columnDefs = "")) {
            Return "ERROR: metadata.source.csvServer/columnDefs missing for csv_arrival strategy"
        }
        Return ""
    } Catch ex {
        Return "ERROR parsing metadata: " _ ex.DisplayString()
    }
}

/// Shared failure path: mark run + pipeline failed, emit run.error/run.finished.
ClassMethod Fail(pipeline As ETLWizard.Model.Pipeline, run As ETLWizard.Model.Run, error As %String) As %Status [ Internal ]
{
    Try {
        Set runId = run.%Id()
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "", {"error": (error)})
        Set run.Status = "failed"
        Set run.FinishedAt = $ZDateTime($ZTimeStamp, 3, , 3)
        Set run.StatsJson = {"error": (error)}.%ToJSON()
        Do run.%Save()
        Set pipeline.Status = "Failed"
        Do pipeline.%Save()
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.finished", "", {"status": "failed"})
    } Catch {
    }
    Return $$$ERROR($$$GeneralError, error)
}

}
