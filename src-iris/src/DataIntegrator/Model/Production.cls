/// The generated Ens.Production for a pipeline (spec v2.2 §12.1).
Class ETLWizard.Model.Production Extends %Persistent
{

Property Pipeline As ETLWizard.Model.Pipeline [ Required ];

/// e.g. ETLWizard.Prod.customer
Property ProductionClass As %String(MAXLEN = 220) [ Required ];

Property Status As %String(VALUELIST = ",stopped,running,troubled") [ InitialExpression = "stopped" ];

/// Mirrors the production settings (items, intervals)
Property ConfigJson As %String(MAXLEN = "");

Index PipelineIdx On Pipeline [ Unique ];

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json.pipelineId = ..Pipeline.%Id()
    Set json.productionClass = ..ProductionClass
    Set json.status = ..Status
    Try {
        Set json.config = ##class(%DynamicObject).%FromJSON(..ConfigJson)
    } Catch {
    }
    Return json
}

}
