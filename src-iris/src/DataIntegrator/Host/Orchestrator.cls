/// Orchestrating Business Process (spec §4.3): receives the batch request and
/// coordinates the load chain. Every hop is a distinct, retryable message in
/// the Visual Trace.
Class ETLWizard.Host.Orchestrator Extends Ens.BusinessProcess
{

/// Config item name of the load Business Operation
Property LoadTarget As %String [ InitialExpression = "LoadOperation" ];

Parameter SETTINGS = "LoadTarget:Basic";

Method OnRequest(pRequest As ETLWizard.Msg.ExtractBatch, Output pResponse As ETLWizard.Msg.LoadResult) As %Status
{
    Set sc = $$$OK
    Try {
        Do ##class(ETLWizard.Model.Event).Append(pRequest.RunId, "node.status", "",
            {"name": "Orchestrator", "status": "running", "hostRole": "business_process"})
        Set sc = ..SendRequestSync(..LoadTarget, pRequest, .pResponse)
        If $$$ISERR(sc) {
            Return sc
        }
        Do ##class(ETLWizard.Model.Event).Append(pRequest.RunId, "node.status", "",
            {"name": "Orchestrator", "status": ($Select($IsObject(pResponse) && pResponse.Ok: "succeeded", 1: "failed")), "hostRole": "business_process"})
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

}
