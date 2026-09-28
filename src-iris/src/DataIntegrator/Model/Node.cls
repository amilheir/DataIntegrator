/// A node of the pipeline DAG (spec §12.1). SqlText stores the exact DDL/DML
/// executed so the pipeline re-runs without the agent (spec §1.1, §13).
Class ETLWizard.Model.Node Extends %Persistent
{

Property Pipeline As ETLWizard.Model.Pipeline [ Required ];

Property Kind As %String(VALUELIST = ",source,foreign_server,foreign_table,rest_client,landing,staging,transform_view,load_config,bulk_load,target,check,quarantine,host,production") [ Required ];

Property Name As %String(MAXLEN = 256) [ Required ];

/// Exact DDL/DML executed for this node
Property SqlText As %String(MAXLEN = "");

/// Reference to generated ObjectScript (e.g. REST client class name)
Property CodeRef As %String(MAXLEN = 256);

Property ConfigJson As %String(MAXLEN = "");

/// Graph state: not_configured -> configured -> validated -> generated -> deployed
/// -> running -> succeeded | failed | warning (spec §14.3)
Property GraphStatus As %String(VALUELIST = ",not_configured,configured,validated,generated,deployed,running,succeeded,failed,warning") [ InitialExpression = "not_configured" ];

/// Canvas position hint {"x":0,"y":0} — auto-layout may override
Property PositionJson As %String(MAXLEN = 512);

/// Interoperability host role this node maps to (spec v2.2 §12.1)
Property HostRole As %String(VALUELIST = ",business_service,business_process,business_operation,none") [ InitialExpression = "none" ];

/// Production config item name when HostRole is not "none"
Property HostItemName As %String(MAXLEN = 128);

Index PipelineIdx On Pipeline;

Index PipelineNameIdx On (Pipeline, Name) [ Unique ];

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json.pipelineId = ..Pipeline.%Id()
    Set json.kind = ..Kind
    Set json.name = ..Name
    Set json.status = ..GraphStatus
    Set json.codeRef = ..CodeRef
    Set json.sqlText = ..SqlText
    Set json.config = ..ConfigJson
    Return json
}

}
