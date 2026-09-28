/// Backing store for the authorization policy (spec §10.3, §12.1).
/// Every destructive tool call suspends here until a human resolves it via
/// POST /api/runs/:id/approvals/:aid.
Class ETLWizard.Model.PendingApproval Extends %Persistent
{

Property Run As ETLWizard.Model.Run [ Required ];

/// Tool name whose execution is suspended
Property Tool As %String(MAXLEN = 128) [ Required ];

/// Exact tool arguments — shown on the approval card (spec §10.3)
Property ArgsJson As %String(MAXLEN = "");

Property Status As %String(VALUELIST = ",pending,approved,rejected,expired") [ InitialExpression = "pending" ];

Property ResolvedBy As %String(MAXLEN = 128);

/// Reviewer comment — on rejection it is returned to the agent as a tool
/// error so the agent re-plans (spec §10.3, §23.4)
Property Comment As %String(MAXLEN = 2000);

Property CreatedAt As %TimeStamp [ InitialExpression = {$ZDateTime($ZTimeStamp, 3, , 3)} ];

Property ResolvedAt As %TimeStamp;

Index RunIdx On Run;

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json.runId = ..Run.%Id()
    Set json.tool = ..Tool
    Set json.status = ..Status
    Set json.resolvedBy = ..ResolvedBy
    Set json.comment = ..Comment
    Set json.createdAt = ..CreatedAt
    Set json.resolvedAt = ..ResolvedAt
    Try {
        Set json.args = ##class(%DynamicObject).%FromJSON(..ArgsJson)
    } Catch {
        Set json.args = {}
    }
    Return json
}

}
