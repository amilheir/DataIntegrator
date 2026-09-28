Include %occStatus

/// LINK-KG entity and relationship extraction for the Knowledge Graph tab
/// (mds/knowledge-graph-tab-plan.md §5.5).
///
/// Deliberately TOOL-FREE, like ETLWizard.Agent.SqlGen and for the same reason:
/// a focused single-purpose call is far faster and more reliable on a local
/// model than the 40-tool architect loop.
///
/// The LINK-KG part is the `known` registry. Each call is told which canonical
/// entities have already been found in this corpus, so the model reuses an
/// established name instead of inventing a variant - which is what stops one
/// real-world thing fragmenting into "Acme", "ACME Corp" and "Acme Corporation"
/// as three unrelated nodes.
Class ETLWizard.Agent.GraphExtract Extends %RegisteredObject
{

/// How many known entity names to feed back into a call. wikigraph sends 50;
/// beyond that the prompt grows faster than the benefit, and on a local model
/// every extra token is decode time.
Parameter MAXKNOWN = 50;

/// Characters of source text sent in one call.
Parameter MAXTEXT = 6000;

/// Extract from one chunk. `known` is a %DynamicArray of canonical names found
/// so far in this corpus. Returns a %DynamicObject:
///   {"entities": [{name, type, description, aliases[]}],
///    "relationships": [{source, predicate, target, description}],
///    "seconds": n}
/// or {"error": "..."}.
ClassMethod Extract(text As %String, label As %String = "", known As %DynamicArray = "") As %DynamicObject
{
    Try {
        Set text = $ZStrip(text, "<>W")
        If text = "" {
            Return {"entities": [], "relationships": []}
        }
        // The PROVIDER (endpoint, provider class) comes from the shared profile;
        // the MODEL is the KG tab's own choice. A third AI.LLM.* profile is not
        // possible on this build - see ETLWizard.KG.Setup.GetChatModel.
        Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizard", .provider, .model)
        If $$$ISERR(sc) {
            Return {"error": ("no LLM profile (AI.LLM.ETLWizard): " _ $System.Status.GetErrorText(sc))}
        }
        Set agent = ##class(%AI.Agent).%New(provider)
        Set model = ##class(ETLWizard.KG.Setup).GetExtractModel()
        // Without this the provider falls back to its own default and the call
        // dies with "model 'meta/llama-4-scout' not found".
        If model '= "" {
            Set agent.Model = model
        }
        Set start = $ZHorolog
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, ..Prompt(text, label, known))
        Set raw = $Select($IsObject(response): response.Content, 1: "")
        Set elapsed = ##class(ETLWizard.KG.Setup).Round($ZHorolog - start, 2)

        Set parsed = ..ParseJson(raw)
        If parsed.%Get("error", "") '= "" {
            Return parsed
        }
        Set parsed.seconds = elapsed
        Set parsed.model = model
        Return parsed
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// The extraction prompt. Asks for a canonical name, aliases FOR THE SAME
/// ENTITY ONLY, and a normalized type - the three things wikigraph found were
/// needed to keep the graph from fragmenting.
ClassMethod Prompt(text As %String, label As %String, known As %DynamicArray) As %String [ Internal ]
{
    Set nl = $Char(10)
    Set p = "You extract a knowledge graph from a short business record." _ nl _ nl

    If $IsObject(known) && (known.%Size() > 0) {
        Set list = ""
        Set iter = known.%GetIterator()
        Set n = 0
        While iter.%GetNext(, .name) {
            Set n = n + 1
            If n > ..#MAXKNOWN {
                Quit
            }
            Set list = list _ $Select(list = "": "", 1: ", ") _ name
        }
        // The LINK-KG instruction. Stated as a rule, not a hint: small models
        // treat a soft suggestion as optional and invent variants anyway.
        Set p = p _ "ENTITIES ALREADY KNOWN in this dataset: " _ list _ nl _
            "If this record mentions any of those, you MUST reuse the exact name above. " _
            "Do not invent a variant spelling of a known entity." _ nl _ nl
    }

    Set p = p _ "RULES" _ nl _
        "- entity name: the full canonical name, not a pronoun or a short form." _ nl _
        "- aliases: other surface forms OF THE SAME ENTITY found in this text. Never another entity's name." _ nl _
        "- type: one word, from Person, Organization, Product, Location, Event, Concept, Issue." _ nl _
        "- description: one short factual sentence drawn from the text only." _ nl _
        "- relationships: connect two entities you listed, with a short verb predicate." _ nl _
        "- extract only what the text states. Invent nothing." _ nl _
        "- reply with JSON only. No prose, no code fence." _ nl _ nl

    Set p = p _ "OUTPUT FORMAT" _ nl _
        "{""entities"":[{""name"":"""",""type"":"""",""description"":"""",""aliases"":[]}]," _
        """relationships"":[{""source"":"""",""predicate"":"""",""target"":"""",""description"":""""}]}" _ nl _ nl

    If $ZStrip(label, "<>W") '= "" {
        Set p = p _ "RECORD LABEL: " _ label _ nl
    }
    Set p = p _ "RECORD TEXT:" _ nl _ $Extract(text, 1, ..#MAXTEXT) _ nl
    Return p
}

/// Pull a JSON object out of whatever the model said. Small models wrap JSON in
/// code fences and some emit a <think> preamble, so neither is treated as an
/// error - but a reply with no object in it is.
ClassMethod ParseJson(raw As %String) As %DynamicObject [ Internal ]
{
    Set s = raw
    If s [ "</think>" {
        Set s = $Piece(s, "</think>", 2, *)
    }
    Set s = $Replace(s, "```json", "")
    Set s = $Replace(s, "```JSON", "")
    Set s = $Replace(s, "```", "")
    Set s = $ZStrip(s, "<>W")
    If s = "" {
        Return {"error": "the model returned nothing"}
    }

    // Three shapes seen from local models, all legitimate:
    //   {"entities": [...], "relationships": [...]}   - what the prompt asks for
    //   [ {...}, {...} ]                              - a bare list of entities
    //   {"name": ..., "type": ...}                    - a single entity
    // Scanning "first { to last }" handled only the first and silently
    // truncated the second into an unparseable fragment.
    Set parsed = ""
    Try {
        Set parsed = ##class(%DynamicAbstractObject).%FromJSON(s)
    } Catch {
        Set parsed = ""
    }
    If '$IsObject(parsed) {
        // trailing prose after the JSON: retry on the balanced outermost value
        Set trimmed = ..OutermostJson(s)
        If trimmed '= "" {
            Try {
                Set parsed = ##class(%DynamicAbstractObject).%FromJSON(trimmed)
            } Catch {
                Set parsed = ""
            }
        }
    }
    If '$IsObject(parsed) {
        Return {"error": ("the model's JSON did not parse: " _ $Extract(s, 1, 200))}
    }

    Set obj = {}
    If parsed.%IsA("%Library.DynamicArray") {
        Set obj.entities = parsed
    } ElseIf parsed.%Get("entities") = "" && (parsed.%Get("name", "") '= "") {
        Set one = []
        Do one.%Push(parsed)
        Set obj.entities = one
    } Else {
        Set obj = parsed
    }

    Set out = {"entities": [], "relationships": []}
    Set ents = obj.%Get("entities")
    If $IsObject(ents) {
        Set iter = ents.%GetIterator()
        While iter.%GetNext(, .e) {
            If '$IsObject(e) {
                Continue
            }
            Set name = $ZStrip(e.%Get("name", ""), "<>W")
            If name = "" {
                Continue
            }
            Do out.entities.%Push({
                "name": (name),
                "type": (..NormalizeType(e.%Get("type", ""))),
                "description": ($Extract($ZStrip(e.%Get("description", ""), "<>W"), 1, 4000)),
                "aliases": (..CleanAliases(e.%Get("aliases"), name))})
        }
    }
    Set rels = obj.%Get("relationships")
    If $IsObject(rels) {
        Set iter2 = rels.%GetIterator()
        While iter2.%GetNext(, .r) {
            If '$IsObject(r) {
                Continue
            }
            Set src = $ZStrip(r.%Get("source", ""), "<>W")
            Set tgt = $ZStrip(r.%Get("target", ""), "<>W")
            If (src = "") || (tgt = "") || (src = tgt) {
                Continue
            }
            Do out.relationships.%Push({
                "source": (src), "target": (tgt),
                "predicate": ($Extract($ZStrip(r.%Get("predicate", "relatedTo"), "<>W"), 1, 200)),
                "description": ($Extract($ZStrip(r.%Get("description", ""), "<>W"), 1, 4000))})
        }
    }
    Return out
}

/// The outermost balanced JSON value in a string, so trailing prose after a
/// complete object or array does not defeat the parse. Returns "" when there is
/// no balanced value.
ClassMethod OutermostJson(s As %String) As %String [ Internal ]
{
    Set startPos = 0
    For i = 1:1:$Length(s) {
        Set ch = $Extract(s, i)
        If (ch = "{") || (ch = "[") {
            Set startPos = i
            Quit
        }
    }
    If startPos = 0 {
        Return ""
    }
    Set opener = $Extract(s, startPos)
    Set closer = $Select(opener = "{": "}", 1: "]")
    Set depth = 0, inStr = 0, escaped = 0
    For i = startPos:1:$Length(s) {
        Set ch = $Extract(s, i)
        If escaped {
            Set escaped = 0
            Continue
        }
        If ch = "\\" {
            Set escaped = 1
            Continue
        }
        If ch = """" {
            Set inStr = 'inStr
            Continue
        }
        If inStr {
            Continue
        }
        If ch = opener {
            Set depth = depth + 1
        } ElseIf ch = closer {
            Set depth = depth - 1
            If depth = 0 {
                Return $Extract(s, startPos, i)
            }
        }
    }
    Return ""
}

/// Canonicalise the type. The same entity gets typed "ORGANIZATION" on one row
/// and "Organisation" on the next; identity is the NAME, and an uncontrolled
/// type would otherwise split the colouring of the graph for no reason.
ClassMethod NormalizeType(raw As %String) As %String [ Internal ]
{
    Set t = $ZConvert($ZStrip(raw, "<>W"), "L")
    Set t = $Piece(t, "/", 1)
    Set t = $Piece(t, "(", 1)
    Set t = $ZStrip(t, "<>W")
    If t = "" {
        Return "Concept"
    }
    If (t [ "person") || (t [ "people") || (t = "customer") || (t = "author") {
        Return "Person"
    }
    If (t [ "organi") || (t [ "company") || (t [ "brand") || (t [ "supplier") {
        Return "Organization"
    }
    If (t [ "product") || (t [ "item") || (t [ "goods") {
        Return "Product"
    }
    If (t [ "locat") || (t [ "place") || (t [ "countr") || (t [ "city") || (t [ "region") {
        Return "Location"
    }
    If (t [ "event") || (t [ "order") || (t [ "transaction") {
        Return "Event"
    }
    If (t [ "issue") || (t [ "problem") || (t [ "defect") || (t [ "complaint") || (t [ "error") {
        Return "Issue"
    }
    Return $ZConvert($Extract(t), "U") _ $Extract(t, 2, *)
}

/// Aliases, minus the junk. An alias equal to the entity's own name adds
/// nothing; an empty one is noise. The guard that an alias must not be ANOTHER
/// entity's canonical name cannot be applied here - it needs the whole batch -
/// and lives in the ingest, which has that view.
ClassMethod CleanAliases(raw As %DynamicArray, ownName As %String) As %DynamicArray [ Internal ]
{
    Set out = []
    If '$IsObject(raw) {
        Return out
    }
    Set seen = ","
    Set iter = raw.%GetIterator()
    While iter.%GetNext(, .a) {
        Set alias = $ZStrip(a, "<>W")
        If (alias = "") || ($ZConvert(alias, "U") = $ZConvert(ownName, "U")) {
            Continue
        }
        If seen [ ("," _ $ZConvert(alias, "U") _ ",") {
            Continue
        }
        Set seen = seen _ $ZConvert(alias, "U") _ ","
        Do out.%Push($Extract(alias, 1, 200))
    }
    Return out
}

}
