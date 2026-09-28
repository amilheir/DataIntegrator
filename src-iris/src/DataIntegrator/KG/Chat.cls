Include %occStatus

/// Grounded question-answering over an embedded corpus
/// (mds/knowledge-graph-tab-plan.md §9).
///
/// Asynchronous by necessity, the same way SqlGen is: the chat model answers in
/// tens of seconds and the webgateway gives up at ~60. Ask() writes a row and
/// JOBs the work; the UI polls. That also gives the chat its live status line
/// ("searching" -> "answering") for free, because the status IS the row.
///
/// Retrieval is deliberately simpler than wikigraph's: vector search over the
/// corpus, plus any entity whose name literally appears in the question, plus a
/// one-hop relationship expansion. wikigraph's entity-scoped narrowing
/// (scopeMargin/scopeFloor) is NOT ported, because its thresholds were tuned on
/// article paragraphs and the scores here bunch into 0.45-0.63 - a nonsense
/// question scores as high as a good one, so an absolute floor would cut real
/// answers and admit nonsense equally.
Class ETLWizard.KG.Chat Extends %RegisteredObject
{

/// Chunks handed to the model as context.
///
/// Every one of these is prefilled before the model writes a single token, and
/// on this hardware that prefill IS the wait: measured at 13.2 s of silence
/// followed by 0.6 s of streamed answer, with the model already resident. Ten
/// chunks of product prose is ~2,400 characters of context to answer a question
/// about one or two of them.
///
/// Five is the trade: the top five vector hits still carry the answer - the
/// scores here bunch into 0.45-0.63, so hits six to ten are rarely the ones
/// that matter - and the reader waits half as long to see anything. Raise it if
/// a corpus needs breadth more than it needs speed.
Parameter MAXCHUNKS = 5;

/// Relationship facts appended to the context.
Parameter MAXFACTS = 20;

/// How the answer is produced. "direct" posts to the provider's own
/// OpenAI-compatible endpoint; "agent" goes through %AI.Agent.StreamChat.
///
/// WHY THERE IS A CHOICE. The configured chat model (gemma4:e4b) is a THINKING
/// model: measured on this machine it spends ~400 tokens and ~13 s reasoning
/// before writing a 145-character answer, and %AI.Agent does not forward
/// reasoning to the stream callback - so the reader watches 13 s of nothing.
/// The endpoint accepts `reasoning_effort: "none"`, which cuts the same
/// question to ~1.9 s, but %AI.Agent has no way to pass it: session config
/// keys it does not recognise are dropped (verified - 9.5 s either way).
///
/// So the direct path exists for exactly one reason: to send that one field.
/// Everything else - the prompt, the model, the Ask row, the UI - is unchanged.
/// Set it back with SetChatMode("agent") to get the %AI.Agent path again.
Parameter CHATMODEDEFAULT = "direct";

/// How long to wait for the streaming endpoint's response headers. This is the
/// model-load wait (see AnswerStream), not a network round trip.
Parameter HEADERWAIT = 240;

ClassMethod GetChatMode() As %String
{
    Set mode = $Get(^ETLWizard.Agent("kgchat", "mode"))
    Return $Select(mode = "": ..#CHATMODEDEFAULT, 1: mode)
}

/// "direct" | "agent"
ClassMethod SetChatMode(mode As %String = "direct") As %String
{
    If (mode '= "direct") && (mode '= "agent") {
        Return "mode must be 'direct' or 'agent'"
    }
    Set ^ETLWizard.Agent("kgchat", "mode") = mode
    Return ""
}

/// Thinking budget asked of the provider on the direct path. "none" is what
/// makes the answer arrive in seconds rather than after a silent minute;
/// "low"/"medium"/"high" restore it if an answer needs the deliberation.
ClassMethod GetReasoningEffort() As %String
{
    Set v = $Get(^ETLWizard.Agent("kgchat", "reasoningEffort"))
    Return $Select(v = "": "none", 1: v)
}

ClassMethod SetReasoningEffort(effort As %String = "none") As %String
{
    Set ^ETLWizard.Agent("kgchat", "reasoningEffort") = effort
    Return ""
}

/// Queue a question. Returns {"id": n, "status": "pending"} immediately.
ClassMethod Ask(corpusId As %String, question As %String) As %DynamicObject
{
    Try {
        Set question = $ZStrip(question, "<>W")
        If question = "" {
            Return {"error": "ask something"}
        }
        If corpusId = "" {
            Return {"error": "pick which embedded data to ask about"}
        }
        Set res = ##class(ETLWizard.Tools.Util).RunDML(
            "INSERT INTO ETLW_KG.Ask (corpusRef, question, status, statusDetail, createdAt) " _
            "VALUES (?,?,'pending','queued',?)",
            corpusId, $Extract(question, 1, 2000), $ZDateTime($Horolog, 3))
        If $Extract(res, 1, 5) = "ERROR" {
            Return {"error": (res)}
        }
        Set id = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT TOP 1 %ID FROM ETLW_KG.Ask ORDER BY %ID DESC")
        Job ##class(ETLWizard.KG.Chat).Run(id)::5
        If '$Test {
            Do ..Mark(id, "error", "could not start the answering job")
        }
        Return ..Poll(id)
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// Job entry point. Never throws out: a failure has to land in the row, or the
/// UI polls a "searching" status forever.
ClassMethod Run(askId As %String)
{
    Try {
        Set row = ..Row(askId)
        If row.%Get("error", "") '= "" {
            Quit
        }
        Do ..Mark(askId, "searching", "finding the relevant records")
        Set ctx = ..Retrieve(row.corpusRef, row.question, .ctxErr)
        If ctxErr '= "" {
            Do ..Mark(askId, "error", ctxErr)
            Quit
        }
        If ctx.chunks.%Size() = 0 {
            Do ..Finish(askId, "There is nothing embedded in this knowledge base yet, so I have nothing to answer from.", ctx)
            Quit
        }
        Do ..Mark(askId, "answering", "writing the answer")
        Set answer = ..Generate(row.question, ctx, .genErr, askId)
        If genErr '= "" {
            Do ..Mark(askId, "error", genErr)
            Quit
        }
        Do ..Finish(askId, answer, ctx)
    } Catch ex {
        Do ..Mark(askId, "error", ex.DisplayString())
    }
    Quit
}

/// Chunks by vector similarity, entities named in the question, and one hop of
/// relationships out from those entities.
ClassMethod Retrieve(corpusId As %String, question As %String, Output err As %String) As %DynamicObject [ Internal ]
{
    Set err = ""
    Set out = {"chunks": [], "entities": [], "facts": []}
    Try {
        Set err = ##class(ETLWizard.KG.Embedder).EmbedOne(question, .vector)
        If err '= "" {
            Return out
        }
        Set type = ##class(ETLWizard.KG.Setup).#EMBEDTYPE
        Set dims = ##class(ETLWizard.KG.Setup).#EMBEDDIMS

        Set stmt = ##class(%SQL.Statement).%New()
        // ODBC mode - VECTOR_COSINE is a DOUBLE and reads back as its raw
        // internal form in the default logical mode.
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare("SELECT TOP " _ ..#MAXCHUNKS _ " c.chunkText, d.label, " _
            "VECTOR_COSINE(c.chunkVector, TO_VECTOR(?, " _ type _ ", " _ dims _ ")) AS score " _
            "FROM ETLW_KG.Chunk c JOIN ETLW_KG.Doc d ON c.docRef = d.%ID " _
            "WHERE c.corpusRef = ? ORDER BY score DESC")
        If $$$ISERR(sc) {
            Set err = $System.Status.GetErrorText(sc)
            Return out
        }
        Set rs = stmt.%Execute(vector, corpusId)
        Set seen = ","
        While rs.%Next() {
            Set text = rs.%GetData(1)
            // The source table can hold the same row twice; two identical
            // chunks in a ten-chunk context waste a slot and tell the model
            // nothing new.
            If seen [ ("," _ $ZConvert(text, "U") _ ",") {
                Continue
            }
            Set seen = seen _ $ZConvert(text, "U") _ ","
            Do out.chunks.%Push({"text": (text), "label": (rs.%GetData(2)),
                                 "score": (##class(ETLWizard.KG.Setup).Round(rs.%GetData(3), 4))})
        }

        // Entities named outright in the question. Cheap, and it rescues the
        // case where a name embeds weakly but is stated word for word.
        Set upperQ = $ZConvert(question, "U")
        Set stmt2 = ##class(%SQL.Statement).%New()
        Set sc2 = stmt2.%Prepare("SELECT %ID, entityName, entityType, description FROM ETLW_KG.Entity WHERE corpusRef = ?")
        If $$$ISOK(sc2) {
            Set rs2 = stmt2.%Execute(corpusId)
            Set hitIds = ","
            While rs2.%Next() {
                Set name = rs2.%GetData(2)
                If (name = "") || (upperQ '[ $ZConvert(name, "U")) {
                    Continue
                }
                Set hitIds = hitIds _ rs2.%GetData(1) _ ","
                Do out.entities.%Push({"name": (name), "type": (rs2.%GetData(3)),
                                       "description": (rs2.%GetData(4))})
            }
            If hitIds '= "," {
                Do ..AddFacts(corpusId, hitIds, out)
            }
        }
    } Catch ex {
        Set err = ex.DisplayString()
    }
    Return out
}

/// One hop out: relationships touching any matched entity, as readable triples.
ClassMethod AddFacts(corpusId As %String, hitIds As %String, ctx As %DynamicObject) [ Internal ]
{
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("SELECT TOP " _ ..#MAXFACTS _ " s.entityName, r.predicate, t.entityName " _
        "FROM ETLW_KG.Relationship r " _
        "JOIN ETLW_KG.Entity s ON r.sourceEntityRef = s.%ID " _
        "JOIN ETLW_KG.Entity t ON r.targetEntityRef = t.%ID " _
        "WHERE r.corpusRef = ?")
    If $$$ISERR(sc) {
        Quit
    }
    Set rs = stmt.%Execute(corpusId)
    While rs.%Next() {
        Do ctx.facts.%Push(rs.%GetData(1) _ " " _ rs.%GetData(2) _ " " _ rs.%GetData(3))
    }
    Quit
}

/// Ask the chat model, grounded in the retrieved context.
/// `askId` is where the answer is streamed as it is written. Passing "" keeps
/// the old blocking behaviour, which is also what the streaming switch selects.
ClassMethod Generate(question As %String, ctx As %DynamicObject, Output err As %String, askId As %String = "") As %String [ Internal ]
{
    Set err = ""
    Try {
        Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizard", .provider, .model)
        If $$$ISERR(sc) {
            Set err = "no LLM profile (AI.LLM.ETLWizard): " _ $System.Status.GetErrorText(sc)
            Return ""
        }
        // The CHAT model, not the extraction model - they are separate roles
        // and cannot be GPU-resident together.
        Set chatModel = ##class(ETLWizard.KG.Setup).GetChatModel()
        Set agent = ##class(%AI.Agent).%New(provider)
        If chatModel '= "" {
            Set agent.Model = chatModel
        }
        Set nl = $Char(10)
        Set p = "Answer the question using ONLY the records below." _ nl _
            "If they do not contain the answer, say so plainly - do not guess." _ nl _
            "Be brief. Refer to the records by their label where it helps." _ nl _ nl _ "RECORDS" _ nl
        Set iter = ctx.chunks.%GetIterator()
        While iter.%GetNext(, .c) {
            Set p = p _ "- " _ $Select(c.label = "": "", 1: "[" _ c.label _ "] ") _ c.text _ nl
        }
        If ctx.facts.%Size() > 0 {
            Set p = p _ nl _ "KNOWN FACTS" _ nl
            Set fIter = ctx.facts.%GetIterator()
            While fIter.%GetNext(, .f) {
                Set p = p _ "- " _ f _ nl
            }
        }
        Set p = p _ nl _ "QUESTION: " _ question _ nl

        If ..GetChatMode() = "direct" {
            Set cfg = ##class(ETLWizard.Agent.Service).StreamConfig()
            If cfg.enabled {
                Return ..AnswerStream(p, askId, cfg, .err)
            }
            Return ..Answer(p, askId, .err)
        }

        Set session = agent.CreateSession()

        // Same switch as the ETL agent's chat: one setting turns streaming off
        // everywhere. StreamChat returns the same %AI.LLM.Response as Chat, so
        // everything below this is unchanged either way.
        Set cfg = ##class(ETLWizard.Agent.Service).StreamConfig()
        Set sink = $$$NULLOREF
        If cfg.enabled && (askId '= "") {
            Set sink = ##class(ETLWizard.KG.AskSink).%New()
            Do sink.StartAsk(askId, cfg.minChars, cfg.minMs)
            Set response = agent.StreamChat(session, p, sink, "OnChunk")
            Do sink.Finish()
        } Else {
            Set response = agent.Chat(session, p)
        }
        Set answer = $Select($IsObject(response): response.Content, 1: "")
        // a provider that streamed but returned nothing would otherwise blank
        // an answer the reader has already watched arrive
        If ($ZStrip(answer, "<>W") = "") && $IsObject(sink) {
            Set answer = sink.Text
        }
        If $ZStrip(answer, "<>W") = "" {
            Set err = "the model returned an empty answer"
            Return ""
        }
        // some small models emit a hidden reasoning preamble
        If answer [ "</think>" {
            Set answer = $Piece(answer, "</think>", 2, *)
        }
        Return $ZStrip(answer, "<>W")
    } Catch ex {
        Set err = ex.DisplayString()
        Return ""
    }
}

/// Ask the provider's OpenAI-compatible endpoint directly, so the request can
/// carry `reasoning_effort`. Returns the answer, or "" with err set.
///
/// Not streamed, and deliberately so: with thinking off the whole answer lands
/// in about two seconds, which is faster than the FIRST TOKEN of the thinking
/// path. Streaming two seconds of text buys nothing and would mean parsing SSE
/// out of a buffered HTTP client. The answer is still written to answerSoFar
/// the moment it arrives, so the UI's streaming render path is unchanged.
ClassMethod Answer(prompt As %String, askId As %String, Output err As %String) As %String [ Internal ]
{
    Set err = ""
    Try {
        Set err = ..Endpoint(.baseUrl, .model)
        If err '= "" {
            Return ""
        }
        Set body = {"stream": false}
        Set body.model = model
        Set body.messages = [{"role": "user", "content": (prompt)}]
        Set effort = ..GetReasoningEffort()
        If effort '= "" {
            Do body.%Set("reasoning_effort", effort)
        }

        Set req = ##class(%Net.HttpRequest).%New()
        Set req.Server = $Piece($Piece(baseUrl, "://", 2), ":", 1)
        Set req.Port = +$Piece($Piece(baseUrl, "://", 2), ":", 2)
        Set req.Https = ($Piece(baseUrl, "://", 1) = "https")
        // UTF-8 on both legs, for the same reason AnswerStream() does it: the
        // entity body is a BINARY stream, so an accented prompt written as
        // characters goes out as single bytes that are not valid UTF-8, and
        // Ollama substitutes U+FFFD for each one - the record comes back quoted
        // with its accents replaced by question marks. ContentCharset is left
        // alone deliberately: the bytes are already encoded here, and setting it
        // would encode them a second time.
        Set req.ContentType = "application/json; charset=utf-8"
        Set req.Timeout = 300
        Do req.EntityBody.Write($ZConvert(body.%ToJSON(), "O", "UTF8"))

        Set sc = req.Post("/v1/chat/completions")
        If $$$ISERR(sc) {
            Set err = "the chat model could not be reached: " _ $System.Status.GetErrorText(sc)
            Return ""
        }
        If req.HttpResponse.StatusCode '= 200 {
            Set err = "the chat endpoint returned HTTP " _ req.HttpResponse.StatusCode _
                " - is the model '" _ model _ "' pulled in Ollama?"
            Return ""
        }
        // Ollama answers "Content-Type: application/json" with no charset, so
        // %Net hands back undecoded bytes; decode them before parsing or every
        // multi-byte character arrives as one character per byte.
        Set raw = ""
        While 'req.HttpResponse.Data.AtEnd {
            Set raw = raw _ req.HttpResponse.Data.Read(32000)
        }
        Set json = ##class(%DynamicAbstractObject).%FromJSON($ZConvert(raw, "I", "UTF8"))
        Set choices = json.%Get("choices")
        If '$IsObject(choices) || (choices.%Size() = 0) {
            Set err = "the chat model returned no choices"
            Return ""
        }
        Set answer = choices.%Get(0).message.%Get("content", "")
        // A model that ignores reasoning_effort puts its thinking inline; the
        // reasoning FIELD beside the content is simply not read.
        If answer [ "</think>" {
            Set answer = $Piece(answer, "</think>", 2, *)
        }
        Set answer = $ZStrip(answer, "<>W")
        If answer = "" {
            Set err = "the model returned an empty answer"
            Return ""
        }
        If askId '= "" {
            Do ##class(ETLWizard.Tools.Util).RunDML(
                "UPDATE ETLW_KG.Ask SET answerSoFar = ?, updatedAt = ? WHERE %ID = ?",
                $Extract(answer, 1, 30000), $ZDateTime($Horolog, 3), askId)
        }
        Return answer
    } Catch ex {
        Set err = ex.DisplayString()
        Return ""
    }
}

/// The streaming direct path: the same request as Answer(), with stream:true,
/// read off the socket as it arrives.
///
/// This talks TCP by hand rather than through %Net.HttpRequest, and the reason
/// is narrow: %Net.HttpRequest does not return until the whole response is
/// buffered, which is the one thing a stream must not do. Everything else here
/// is ordinary - the batching, the reasoning filter and the cumulative write to
/// answerSoFar are the same AskSink the %AI.Agent path uses.
///
/// `reasoning_effort` is why this path exists at all: %AI.Agent drops the field
/// at both the session and the provider level (verified - the model kept
/// thinking, 223 tokens for a one-line answer), and with it the same question
/// goes from 13 s to under 2 s.
ClassMethod AnswerStream(prompt As %String, askId As %String, cfg As %DynamicObject, Output err As %String) As %String [ Internal ]
{
    Set err = "", dev = "", opened = 0
    Set io = $IO
    Try {
        Set err = ..Endpoint(.baseUrl, .model)
        If err '= "" {
            Return ""
        }
        Set scheme = $Piece(baseUrl, "://", 1)
        Set hostPort = $Piece(baseUrl, "://", 2)
        Set host = $Piece($Piece(hostPort, "/", 1), ":", 1)
        Set port = +$Piece($Piece(hostPort, "/", 1), ":", 2)
        If port = 0 {
            Set port = $Select(scheme = "https": 443, 1: 80)
        }
        If scheme = "https" {
            // no TLS on a hand-rolled socket; the buffered path still works
            Return ..Answer(prompt, askId, .err)
        }

        Set body = {"stream": true}
        Set body.model = model
        Set body.messages = [{"role": "user", "content": (prompt)}]
        Set effort = ..GetReasoningEffort()
        If effort '= "" {
            Do body.%Set("reasoning_effort", effort)
        }
        // JSON is UTF-8 by definition, and this socket carries BYTES - it is
        // opened with no translation, so whatever is written goes out as it
        // stands. Encoding here (rather than relying on the device) keeps
        // Content-Length honest: it must count bytes, and $Length() counts
        // CHARACTERS, so an accented prompt would under-declare its own body
        // and the request would be truncated at the far end.
        Set json = $ZConvert(body.%ToJSON(), "O", "UTF8")

        Set crlf = $Char(13, 10)
        Set req = "POST /v1/chat/completions HTTP/1.1" _ crlf _
            "Host: " _ host _ ":" _ port _ crlf _
            "Content-Type: application/json; charset=utf-8" _ crlf _
            "Accept: text/event-stream" _ crlf _
            "Content-Length: " _ $Length(json) _ crlf _
            "Connection: close" _ crlf _ crlf _ json

        Set sink = ##class(ETLWizard.KG.AskSink).%New()
        Do sink.StartAsk(askId, cfg.minChars, cfg.minMs)

        Set dev = "|TCP|" _ $Job
        Open dev:(host:port:"M"):5
        If '$Test {
            Set err = "could not reach the chat model at " _ host _ ":" _ port
            Return ""
        }
        Set opened = 1
        Use dev
        Write req, *-3

        // Headers, up to the blank line that ends them.
        //
        // The header wait is the MODEL LOAD wait, not a network wait: Ollama
        // sends nothing until the model is resident, and a cold 9.6 GB model
        // with layers spilling to CPU takes ~33 s to first byte on this box.
        // At the 30 s this used to be, the first question after any restart
        // failed with "the chat model did not respond" while the load was
        // seconds from finishing - and the load then completed, so the NEXT
        // question worked and the failure looked random. #HEADERWAIT is
        // deliberately near the buffered path's own 300 s timeout; a model that
        // is genuinely absent fails fast on the Open above instead.
        // "answering" is the status Run() already set; only the detail changes,
        // which is what the UI shows in the live bubble. A NEW status value
        // would not be one Poll() counts as done and would be dead weight.
        Do ..Mark(askId, "answering", "waiting for the chat model (a cold model takes up to a minute to load)")
        Set lines = 0
        For {
            Read line:..#HEADERWAIT
            If '$Test {
                Set err = "the chat model did not send a reply within " _ ..#HEADERWAIT _
                    "s - it may still be loading; ask again in a moment"
                Quit
            }
            Set line = $ZStrip(line, "*", $Char(13))
            If lines = 0 {
                Set status = +$Piece(line, " ", 2)
                If (status '= 200) && (status '= 0) {
                    Set err = "the chat endpoint returned HTTP " _ status
                    Quit
                }
            }
            Set lines = lines + 1
            If line = "" {
                Quit
            }
        }
        If err '= "" {
            Quit
        }

        // The stream. Chunked framing and SSE share the line structure here:
        // a hex chunk size, a `data:` line, a blank. Only `data:` lines carry
        // anything, so the rest can simply be ignored rather than parsed.
        For {
            Read line:60
            If '$Test {
                Quit
            }
            Set line = $ZStrip(line, "*", $Char(13))
            If $Extract(line, 1, 6) '= "data: " {
                Continue
            }
            Set payload = $Extract(line, 7, *)
            If payload = "[DONE]" {
                Quit
            }
            Set ev = ""
            Try {
                // Decode UTF-8 -> characters BEFORE parsing. Without this every
                // byte of a multi-byte character became a character of its own
                // and "comunicacao" (with a cedilla and a tilde) was stored, and
                // shown, as "comunicaAAo" with the bytes spelled out. The
                // buffered Answer() path never had this because %Net.HttpRequest
                // decodes the response for it; this socket does not.
                Set ev = ##class(%DynamicObject).%FromJSON($ZConvert(payload, "I", "UTF8"))
            } Catch {
                // a chunk boundary split the JSON - or, now, split a character
                // mid-sequence: the piece is unusable on its own and the next
                // delta carries on, so drop it rather than guess at the text it
                // contained
                Continue
            }
            Set choices = ev.%Get("choices")
            If '$IsObject(choices) || (choices.%Size() = 0) {
                Continue
            }
            Set delta = choices.%Get(0).%Get("delta")
            If '$IsObject(delta) {
                Continue
            }
            // `content` only. A model that ignores reasoning_effort puts its
            // thinking in `reasoning`, and that is never read here.
            Set piece = delta.%Get("content", "")
            If piece '= "" {
                Do sink.OnChunk(piece)
            }
        }
        Do sink.Finish()
        Set answer = $ZStrip(sink.Text, "<>W")
        If answer = "" {
            Set err = "the model returned an empty answer"
        }
    } Catch ex {
        // <ENDOFFILE> is how a closed connection arrives, and by then the
        // answer is already complete - it is the normal end of this loop.
        If ex.Name '[ "ENDOFFILE" {
            Set err = ex.DisplayString()
        } Else {
            Try {
                Do sink.Finish()
                Set answer = $ZStrip(sink.Text, "<>W")
            } Catch {
            }
        }
    }
    If opened {
        Try {
            Close dev
        } Catch {
        }
    }
    Use io
    If (err = "") && ($Get(answer) = "") {
        Set err = "the model returned an empty answer"
    }
    Return $Get(answer)
}

/// Base URL and model for the chat profile, read from the same Config Store
/// entry the agent path uses - one source of truth for where the LLM lives.
ClassMethod Endpoint(Output baseUrl As %String, Output model As %String) As %String [ Internal ]
{
    Set baseUrl = "", model = ""
    Set sc = ##class(%ConfigStore.Configuration).GetDetails("AI.LLM.ETLWizard", .details, 0, 1)
    If $$$ISERR(sc) {
        Return "no LLM profile (AI.LLM.ETLWizard): " _ $System.Status.GetErrorText(sc)
    }
    Set baseUrl = details.%Get("base_url", "")
    If baseUrl = "" {
        Return "the LLM profile has no base_url - the direct chat path needs one " _
            "(use ##class(ETLWizard.KG.Chat).SetChatMode(""agent"") for a provider without one)"
    }
    Set model = ##class(ETLWizard.KG.Setup).GetChatModel()
    If model = "" {
        Set model = details.%Get("model", "")
    }
    Return ""
}

// ------------------------------------------------------------------ state

ClassMethod Mark(askId As %String, status As %String, detail As %String) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Ask SET status = ?, statusDetail = ?, updatedAt = ? WHERE %ID = ?",
        status, $Extract(detail, 1, 1000), $ZDateTime($Horolog, 3), askId)
}

ClassMethod Finish(askId As %String, answer As %String, ctx As %DynamicObject) [ Internal ]
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Ask SET status = 'done', statusDetail = 'answered', answer = ?, hits = ?, updatedAt = ? WHERE %ID = ?",
        $Extract(answer, 1, 30000), $Extract(ctx.%ToJSON(), 1, 30000), $ZDateTime($Horolog, 3), askId)
}

ClassMethod Row(askId As %String) As %DynamicObject [ Internal ]
{
    Set stmt = ##class(%SQL.Statement).%New()
    Set stmt.%SelectMode = 1
    Set sc = stmt.%Prepare("SELECT %ID, corpusRef, question, status, statusDetail, answer, hits, answerSoFar FROM ETLW_KG.Ask WHERE %ID = ?")
    If $$$ISERR(sc) {
        Return {"error": ($System.Status.GetErrorText(sc))}
    }
    Set rs = stmt.%Execute(askId)
    If 'rs.%Next() {
        Return {"error": "not found"}
    }
    Return {"id": (rs.%GetData(1)), "corpusRef": (rs.%GetData(2)), "question": (rs.%GetData(3)),
            "status": (rs.%GetData(4)), "statusDetail": (rs.%GetData(5)),
            "answer": (rs.%GetData(6)), "hitsJson": (rs.%GetData(7)),
            "answerSoFar": (rs.%GetData(8))}
}

/// What the UI polls.
ClassMethod Poll(askId As %String) As %DynamicObject
{
    Set row = ..Row(askId)
    If row.%Get("error", "") '= "" {
        Return row
    }
    Set row.done = ''((row.status = "done") || (row.status = "error"))
    Try {
        If row.hitsJson '= "" {
            Set row.hits = ##class(%DynamicAbstractObject).%FromJSON(row.hitsJson)
        }
    } Catch {
    }
    Do row.%Remove("hitsJson")
    Return row
}

}
