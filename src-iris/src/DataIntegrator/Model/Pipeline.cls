/// A pipeline definition created by the wizard (spec §12.1).
/// MetadataJson holds the canonical pipeline metadata shape (spec §12.2).
Class ETLWizard.Model.Pipeline Extends %Persistent
{

Property Name As %String(MAXLEN = 128) [ Required ];

Property Description As %String(MAXLEN = 2000);

Property Owner As %String(MAXLEN = 128);

/// Draft -> Generated -> Deployed -> Running -> Succeeded | Failed | Warning | Paused (spec §18)
Property Status As %String(VALUELIST = ",Draft,Generated,Deployed,Running,Succeeded,Failed,Warning,Paused") [ InitialExpression = "Draft" ];

/// Links the persisted %AI.Agent.Session so a wizard run survives browser refresh.
Property SessionId As %String(MAXLEN = 256);

/// Canonical pipeline metadata JSON (spec §12.2)
Property MetadataJson As %String(MAXLEN = "");

Property CreatedAt As %TimeStamp [ InitialExpression = {$ZDateTime($ZTimeStamp, 3, , 3)} ];

Index NameIdx On Name [ Unique ];

/// Compact JSON projection for the REST API.
Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json.name = ..Name
    Set json.description = ..Description
    Set json.owner = ..Owner
    Set json.status = ..Status
    Set json.sessionId = ..SessionId
    Set json.createdAt = ..CreatedAt
    If ..MetadataJson '= "" {
        Try {
            Set json.metadata = ##class(%DynamicObject).%FromJSON(..MetadataJson)
        } Catch {
            Set json.metadata = ""
        }
    }
    Return json
}

}
