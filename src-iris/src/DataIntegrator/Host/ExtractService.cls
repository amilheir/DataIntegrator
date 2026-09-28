/// Extract/trigger Business Service (spec §4.3): an adapterless poll service
/// that starts a pipeline run each CallInterval. Scheduling is expressed as
/// this service's CallInterval (or the production Schedule setting) instead
/// of a standalone %SYS.Task.
/// Reusable across pipelines: the generated Ens.Production sets PipelineId
/// per item, so the production class remains the visible generated artifact.
Class ETLWizard.Host.ExtractService Extends Ens.BusinessService
{

Parameter ADAPTER = "Ens.InboundAdapter";

/// Pipeline this service triggers (set in the generated production)
Property PipelineId As %String;

/// Config item name of the orchestrating Business Process
Property TargetProcess As %String [ InitialExpression = "Orchestrator" ];

Parameter SETTINGS = "PipelineId:Basic,TargetProcess:Basic";

Method OnProcessInput(pInput As %RegisteredObject, Output pOutput As %RegisteredObject) As %Status
{
    Set sc = $$$OK
    Try {
        If ..PipelineId = "" {
            Return $$$ERROR($$$GeneralError, "PipelineId setting is empty")
        }
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(..PipelineId)
        If '$IsObject(pipeline) {
            Return $$$ERROR($$$GeneralError, "Pipeline not found: " _ ..PipelineId)
        }
        Set err = ##class(ETLWizard.Runtime.Executor).ParsePlan(pipeline, .baseName, .foreignTable, .wmColumn, .mode, .csvServer, .columnDefs, .transformSql)
        If err '= "" {
            Return $$$ERROR($$$GeneralError, err)
        }

        Set run = ##class(ETLWizard.Model.Run).%New()
        Set run.Pipeline = pipeline
        Set run.Trigger = "schedule"
        Set sc = run.%Save()
        If $$$ISERR(sc) {
            Return sc
        }
        Set runId = run.%Id()
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.started", "",
            {"pipelineId": (..PipelineId), "pipelineName": (pipeline.Name), "trigger": "production", "llm": false})

        Set req = ##class(ETLWizard.Msg.ExtractBatch).%New()
        Set req.PipelineId = ..PipelineId
        Set req.RunId = runId
        Set req.BaseName = baseName
        Set req.ForeignTable = foreignTable
        Set req.WatermarkColumn = wmColumn
        Set req.Mode = mode
        Set req.CsvServer = csvServer
        Set req.ColumnDefs = columnDefs
        Set req.TransformSql = transformSql

        Set sc = ..SendRequestSync(..TargetProcess, req, .resp)

        // Finalize the run from the load result
        If $$$ISERR(sc) || ('$IsObject(resp)) || ('resp.Ok) {
            Set errText = $Select($$$ISERR(sc): $System.Status.GetErrorText(sc),
                                  $IsObject(resp): resp.Error, 1: "no response from " _ ..TargetProcess)
            Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "", {"error": (errText)})
            Set run.Status = "failed"
            Set pipeline.Status = "Failed"
        } Else {
            Set run.StatsJson = resp.StatsJson
            Set run.Status = "succeeded"
            Set pipeline.Status = "Succeeded"
        }
        Set run.FinishedAt = $ZDateTime($ZTimeStamp, 3, , 3)
        Do run.%Save()
        Do pipeline.%Save()
        Set stats = {}
        Try {
            Set stats = ##class(%DynamicObject).%FromJSON(run.StatsJson)
        } Catch {
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.finished", "",
            {"status": (run.Status), "stats": (stats)})
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

}
