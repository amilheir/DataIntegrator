/// One execution of a pipeline — wizard-driven, manual, or scheduled (spec §12.1).
Class ETLWizard.Model.Run Extends %Persistent
{

Property Pipeline As ETLWizard.Model.Pipeline [ Required ];

Property StartedAt As %TimeStamp [ InitialExpression = {$ZDateTime($ZTimeStamp, 3, , 3)} ];

Property FinishedAt As %TimeStamp;

Property Status As %String(VALUELIST = ",running,succeeded,failed,warning,cancelled") [ InitialExpression = "running" ];

Property Trigger As %String(VALUELIST = ",wizard,schedule,manual") [ Required ];

/// Rows read/inserted/updated/rejected, latency, retries... (spec §18)
Property StatsJson As %String(MAXLEN = "");

Index PipelineIdx On Pipeline;

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json.pipelineId = ..Pipeline.%Id()
    Set json.startedAt = ..StartedAt
    Set json.finishedAt = ..FinishedAt
    Set json.status = ..Status
    Set json.trigger = ..Trigger
    Return json
}

}
