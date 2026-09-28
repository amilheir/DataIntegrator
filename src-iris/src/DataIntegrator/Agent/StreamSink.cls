/// Batches an agent's token stream into something a client can watch.
///
/// WHERE the batched text goes is `Emit()`, and that is the only thing the two
/// chats differ in: the ETL agent appends `agent.delta` events to the run log
/// (this class), and the Knowledge Base chat updates its own Ask row
/// (ETLWizard.KG.AskSink). The batching and the reasoning filter - the parts
/// that are easy to get subtly wrong - are written once, here.
///
/// `%AI.Agent.StreamChat(session, input, callbackObj, callbackMethod)` calls
/// back once per chunk with a plain string - the same `OnChunk(chunk)` contract
/// `%AI.Shell.StreamRenderer` implements. Nothing else is required of the
/// object, so this one does the two things the shell renderer does not: it
/// batches, and it keeps reasoning out of what the user sees.
///
/// BATCHING IS NOT OPTIONAL. Every event is a persisted row with a sequence
/// number, and the WS hub replays that table; one row per token would put
/// thousands of rows behind every answer and drag the replay path down with
/// them. An append happens only when BOTH enough characters have accumulated
/// AND enough time has passed, so a fast model is batched and a slow one still
/// appears to move.
Class ETLWizard.Agent.StreamSink Extends %RegisteredObject
{

/// Run whose event log receives the deltas
Property RunId As %String;

/// Which turn these deltas belong to - the Seq of the user's own note. The
/// client coalesces deltas by this, and the final agent.note replaces them.
Property Turn As %Integer;

/// Visible text accumulated since the last append
Property Buffer As %String [ InitialExpression = "" ];

/// Text held back because it MIGHT be the start of a reasoning tag split
/// across two chunks - "</thi" at the end of one chunk and "nk>" at the start
/// of the next is one tag, and emitting the first half would print it.
Property Held As %String [ InitialExpression = "" ];

/// Inside a <think> span: everything is dropped until it closes
Property InThink As %Boolean [ InitialExpression = 0 ];

Property MinChars As %Integer [ InitialExpression = 24 ];

Property MinMs As %Integer [ InitialExpression = 250 ];

/// $ZHorolog of the last append, and of the start of the turn
Property LastAppend As %Numeric [ InitialExpression = 0 ];

Property StartH As %Numeric [ InitialExpression = 0 ];

/// measurements, reported on the final note
Property Deltas As %Integer [ InitialExpression = 0 ];

Property Chars As %Integer [ InitialExpression = 0 ];

Property FirstChunkMs As %Integer [ InitialExpression = -1 ];

/// Everything visible this turn, in order. The fallback for a provider whose
/// Response.Content comes back empty after a stream.
Property Text As %String [ InitialExpression = "" ];

/// The reasoning wrappers a local model may emit inline in its content. The
/// OpenAI-style separate `reasoning` field never reaches OnChunk at all - this
/// covers the models that put thinking in the content itself.
Parameter THINKOPEN = "<think>";

Parameter THINKCLOSE = "</think>";

Method Start(runId As %String, turn As %Integer, minChars As %Integer = 24, minMs As %Integer = 250)
{
    Set ..RunId = runId, ..Turn = turn
    Set ..MinChars = minChars, ..MinMs = minMs
    Set ..StartH = $ZHorolog, ..LastAppend = $ZHorolog
}

/// The callback %AI.Agent.StreamChat invokes per chunk.
Method OnChunk(chunk As %String)
{
    Try {
        If ..FirstChunkMs < 0 {
            Set ..FirstChunkMs = ..Elapsed(..StartH)
        }
        Set visible = ..Filter(chunk)
        If visible '= "" {
            Set ..Buffer = ..Buffer _ visible
            Set ..Text = ..Text _ visible
        }
        // Both conditions, never either: characters alone would append once per
        // token on a fast model, and time alone would append single characters
        // on a slow one.
        If ($Length(..Buffer) >= ..MinChars) && (..Elapsed(..LastAppend) >= ..MinMs) {
            Do ..Flush()
        }
    } Catch ex {
        // A failure here must never take down the turn: the answer still
        // arrives whole in the final record, streamed or not. Reported only
        // where there IS a run log - a sink writing somewhere else has none.
        If ..RunId '= "" {
            Do ##class(ETLWizard.Model.Event).Append(..RunId, "run.error", "",
                {"error": ("streaming callback failed: " _ ex.DisplayString()), "fatal": 0})
        }
    }
}

/// Hand the batched text on. Overridden per transport.
///
/// A DELTA, not the whole answer so far: the run log has a Seq and the hub
/// replays in order with a cursor, so ordered gap-free delivery is already
/// guaranteed and re-sending everything each time would be waste. A transport
/// WITHOUT that guarantee - polling, say - must emit cumulatively instead;
/// see ..Text, which is kept for exactly that.
Method Emit(text As %String)
{
    Do ##class(ETLWizard.Model.Event).Append(..RunId, "agent.delta", "",
        {"role": "assistant", "turn": (..Turn), "text": (text)})
}

/// Push whatever is buffered through Emit().
Method Flush()
{
    If ..Buffer = "" {
        Return
    }
    Do ..Emit(..Buffer)
    Set ..Deltas = ..Deltas + 1
    Set ..Chars = ..Chars + $Length(..Buffer)
    Set ..Buffer = ""
    Set ..LastAppend = $ZHorolog
}

/// End of turn: emit the tail, including anything held back as a possible
/// partial tag that turned out to be ordinary text.
Method Finish()
{
    If ..Held '= "" {
        If '..InThink {
            Set ..Buffer = ..Buffer _ ..Held
            Set ..Text = ..Text _ ..Held
        }
        Set ..Held = ""
    }
    Do ..Flush()
}

/// What this turn cost, for the final note.
Method Stats() As %DynamicObject
{
    Return {"deltas": (..Deltas), "chars": (..Chars),
            "ttftMs": (..FirstChunkMs), "totalMs": (..Elapsed(..StartH))}
}

/// Strip reasoning spans, and hold back a trailing fragment that could be the
/// first half of a tag. Returns the text that is safe to show.
Method Filter(chunk As %String) As %String [ Internal ]
{
    Set work = ..Held _ chunk
    Set ..Held = ""
    Set out = ""
    For {
        If work = "" {
            Quit
        }
        If ..InThink {
            Set at = $Find(work, ..#THINKCLOSE)
            If at = 0 {
                // still thinking - drop it, but keep a possible partial tag
                Set ..Held = ..TagTail(work)
                Quit
            }
            Set work = $Extract(work, at, *)
            Set ..InThink = 0
            Continue
        }
        Set at = $Find(work, ..#THINKOPEN)
        If at = 0 {
            Set tail = ..TagTail(work)
            Set out = out _ $Extract(work, 1, $Length(work) - $Length(tail))
            Set ..Held = tail
            Quit
        }
        Set out = out _ $Extract(work, 1, at - $Length(..#THINKOPEN) - 1)
        Set work = $Extract(work, at, *)
        Set ..InThink = 1
    }
    Return out
}

/// The trailing characters of `text` that form a proper prefix of either
/// reasoning tag, or "" when none does.
Method TagTail(text As %String) As %String [ Internal ]
{
    Set max = $Length(..#THINKCLOSE) - 1
    For n = max:-1:1 {
        Set tail = $Extract(text, * - n + 1, *)
        If tail = "" {
            Continue
        }
        If ($Extract(..#THINKOPEN, 1, n) = tail) || ($Extract(..#THINKCLOSE, 1, n) = tail) {
            Return tail
        }
    }
    Return ""
}

/// Milliseconds since a $ZHorolog reading. Guards the midnight rollover, which
/// would otherwise report a negative interval and append on every chunk.
Method Elapsed(since As %Numeric) As %Integer [ Internal ]
{
    Set ms = ($ZHorolog - since) * 1000
    Return $Select(ms < 0: 0, 1: ms \ 1)
}

}
