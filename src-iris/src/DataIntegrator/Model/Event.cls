/// Append-only event log (spec §12.1, §14.2). The real-time canvas is a pure
/// projection of this log: the WS hub replays events with Seq > lastSeq on
/// reconnect, then pushes live. Doubles as the audit trail (spec §16.6).
Class ETLWizard.Model.Event Extends %Persistent
{

Property Run As ETLWizard.Model.Run [ Required ];

/// Monotonic per-run sequence — the replay cursor
Property Seq As %Integer [ Required ];

Property Ts As %TimeStamp [ Required ];

/// run.started | plan.updated | node.created | edge.created | node.status |
/// check.result | watermark.updated | approval.requested | approval.resolved |
/// agent.token | agent.note | agent.delta | run.finished | run.error (spec §14.2)
///
/// `agent.delta` is the assistant's reply as it is being written. It is the one
/// EPHEMERAL type in this log: the WS hub and GET /runs/:id/events both withhold
/// deltas from replay, because the `agent.note` that closes the turn carries the
/// same text whole and a reader that took both would render the answer twice.
/// The rows stay for audit, and ?deltas=1 serves them.
Property Type As %String(MAXLEN = 64) [ Required ];

/// Node id/name this event refers to, when applicable
Property NodeRef As %String(MAXLEN = 256);

Property PayloadJson As %String(MAXLEN = "");

Index RunSeqIdx On (Run, Seq) [ Unique ];

/// Append an event with a monotonic per-run Seq and persist it.
/// payload may be a %DynamicObject or "".
/// Returns the persisted Seq in seq.
ClassMethod Append(runId As %String, type As %String, nodeRef As %String = "", payload As %DynamicObject = {$$$NULLOREF}, Output seq As %Integer) As %Status
{
    Set sc = $$$OK
    Set seq = 0
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return $$$ERROR($$$GeneralError, "Run not found: " _ runId)
        }
        Set ev = ..%New()
        Set ev.Run = run
        Set ev.Seq = $Increment(^ETLWizard.EventSeq(runId))
        Set ev.Ts = $ZDateTime($ZTimeStamp, 3, , 3)
        Set ev.Type = type
        Set ev.NodeRef = nodeRef
        If $IsObject(payload) {
            Set ev.PayloadJson = payload.%ToJSON()
        } Else {
            Set ev.PayloadJson = "{}"
        }
        Set sc = ev.%Save()
        If $$$ISOK(sc) {
            Set seq = ev.Seq
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// Event envelope for the WS/SSE wire format (spec §14.2).
Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.seq = ..Seq
    Set json.ts = ..Ts
    Set json.runId = ..Run.%Id()
    Set json.type = ..Type
    If ..NodeRef '= "" {
        Set json.nodeRef = ..NodeRef
    }
    Try {
        Set json.payload = ##class(%DynamicObject).%FromJSON(..PayloadJson)
    } Catch {
        Set json.payload = {}
    }
    Return json
}

}
