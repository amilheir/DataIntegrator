Include %occStatus

/// Batch embedding against Ollama's OpenAI-compatible /v1/embeddings endpoint
/// (mds/knowledge-graph-tab-plan.md §5.4).
///
/// Why this exists rather than the EMBEDDING datatype: an EMBEDDING column
/// vectorises one row per %Save, which is one HTTP round-trip per row. Measured
/// on this instance, that is ~247 ms; the same text in a batch of 32 costs
/// ~31 ms per row. Eight times faster is the difference between a demo and a
/// coffee break, so the vectors are written explicitly.
Class ETLWizard.KG.Embedder Extends %RegisteredObject
{

/// Batch size beyond which the request body gets unwieldy. 32 measured fastest
/// per row (31 ms); 128 was slower per row (39 ms), so bigger is not better.
Parameter MAXBATCH = 64;

/// Embed a batch of texts. `vectors` comes back as a %DynamicArray of
/// comma-separated strings, one per input, ready for TO_VECTOR(?, FLOAT, 1024).
/// Returns "" on success, else the reason.
///
/// Never returns a partial batch: a short or misordered reply is an error, not
/// something to paper over, because a vector silently attached to the wrong row
/// is undetectable afterwards.
ClassMethod Embed(texts As %DynamicArray, Output vectors As %DynamicArray) As %String
{
    Set vectors = []
    Try {
        If '$IsObject(texts) || (texts.%Size() = 0) {
            Return ""
        }
        If texts.%Size() > ..#MAXBATCH {
            Return "batch of " _ texts.%Size() _ " exceeds the maximum of " _ ..#MAXBATCH
        }
        Set err = ##class(ETLWizard.KG.Setup).EmbedEndpoint(.baseUrl, .model)
        If err '= "" {
            Return err
        }

        Set body = {}
        Set body.model = model
        Set body.input = texts

        Set req = ##class(%Net.HttpRequest).%New()
        Set req.Server = $Piece($Piece(baseUrl, "://", 2), ":", 1)
        Set req.Port = +$Piece($Piece(baseUrl, "://", 2), ":", 2)
        Set req.Https = ($Piece(baseUrl, "://", 1) = "https")
        Set req.ContentType = "application/json"
        Set req.Timeout = 300
        Do req.EntityBody.Write(body.%ToJSON())

        Set sc = req.Post("/v1/embeddings")
        If $$$ISERR(sc) {
            Return "embedding request failed: " _ $System.Status.GetErrorText(sc)
        }
        If req.HttpResponse.StatusCode '= 200 {
            Return "embedding endpoint returned HTTP " _ req.HttpResponse.StatusCode _
                " - is the model '" _ model _ "' pulled in Ollama?"
        }

        Set json = ##class(%DynamicAbstractObject).%FromJSON(req.HttpResponse.Data)
        Set data = json.%Get("data")
        If '$IsObject(data) {
            Return "embedding response carried no data array"
        }
        If data.%Size() '= texts.%Size() {
            Return "asked for " _ texts.%Size() _ " embeddings and got " _ data.%Size() _
                " - refusing to guess which text each belongs to"
        }
        Set dims = ##class(ETLWizard.KG.Setup).#EMBEDDIMS
        Set iter = data.%GetIterator()
        While iter.%GetNext(, .entry) {
            Set arr = entry.%Get("embedding")
            If '$IsObject(arr) || (arr.%Size() '= dims) {
                Return "embedding came back with " _ $Select($IsObject(arr): arr.%Size(), 1: 0) _
                    " dimensions, expected " _ dims
            }
            Do vectors.%Push(..ToVectorString(arr))
        }
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// A %DynamicArray of numbers as the comma-separated string TO_VECTOR wants.
/// No brackets: TO_VECTOR takes a bare list.
ClassMethod ToVectorString(arr As %DynamicArray) As %String [ Internal ]
{
    Set out = ""
    Set iter = arr.%GetIterator()
    While iter.%GetNext(, .value) {
        Set out = out _ $Select(out = "": "", 1: ",") _ value
    }
    Return out
}

/// Embed one string; convenience for a search query, where there is nothing to
/// batch. Returns "" in `vector` on failure, with the reason as the return.
ClassMethod EmbedOne(text As %String, Output vector As %String) As %String
{
    Set vector = ""
    Set batch = []
    Do batch.%Push(text)
    Set err = ..Embed(batch, .vectors)
    If err '= "" {
        Return err
    }
    If vectors.%Size() = 0 {
        Return "the embedding endpoint returned nothing"
    }
    Set vector = vectors.%Get(0)
    Return ""
}

/// Round-trip probe: embed two related texts and one unrelated one, and report
/// their cosine similarities. Used by the setup check to prove the whole chain -
/// model, config, VECTOR column, HNSW index - before any real ingest.
ClassMethod SelfTest() As %DynamicObject
{
    Try {
        Set texts = []
        Do texts.%Push("A soft cotton t-shirt in navy blue, machine washable.")
        Do texts.%Push("Navy blue tee made of soft cotton, washable in a machine.")
        Do texts.%Push("Quarterly depreciation schedule for warehouse forklifts.")
        Set start = $ZHorolog
        Set err = ..Embed(texts, .vectors)
        If err '= "" {
            Return {"error": (err)}
        }
        Set elapsed = $ZHorolog - start

        // cosine computed by IRIS itself, the same way a search will
        Set related = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT VECTOR_COSINE(TO_VECTOR(?, FLOAT, 1024), TO_VECTOR(?, FLOAT, 1024))",
            vectors.%Get(0), vectors.%Get(1))
        Set unrelated = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT VECTOR_COSINE(TO_VECTOR(?, FLOAT, 1024), TO_VECTOR(?, FLOAT, 1024))",
            vectors.%Get(0), vectors.%Get(2))
        Return {"ok": (''((+related > +unrelated) && (+related > 0.5))),
                "relatedScore": (+related), "unrelatedScore": (+unrelated),
                "seconds": (##class(ETLWizard.KG.Setup).Round(elapsed, 3)), "batch": (texts.%Size())}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

}
