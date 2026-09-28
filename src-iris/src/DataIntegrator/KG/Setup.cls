Include %occStatus

/// Knowledge Graph tab: one-time setup (mds/knowledge-graph-tab-plan.md §3, §4).
///
/// Creates the %Embedding.Config row that names the embedding model and endpoint,
/// and the ETLW_KG schema. Both idempotent, both called from iris.script so a
/// clean rebuild comes up ready.
Class ETLWizard.KG.Setup Extends %RegisteredObject
{

/// Name of the %Embedding.Config entry. Vectors are written by our own batch
/// embedder rather than by the EMBEDDING datatype, but the config row stays the
/// single source of truth for WHICH model and endpoint - the same discipline
/// wikigraph uses, so the model can never be changed in one place only.
Parameter EMBEDCONFIG = "etlembed";

/// %Embedding.OpenAI.IsValidConfig demands an existing SSL config name even when
/// the call is plain HTTP (httpConfig sets Https=0). This is that dummy.
Parameter OLLAMASSL = "OllamaDummySSL";

Parameter EMBEDMODEL = "leoipulsar/harrier-0.6b:latest";

/// Vector length of the embedding model. Every TO_VECTOR in this feature must
/// agree with this and with the column DDL, or SQLCODE -259 fires at query time.
Parameter EMBEDDIMS = 1024;

/// Vector element type. Measured against this model's output and fixed here:
/// mixing FLOAT and DOUBLE raises "vectors of different datatypes".
Parameter EMBEDTYPE = "FLOAT";

/// Everything: embedding config then schema. Safe to re-run.
ClassMethod Install(verbose As %Boolean = 1) As %String
{
    Set err = ..CreateEmbeddingConfig()
    If err '= "" {
        Return "ERROR: " _ err
    }
    If verbose {
        Write "embedding config '", ..#EMBEDCONFIG, "' ready", !
    }
    Set err = ..CreateSchema(verbose)
    If err '= "" {
        Return "ERROR: " _ err
    }
    Return ""
}

/// Register the embedding model with IRIS. Returns "" or the reason.
ClassMethod CreateEmbeddingConfig() As %String
{
    Try {
        New $Namespace
        Set here = $Namespace
        Set $Namespace = "%SYS"
        If '##class(Security.SSLConfigs).Exists(..#OLLAMASSL) {
            Set sc = ##class(Security.SSLConfigs).Create(..#OLLAMASSL)
            If $$$ISERR(sc) {
                Return "could not create the dummy SSL config: " _ $System.Status.GetErrorText(sc)
            }
        }
        Set $Namespace = here

        Set exists = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT COUNT(*) FROM %Embedding.Config WHERE Name = ?", ..#EMBEDCONFIG)
        If +exists > 0 {
            Return ""
        }

        Set model = $System.Util.GetEnviron("EMBEDDING_MODEL")
        If model = "" {
            Set model = ..#EMBEDMODEL
        }
        Set host = $System.Util.GetEnviron("OLLAMA_HOST")
        If host = "" {
            Set host = "ollama"
        }
        Set port = $System.Util.GetEnviron("OLLAMA_PORT")
        If port = "" {
            Set port = 11434
        }
        Set config = {"modelName": (model), "apiKey": "ollama",
                      "sslConfig": (..#OLLAMASSL), "checkTokenCount": false}
        Set config.httpConfig = {"Server": (host), "Https": 0}
        Set config.httpConfig.Port = +port

        Set res = ##class(ETLWizard.Tools.Util).RunDML(
            "INSERT INTO %Embedding.Config (Name, Configuration, EmbeddingClass, VectorLength, Description) " _
            "VALUES (?, ?, ?, ?, ?)",
            ..#EMBEDCONFIG, config.%ToJSON(), "%Embedding.OpenAI", ..#EMBEDDIMS,
            "Embedding model served by Ollama (OpenAI-compatible /v1/embeddings)")
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// The endpoint and model, read back from the config row so there is one source
/// of truth. Returns "" in both outputs when the config is missing.
ClassMethod EmbedEndpoint(Output baseUrl As %String, Output model As %String) As %String
{
    Set baseUrl = "", model = ""
    Try {
        Set json = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT Configuration FROM %Embedding.Config WHERE Name = ?", ..#EMBEDCONFIG)
        If ($Extract(json, 1, 5) = "ERROR") || (json = "") {
            Return "embedding config '" _ ..#EMBEDCONFIG _ "' not found - run ETLWizard.KG.Setup.Install()"
        }
        Set cfg = ##class(%DynamicObject).%FromJSON(json)
        Set http = cfg.%Get("httpConfig")
        Set scheme = $Select($IsObject(http) && +http.%Get("Https", 0): "https", 1: "http")
        Set server = $Select($IsObject(http): http.%Get("Server", "ollama"), 1: "ollama")
        Set port = $Select($IsObject(http): +http.%Get("Port", 11434), 1: 11434)
        Set baseUrl = scheme _ "://" _ server _ ":" _ port
        Set model = cfg.%Get("modelName", ..#EMBEDMODEL)
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// The ETLW_KG tables and their HNSW indexes. Idempotent: existing tables are
/// left alone.
ClassMethod CreateSchema(verbose As %Boolean = 0) As %String
{
    Set dims = ..#EMBEDDIMS, type = ..#EMBEDTYPE
    Set vec = "VECTOR(" _ type _ ", " _ dims _ ")"

    Kill ddl
    Set ddl("Corpus") = "CREATE TABLE ETLW_KG.Corpus (" _
        "name VARCHAR(200), sourceTable VARCHAR(200), textColumn VARCHAR(200), " _
        "labelColumn VARCHAR(200), keyColumns VARCHAR(400), pipelineId VARCHAR(50), " _
        "rowsRequested INTEGER, rowsIngested INTEGER, chunksIngested INTEGER, " _
        "chunkChars INTEGER, batchSize INTEGER, extractGraph BIT, " _
        "embedModel VARCHAR(200), chatModel VARCHAR(200), status VARCHAR(20), " _
        "statusDetail VARCHAR(1000), autoRefresh BIT, refreshCap INTEGER, " _
        "loadStrategy VARCHAR(20), keyMode VARCHAR(10), " _
        "startedAt TIMESTAMP, finishedAt TIMESTAMP, " _
        "lastRowId BIGINT, lastSeenAt VARCHAR(40))"

    Set ddl("Doc") = "CREATE TABLE ETLW_KG.Doc (" _
        "corpusRef INTEGER, sourceKey VARCHAR(400), sourceRowId BIGINT, " _
        "label VARCHAR(1000), textHash VARCHAR(64), " _
        "ingestedAt TIMESTAMP, refreshedAt TIMESTAMP)"
    Set ddl("DocIdx") = "CREATE INDEX DocKeyIdx ON TABLE ETLW_KG.Doc (corpusRef, sourceKey)"

    Set ddl("Chunk") = "CREATE TABLE ETLW_KG.Chunk (" _
        "corpusRef INTEGER, docRef INTEGER, chunkIndex INTEGER, " _
        "chunkText VARCHAR(30000), embedText VARCHAR(31000), chunkVector " _ vec _ ")"
    Set ddl("ChunkHNSW") = "CREATE INDEX HNSWChunkIdx ON TABLE ETLW_KG.Chunk (chunkVector) AS HNSW(Distance='Cosine')"

    Set ddl("Entity") = "CREATE TABLE ETLW_KG.Entity (" _
        "corpusRef INTEGER, entityName VARCHAR(300), entityType VARCHAR(100), " _
        "description VARCHAR(4000), aliases VARCHAR(1000), mentionCount INTEGER, " _
        "descVector " _ vec _ ")"
    Set ddl("EntityHNSW") = "CREATE INDEX HNSWEntityIdx ON TABLE ETLW_KG.Entity (descVector) AS HNSW(Distance='Cosine')"

    Set ddl("Relationship") = "CREATE TABLE ETLW_KG.Relationship (" _
        "corpusRef INTEGER, sourceEntityRef INTEGER, targetEntityRef INTEGER, " _
        "predicate VARCHAR(200), description VARCHAR(4000), chunkRef INTEGER)"

    Set ddl("Mention") = "CREATE TABLE ETLW_KG.Mention (" _
        "corpusRef INTEGER, entityRef INTEGER, chunkRef INTEGER)"

    // The chat's queue and state machine. The answering model takes tens of
    // seconds and the webgateway gives up at ~60, so a question is a row the UI
    // polls rather than a request it waits on.
    Set ddl("Ask") = "CREATE TABLE ETLW_KG.Ask (" _
        "corpusRef INTEGER, question VARCHAR(2000), status VARCHAR(20), " _
        "statusDetail VARCHAR(1000), answer VARCHAR(30000), hits VARCHAR(30000), " _
        "createdAt TIMESTAMP, updatedAt TIMESTAMP)"

    // Order matters only in that an index needs its table; $Order over the
    // subscripts would run them alphabetically, so drive the list explicitly.
    Set order = $ListBuild("Corpus", "Doc", "DocIdx", "Chunk", "ChunkHNSW",
                           "Entity", "EntityHNSW", "Relationship", "Mention", "Ask")
    For i = 1:1:$ListLength(order) {
        Set key = $List(order, i)
        If ..ObjectExists(key) {
            Continue
        }
        Set res = ##class(ETLWizard.Tools.Util).RunDDL(ddl(key))
        If $Extract(res, 1, 5) = "ERROR" {
            Return "creating " _ key _ ": " _ res
        }
        If verbose {
            Write "created ", key, !
        }
    }
    // Columns added after the schema first shipped. The loop above skips a table
    // that already exists, so a new column needs its own idempotent step or an
    // instance built before the change never gets it.
    Set err = ..EnsureColumn("Corpus", "ingestMode", "VARCHAR(20)")
    If err '= "" {
        Return err
    }
    // the chat's answer as it is being written, for its poll to read
    Set err = ..EnsureColumn("Ask", "answerSoFar", "VARCHAR(30000)")
    If err '= "" {
        Return err
    }

    // An HNSW index that failed to create leaves the table with NO index, which
    // downstream is indistinguishable from a slow one - every query silently
    // full-scans. Verify rather than trust the SQLCODE alone.
    Set missing = ..MissingIndexes()
    If missing '= "" {
        Return "these vector indexes are not present after creation: " _ missing
    }
    Return ""
}

/// Add a column to an existing ETLW_KG table if it is not there yet.
ClassMethod EnsureColumn(table As %String, column As %String, type As %String) As %String [ Internal ]
{
    Set have = +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS " _
        "WHERE TABLE_SCHEMA = 'ETLW_KG' AND TABLE_NAME = ? AND COLUMN_NAME = ?", table, column)
    If have {
        Return ""
    }
    Set res = ##class(ETLWizard.Tools.Util).RunDDL(
        "ALTER TABLE ETLW_KG." _ table _ " ADD COLUMN " _ column _ " " _ type)
    If $Extract(res, 1, 5) = "ERROR" {
        Return "adding " _ table _ "." _ column _ ": " _ res
    }
    Return ""
}

/// Does this schema object already exist?
ClassMethod ObjectExists(key As %String) As %Boolean [ Internal ]
{
    If key = "DocIdx" {
        Return ..IndexExists("ETLW_KG.Doc", "DocKeyIdx")
    }
    If key = "ChunkHNSW" {
        Return ..IndexExists("ETLW_KG.Chunk", "HNSWChunkIdx")
    }
    If key = "EntityHNSW" {
        Return ..IndexExists("ETLW_KG.Entity", "HNSWEntityIdx")
    }
    Return +##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLW_KG' AND TABLE_NAME = ?",
        key) > 0
}

/// Index presence read from the class dictionary, which is where a CREATE INDEX
/// actually lands - INFORMATION_SCHEMA.INDEXES does not describe HNSW indexes.
ClassMethod IndexExists(table As %String, indexName As %String) As %Boolean [ Internal ]
{
    Set cls = ..ClassForTable(table)
    If cls = "" {
        Return 0
    }
    Return ##class(%Dictionary.CompiledIndex).%ExistsId(cls _ "||" _ indexName)
}

/// The persistent class behind a SQL table name.
ClassMethod ClassForTable(table As %String) As %String [ Internal ]
{
    Set res = ##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT TOP 1 CLASSNAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
        $Piece(table, ".", 1), $Piece(table, ".", 2))
    If $Extract(res, 1, 5) = "ERROR" {
        Return ""
    }
    Return res
}

/// Comma-separated list of vector indexes that should exist and do not.
ClassMethod MissingIndexes() As %String [ Internal ]
{
    Set out = ""
    If '..IndexExists("ETLW_KG.Chunk", "HNSWChunkIdx") {
        Set out = out _ $Select(out = "": "", 1: ", ") _ "ETLW_KG.Chunk:HNSWChunkIdx"
    }
    If '..IndexExists("ETLW_KG.Entity", "HNSWEntityIdx") {
        Set out = out _ $Select(out = "": "", 1: ", ") _ "ETLW_KG.Entity:HNSWEntityIdx"
    }
    Return out
}

/// Model for LINK-KG extraction. Measured head to head on one feedback record,
/// both warm: the coder took 39.9 s and produced full descriptions and aliases;
/// gemma4:e4b took 204 s and returned empty descriptions, missed an entity and
/// invented a relationship. A clean-generation benchmark (gemma at 32.3 tok/s)
/// did not predict this at all - extraction is a long structured prompt
/// demanding JSON, which is a different workload.
Parameter DEFAULTEXTRACTMODEL = "etlwizard-coder:latest";

/// Model for the conversational interface. gemma4:e4b is an instruct model and
/// reads better in prose than the coder, which is what a chat answer is.
/// Measured 3.23 GB resident, 100% on GPU, despite a 9.61 GB file - never infer
/// this model's VRAM from its file size.
Parameter DEFAULTCHATMODEL = "etlwizard-gemma:latest";

/// The two roles cannot be resident together: coder 4.99 + gemma 3.23 +
/// embedder 2.37 = 10.6 GB against 7.8 GB usable. They do not need to be -
/// extraction is a batch job and chat is interactive, so they never run at the
/// same moment. The cost is a ~35 s cold load when the GPU swaps between them.
///
/// Kept in a global rather than a Config Store profile because this build's
/// Config Store REJECTS new AI.LLM.* names: Create returns ERROR #26414 "No
/// descriptor found for AI.LLM". The two profiles that do exist
/// (AI.LLM.ETLWizard, AI.LLM.ETLWizardSqlGen) predate that restriction and
/// cannot be joined by a third. The provider - endpoint, credentials, provider
/// class - still comes from AI.LLM.ETLWizard; only the model name is overridden
/// here, which is the one thing that actually differs.
ClassMethod GetExtractModel() As %String
{
    Set model = $Get(^ETLWizard.KG("extractModel"))
    Return $Select(model = "": ..#DEFAULTEXTRACTMODEL, 1: model)
}

ClassMethod SetExtractModel(model As %String) As %String
{
    Set model = $ZStrip(model, "<>W")
    If model = "" {
        Return "a model name is required"
    }
    Set ^ETLWizard.KG("extractModel") = model
    Return ""
}

ClassMethod GetChatModel() As %String
{
    Set model = $Get(^ETLWizard.KG("chatModel"))
    Return $Select(model = "": ..#DEFAULTCHATMODEL, 1: model)
}

ClassMethod SetChatModel(model As %String) As %String
{
    Set model = $ZStrip(model, "<>W")
    If model = "" {
        Return "a model name is required"
    }
    Set ^ETLWizard.KG("chatModel") = model
    Return ""
}

/// Round a value for display, locale-proof.
///
/// NEVER use $NUMBER for this. This instance runs a Portuguese locale, where
/// "." is the THOUSANDS separator, so $NUMBER("0.55686...", 4) parses the
/// string as 55686169862747192380 - the digits survive and the decimal point
/// silently disappears. `+value` uses canonical numeric parsing (always "."),
/// and $JUSTIFY does the rounding.
ClassMethod Round(value As %String, places As %Integer = 3) As %Numeric
{
    If $ZStrip(value, "<>W") = "" {
        Return ""
    }
    Return +$Justify(+value, 0, places)
}

/// Drop the whole schema. Presenter-tools territory: everything embedded is lost.
ClassMethod DropSchema() As %String
{
    For table = "Ask", "Mention", "Relationship", "Entity", "Chunk", "Doc", "Corpus" {
        Do ##class(ETLWizard.Tools.Util).RunDDL("DROP TABLE ETLW_KG." _ table)
    }
    Return ""
}

}
