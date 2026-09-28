Include %cspInclude

/// WebSocket event fan-out per run (spec §5, §14.1).
/// Protocol: on connect the client sends {"runId":"...","lastSeq":0}; the hub
/// replays persisted events with Seq > lastSeq, then switches to live push.
/// The canvas is a pure projection of the persisted ETLWizard.Model.Event log,
/// so a reconnecting client is always consistent (spec §23.3).
///
/// P0 note: live push is poll-based over the event table (the persisted log IS
/// the bus). Interprocess signalling can replace the poll later without any
/// protocol change.
Class ETLWizard.WS.Hub Extends %CSP.WebSocket
{

/// Run this socket is subscribed to
Property RunId As %String;

/// Replay/live cursor — last Seq pushed to this client
Property LastSeq As %Integer [ InitialExpression = 0 ];

/// True until the first catch-up pass has run.
///
/// This is what keeps a streamed answer from rendering twice. `agent.delta`
/// events are the answer being typed; the `agent.note` that follows is the
/// same answer, whole. A client replaying the log from a cursor would receive
/// both and render both, so the deltas are treated as EPHEMERAL: they are
/// pushed only to a client that is already live, never replayed. The durable
/// record is, and stays, the note.
///
/// The alternative - having the client coalesce - was rejected as the primary
/// mechanism because it puts correctness in every future reader of the log
/// rather than in one place. The client coalesces anyway, because a client
/// connecting MID-turn still sees the tail of the deltas, but it never has to
/// undo a full replay.
Property Replaying As %Boolean [ InitialExpression = 1 ];

/// Seconds between live-push polls. The persisted log is the bus, so this tick
/// bounds how fast anything - a node status, a streamed token - can reach the
/// client: what arrives is max(producer interval, this). It was 1s, which made
/// any batching finer than a second pointless; 0.25s is four checks a second
/// against one indexed query on a table the client is reading anyway.
/// Overridable at runtime: Set ^ETLWizard.Agent("ws","tick") = 0.5
Parameter TICKDEFAULT = 0.25;

Method OnPreServer() As %Status
{
    Set ..SharedConnection = 0
    Return $$$OK
}

Method Server() As %Status
{
    Set sc = $$$OK
    Try {
        // First frame: subscription {"runId":"...","lastSeq":n}
        Set data = ..Read(.size, .sc, 30)
        If $$$ISERR(sc) {
            Do ..EndServer()
            Return $$$OK
        }
        Set sub = {}
        Try {
            Set sub = ##class(%DynamicObject).%FromJSON(data)
        } Catch {
            Do ..Write({"type":"error","error":"invalid subscription JSON"}.%ToJSON())
            Do ..EndServer()
            Return $$$OK
        }
        Set ..RunId = sub.runId
        Set ..LastSeq = +sub.lastSeq

        Set run = ##class(ETLWizard.Model.Run).%OpenId(..RunId)
        If '$IsObject(run) {
            Do ..Write({"type":"error","error":("run not found: " _ ..RunId)}.%ToJSON())
            Do ..EndServer()
            Return $$$OK
        }

        Do ..Write({"type":"subscribed","runId":(..RunId),"lastSeq":(..LastSeq)}.%ToJSON())

        // Replay + live loop: push anything newer than the cursor, then use a
        // short Read timeout as the poll tick. Client frames are optional
        // ({"type":"ack"} keep-alives are ignored).
        Set tick = +$Get(^ETLWizard.Agent("ws", "tick"), ..#TICKDEFAULT)
        If (tick <= 0) || (tick > 5) {
            Set tick = ..#TICKDEFAULT
        }
        For {
            Do ..PushPending()
            Set data = ..Read(.size, .sc, tick)
            If $$$ISERR(sc) {
                If $$$GETERRORCODE(sc) = $$$CSPWebSocketClosed {
                    Quit
                }
                If $$$GETERRORCODE(sc) '= $$$CSPWebSocketTimeout {
                    Quit
                }
                // timeout: normal poll tick
            }
        }
        Do ..EndServer()
    } Catch ex {
        Set sc = ex.AsStatus()
        Try {
            Do ..EndServer()
        } Catch {
        }
    }
    Return $$$OK
}

/// Push all persisted events for RunId with Seq > LastSeq, in order.
///
/// On the FIRST pass (the replay) `agent.delta` rows are skipped - but the
/// cursor still advances past them, or the next pass would deliver the very
/// rows this one decided not to send.
Method PushPending() As %Status
{
    Set sc = $$$OK
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT ID FROM ETLWizard_Model.Event WHERE Run = ? AND Seq > ? ORDER BY Seq")
        If $$$ISERR(sc) {
            Return sc
        }
        Set rs = stmt.%Execute(..RunId, ..LastSeq)
        If rs.%SQLCODE < 0 {
            Return $$$ERROR($$$GeneralError, "event query failed: SQLCODE " _ rs.%SQLCODE)
        }
        While rs.%Next() {
            Set ev = ##class(ETLWizard.Model.Event).%OpenId(rs.ID)
            If '$IsObject(ev) {
                Continue
            }
            If '(..Replaying && (ev.Type = "agent.delta")) {
                Do ..Write(ev.ToJSON().%ToJSON())
            }
            Set ..LastSeq = ev.Seq
        }
        Set ..Replaying = 0
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

}
