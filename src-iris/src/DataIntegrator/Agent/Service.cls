/// Bridge between the REST layer and the agent: one wizard chat turn.
/// Keeps all %AI.* calls out of ETLWizard.API (spec §4.1 EAP caveat).
Class ETLWizard.Agent.Service Extends %RegisteredObject
{

/// Streaming defaults. Overridden per instance through ^ETLWizard.Agent -
/// see SetStreamConfig() - so it can be turned off, or retuned, without a
/// code change or a recompile.
Parameter STREAMDEFAULT = 1;

Parameter MINCHARSDEFAULT = 24;

Parameter MINMSDEFAULT = 250;

/// Run one chat turn for a wizard run. The user text and the agent reply are
/// appended to the event log, so the canvas/chat panel render them from the
/// same replayable stream as everything else.
///
/// With streaming on, the reply ALSO arrives as `agent.delta` events while the
/// model is still writing. The final `agent.note` is appended exactly as
/// before, so history, replay and anything else reading the log are unchanged -
/// the deltas are an addition to the stream, not a replacement for the record.
///
/// P0 NOTE: a fresh session per turn. Persisted %AI.Agent.Session reload
/// (Load(sessionId, provider)) + per-step checkpoints land in P1 (spec §4.1).
ClassMethod ChatTurn(runId As %String, text As %String) As %Status
{
    Set sc = $$$OK
    Try {
        // The user's own note carries the Seq that identifies this turn: the
        // deltas quote it, and the client uses it to put them in one place.
        Do ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "",
            {"role": "user", "text": (text)}, .turn)

        Set agent = ##class(ETLWizard.Agent.Architect).%New()
        Set sc = agent.%Init()
        If $$$ISERR(sc) {
            Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "",
                {"error": ("agent init failed: " _ $System.Status.GetErrorText(sc)),
                 "hint": "Run ##class(ETLWizard.Setup).ConfigureLocalProfile() or ConfigureCloudProfile() first"})
            Return sc
        }

        Set session = agent.CreateSession()
        // Tools need the runId; the INSTRUCTIONS tell the model to pass it through.
        Set prompt = "[runId=" _ runId _ "] " _ text

        Set cfg = ..StreamConfig()
        Set sink = $$$NULLOREF
        If cfg.enabled {
            Set sink = ##class(ETLWizard.Agent.StreamSink).%New()
            Do sink.Start(runId, turn, cfg.minChars, cfg.minMs)
            Set response = agent.StreamChat(session, prompt, sink, "OnChunk")
            Do sink.Finish()
        } Else {
            Set response = agent.Chat(session, prompt)
        }

        // The stream is what the user already read; Content is the record. They
        // agree for every provider tested, but a provider that streams and then
        // returns an empty Content would otherwise blank the answer on screen.
        Set answer = response.Content
        If (answer = "") && $IsObject(sink) {
            Set answer = sink.Text
        }
        Set note = {"role": "assistant", "text": (answer), "turn": (turn)}
        If $IsObject(sink) {
            Set note.stream = sink.Stats()
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "agent.note", "", note)
    } Catch ex {
        Set sc = ex.AsStatus()
        Do ##class(ETLWizard.Model.Event).Append(runId, "run.error", "",
            {"error": ($System.Status.GetErrorText(sc))})
    }
    Return sc
}

/// Current streaming settings.
ClassMethod StreamConfig() As %DynamicObject
{
    Set enabled = $Get(^ETLWizard.Agent("stream", "enabled"), ..#STREAMDEFAULT)
    Set minChars = +$Get(^ETLWizard.Agent("stream", "minChars"), ..#MINCHARSDEFAULT)
    Set minMs = +$Get(^ETLWizard.Agent("stream", "minMs"), ..#MINMSDEFAULT)
    Return {"enabled": (''enabled), "minChars": ($Select(minChars < 1: 1, 1: minChars)),
            "minMs": ($Select(minMs < 0: 0, 1: minMs))}
}

/// Turn streaming on or off and retune the batching, at runtime.
///   Do ##class(ETLWizard.Agent.Service).SetStreamConfig(0)          // off
///   Do ##class(ETLWizard.Agent.Service).SetStreamConfig(1, 48, 400) // coarser
ClassMethod SetStreamConfig(enabled As %Boolean = 1, minChars As %Integer = "", minMs As %Integer = "") As %DynamicObject
{
    Set ^ETLWizard.Agent("stream", "enabled") = ''enabled
    If minChars '= "" {
        Set ^ETLWizard.Agent("stream", "minChars") = +minChars
    }
    If minMs '= "" {
        Set ^ETLWizard.Agent("stream", "minMs") = +minMs
    }
    Return ..StreamConfig()
}

}
