/// Index advisor + builder for the target table (the wizard's last step).
///
/// IRIS index types, and when each earns its keep:
///   standard  CREATE INDEX            equality + range lookups, ORDER BY
///   bitmap    CREATE BITMAP INDEX     low-cardinality columns, ANDed filters
///   bitslice  CREATE BITSLICE INDEX   numeric measures aggregated with SUM/AVG
///   columnar  CREATE COLUMNAR INDEX   analytic scans over one wide column
/// and the whole table can be stored column-wise:
///   ALTER TABLE <t> CONVERT TO STORAGETYPE = COLUMNAR
/// (verified against 2026.3.0AI build 125 — a table converted this way grows a
/// _CDM_<column> map per column, so per-column columnar indexes become redundant.)
///
/// RecommendIndexes profiles the target and applies the rules above, then asks
/// the local model to reconsider them against what the column NAMES mean — a
/// rule sees "20 distinct values", the model sees "status". CreateIndexes is
/// DDL and gated, so nothing is built until the user approves the list.
Class ETLWizard.Tools.Indexing Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Rows above which COUNT(DISTINCT) is estimated from a sample instead of
/// scanning the whole table.
Parameter SAMPLEOVER = 200000;

Parameter SAMPLEROWS = 50000;

/// Column facts for ETLW_TARGET.<baseName>: type, distinct values, nulls, and
/// the row count. This is what both the rules and the model reason over.
Method ProfileTarget(baseName As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(baseName) {
            Return "ERROR: invalid baseName"
        }
        Set table = "ETLW_TARGET." _ baseName
        Set rows = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ table)
        If $Extract(rows, 1, 5) = "ERROR" {
            Return "ERROR: target table " _ table _ " not found - deploy the pipeline first"
        }
        Set rows = +rows
        Set cols = []
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLW_TARGET' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
            baseName)
        While rs.%Next() {
            Set name = rs.%GetData(1), type = $ZConvert(rs.%GetData(2), "L")
            If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
                Continue
            }
            // etl_created_at / etl_updated_at are bookkeeping, never filtered on
            If $Extract($ZConvert(name, "L"), 1, 4) = "etl_" {
                Continue
            }
            Set from = table
            If rows > ..#SAMPLEOVER {
                Set from = "(SELECT TOP " _ ..#SAMPLEROWS _ " " _ name _ " FROM " _ table _ ") s"
            }
            Set distinct = +##class(ETLWizard.Tools.Util).ScalarQuery(
                "SELECT COUNT(DISTINCT " _ name _ ") FROM " _ from)
            Set nulls = +##class(ETLWizard.Tools.Util).ScalarQuery(
                "SELECT COUNT(*) FROM " _ table _ " WHERE " _ name _ " IS NULL")
            Do cols.%Push({"column": (name), "type": (type), "distinct": (distinct),
                           "nulls": (nulls), "sampled": ($Select(rows > ..#SAMPLEOVER: 1, 1: 0))})
        }
        Return {"table": (table), "rowCount": (rows), "columns": (cols)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Is this a numeric type that SUM/AVG would be run over?
ClassMethod IsMeasure(type As %String, name As %String) As %Boolean [ Internal ]
{
    If '((type [ "numeric") || (type [ "decimal") || (type [ "double") || (type [ "money") ||
        (type [ "int") || (type [ "float")) {
        Return 0
    }
    Set n = $ZConvert(name, "L")
    // an id is a key, not a measure, however numeric it looks
    If (n [ "_id") || ($Extract(n, *-1, *) = "id") || (n [ "key") || (n [ "code") {
        Return 0
    }
    Return (type [ "numeric") || (type [ "decimal") || (type [ "double") || (type [ "money") || (type [ "float") ||
           (n [ "amount") || (n [ "price") || (n [ "total") || (n [ "qty") || (n [ "quantity") ||
           (n [ "count") || (n [ "sum") || (n [ "cost") || (n [ "value")
}

ClassMethod IsTemporal(type As %String) As %Boolean [ Internal ]
{
    Return (type [ "timestamp") || (type [ "date") || (type [ "time")
}

/// Rule-based draft: one recommendation per column that deserves one.
/// Returns a %DynamicArray of {column, type, reason}.
ClassMethod RuleDraft(profile As %DynamicObject, pkColumns As %String, watermarkColumn As %String) As %DynamicArray [ Internal ]
{
    Set out = []
    Set rows = +profile.rowCount
    Set pkList = ","
    For i = 1:1:$Length(pkColumns, ",") {
        Set pkList = pkList _ $ZConvert($ZStrip($Piece(pkColumns, ",", i), "<>W"), "L") _ ","
    }
    Set iter = profile.columns.%GetIterator()
    While iter.%GetNext(.i, .col) {
        Set name = col.column, type = col.type, distinct = +col.distinct
        Set lname = $ZConvert(name, "L")
        // the primary key already has a unique index from CREATE TABLE
        If pkList [ ("," _ lname _ ",") {
            Continue
        }
        If lname = $ZConvert(watermarkColumn, "L") {
            Do out.%Push({"column": (name), "type": "standard",
                "reason": "watermark column - every incremental run filters on it with >"})
            Continue
        }
        If ..IsTemporal(type) {
            Do out.%Push({"column": (name), "type": "standard",
                "reason": "date/time column - range filters and ORDER BY use a standard index"})
            Continue
        }
        // low cardinality: a handful of repeated values across many rows
        If (distinct > 0) && (distinct '> 20) && (rows > 0) && ((distinct * 100) '> (rows * 5)) {
            Do out.%Push({"column": (name), "type": "bitmap",
                "reason": (distinct _ " distinct values over " _ rows _ " rows - bitmap ANDs cheaply with other filters")})
            Continue
        }
        If ..IsMeasure(type, name) {
            Do out.%Push({"column": (name), "type": "bitslice",
                "reason": "numeric measure - bitslice answers SUM/AVG without reading the rows"})
            Continue
        }
        // high cardinality on a big table: scanned, not looked up
        If (rows '< 100000) && (distinct > 0) && ((distinct * 2) > rows) {
            Do out.%Push({"column": (name), "type": "columnar",
                "reason": "high-cardinality column on a large table - columnar scans it without the other columns"})
        }
    }
    Return out
}

/// Ask the local model to revise the rule draft using what the column names
/// MEAN. Returns a revised %DynamicArray, or "" when no model is configured or
/// the answer cannot be trusted (the caller then keeps the rule draft).
ClassMethod AgentDraft(profile As %DynamicObject, draft As %DynamicArray, pkColumns As %String, watermarkColumn As %String) As %DynamicArray [ Internal ]
{
    Try {
        Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizardSqlGen", .provider, .model)
        If $$$ISERR(sc) {
            Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizard", .provider, .model)
        }
        If $$$ISERR(sc) {
            Return ""
        }
        Set agent = ##class(%AI.Agent).%New(provider)
        If model '= "" {
            Set agent.Model = model
        }
        Set nl = $Char(10)
        Set agent.SystemPrompt =
            "You advise on InterSystems IRIS indexes for a data-warehouse target table." _ nl _ nl _
            "Index types:" _ nl _
            "- standard: equality and range lookups, ORDER BY. Dates, foreign keys, codes." _ nl _
            "- bitmap: low-cardinality columns (a few dozen distinct values at most)," _ nl _
            "  especially when several filters are ANDed. Never on a near-unique column." _ nl _
            "- bitslice: numeric measures that get SUM/AVG/range-counted. Not for ids." _ nl _
            "- columnar: one wide column scanned analytically on a large table." _ nl _ nl _
            "Rules:" _ nl _
            "- Recommend an index only when a query would plausibly use it. Fewer is better;" _ nl _
            "  every index costs write time and space." _ nl _
            "- Never index the primary key (it already has one)." _ nl _
            "- Judge from what the column NAME means as well as its statistics." _ nl _
            "- Answer with ONLY a JSON array, no prose and no markdown fences:" _ nl _
            "  [{""column"":""status"",""type"":""bitmap"",""reason"":""order state, few values""}]" _ nl _
            "- An empty array is a valid answer when no index is worth building."
        Set facts = "Table: " _ profile.table _ nl _ "Rows: " _ profile.rowCount _ nl _
            "Primary key: " _ $Select(pkColumns '= "": pkColumns, 1: "(none)") _ nl _
            "Watermark: " _ $Select(watermarkColumn '= "": watermarkColumn, 1: "(none)") _ nl _
            "Columns (name, type, distinct values, nulls):" _ nl
        Set it = profile.columns.%GetIterator()
        While it.%GetNext(.i, .c) {
            Set facts = facts _ "- " _ c.column _ ", " _ c.type _ ", " _ c.distinct _ " distinct, " _ c.nulls _ " null" _ nl
        }
        Set prompt = "/no_think" _ nl _ facts _ nl _
            "A rule-based pass proposed:" _ nl _ draft.%ToJSON() _ nl _ nl _
            "Revise it. Keep what is right, drop what is not worth building, add what it missed." _ nl _
            "Answer with the JSON array only."
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, prompt)
        Set raw = ""
        If $IsObject(response) {
            Set raw = response.Content
        }
        If raw [ "</think>" {
            Set raw = $Piece(raw, "</think>", 2, *)
        }
        // keep just the JSON array, however the model wrapped it
        If raw '[ "[" {
            Return ""
        }
        Set raw = $Extract(raw, $Find(raw, "[") - 1, $Length(raw))
        Set depth = 0, end = 0
        For i = 1:1:$Length(raw) {
            Set ch = $Extract(raw, i)
            If ch = "[" {
                Set depth = depth + 1
            } ElseIf ch = "]" {
                Set depth = depth - 1
                If depth = 0 {
                    Set end = i
                    Quit
                }
            }
        }
        If end = 0 {
            Return ""
        }
        Return ##class(%DynamicArray).%FromJSON($Extract(raw, 1, end))
    } Catch {
        Return ""
    }
}

/// Recommend indexes for ETLW_TARGET.<baseName>. Read-only: nothing is built.
/// Returns {"table","rowCount","recommendations":[{column,type,name,reason,source}],
///          "tableColumnar":{"suggested","reason"},"profile":{...}}
Method RecommendIndexes(runId As %String, baseName As %String, pkColumns As %String = "", watermarkColumn As %String = "") As %String
{
    Try {
        Set profileJson = ..ProfileTarget(baseName)
        If $Extract(profileJson, 1, 5) = "ERROR" {
            Return profileJson
        }
        Set profile = ##class(%DynamicObject).%FromJSON(profileJson)
        Set draft = ..RuleDraft(profile, pkColumns, watermarkColumn)
        Set source = "rules"
        Set revised = ..AgentDraft(profile, draft, pkColumns, watermarkColumn)
        If $IsObject(revised) {
            Set source = "agent"
        } Else {
            Set revised = draft
        }
        // Validate whatever came back: real columns, known types, no duplicates.
        Set valid = ["standard", "bitmap", "bitslice", "columnar"]
        Set known = ","
        Set ci = profile.columns.%GetIterator()
        While ci.%GetNext(.i, .c) {
            Set known = known _ $ZConvert(c.column, "L") _ ","
        }
        // columns that already carry an index, so the step can say so
        Set already = "|"
        Try {
            Set have = ##class(%DynamicObject).%FromJSON(..ListTargetIndexes(baseName))
            Set hi = have.rows.%GetIterator()
            While hi.%GetNext(.i, .h) {
                Set already = already _ $ZConvert(h.columns, "L") _ "|"
            }
        } Catch {
        }
        Set out = [], seen = ""
        Set it = revised.%GetIterator()
        While it.%GetNext(.i, .rec) {
            If '$IsObject(rec) {
                Continue
            }
            Set col = $ZStrip(rec.%Get("column", ""), "<>W")
            Set type = $ZConvert($ZStrip(rec.%Get("type", ""), "<>W"), "L")
            If (col = "") || (known '[ ("," _ $ZConvert(col, "L") _ ",")) {
                Continue
            }
            If '##class(ETLWizard.Tools.Util).ValidIdent(col) {
                Continue
            }
            If $ListFind($ListBuild("standard", "bitmap", "bitslice", "columnar"), type) = 0 {
                Continue
            }
            If seen [ ("|" _ $ZConvert(col, "L") _ "|") {
                Continue
            }
            Set seen = seen _ "|" _ $ZConvert(col, "L") _ "|"
            // an index already covering this column is not worth proposing again
            Set exists = (already [ ("|" _ $ZConvert(col, "L") _ "|"))
            Do out.%Push({"column": (col), "type": (type), "name": (..IndexName(baseName, col, type)),
                          "reason": (rec.%Get("reason", "")), "source": (source),
                          "exists": ($Select(exists: 1, 1: 0))})
        }
        // Whole-table columnar: an analytic target, not an operational one.
        Set rows = +profile.rowCount, measures = 0
        Set mi = profile.columns.%GetIterator()
        While mi.%GetNext(.i, .c) {
            If ..IsMeasure(c.type, c.column) {
                Set measures = measures + 1
            }
        }
        Set colSuggest = ((rows '< 1000000) || ((measures '< 3) && (rows '< 100000)))
        Set colReason = $Select(
            colSuggest && (rows '< 1000000): rows _ " rows - at this size column-wise storage usually wins on analytic scans",
            colSuggest: measures _ " numeric measures over " _ rows _ " rows - reads for aggregation, a good fit for columnar storage",
            1: "small or operational table - row storage is the better default; a per-column columnar index is enough if one query needs it")
        // "agent" when the model revised the draft, "rules" when it was
        // unreachable or unusable — the step offers a manual list in that case
        Return {"table": (profile.table), "rowCount": (rows), "advisor": (source),
                "recommendations": (out),
                "tableColumnar": {"suggested": ($Select(colSuggest: 1, 1: 0)), "reason": (colReason),
                                  "ddl": ("ALTER TABLE ETLW_TARGET." _ baseName _ " CONVERT TO STORAGETYPE = COLUMNAR")},
                "profile": (profile)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Index name that is unique per table+column+type and short enough for SQL.
ClassMethod IndexName(baseName As %String, column As %String, type As %String) As %String [ Internal ]
{
    Set suffix = $Case(type, "bitmap": "_bmi", "bitslice": "_bsi", "columnar": "_cmi", : "_idx")
    Set name = baseName _ "_" _ column _ suffix
    If $Length(name) > 60 {
        Set name = $Extract(baseName, 1, 20) _ "_" _ $Extract(column, 1, 30) _ suffix
    }
    Return name
}

/// Build the approved indexes on ETLW_TARGET.<baseName>. Gated DDL.
/// specJson: {"tableColumnar":0|1,
///            "indexes":[{"column":"status","type":"bitmap","name":"..."}]}
/// Converting the table to columnar storage happens first, because it makes
/// per-column columnar indexes redundant — those are dropped from the list.
Method CreateIndexes(runId As %String, baseName As %String, specJson As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(baseName) {
            Return "ERROR: invalid baseName"
        }
        Set table = "ETLW_TARGET." _ baseName
        Set spec = ##class(%DynamicObject).%FromJSON(specJson)
        Set applied = [], failed = []
        Set toColumnar = +spec.%Get("tableColumnar", 0)
        If toColumnar {
            Set ddl = "ALTER TABLE " _ table _ " CONVERT TO STORAGETYPE = COLUMNAR"
            Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
            If err '= "" {
                Do failed.%Push({"name": (table), "type": "table_columnar", "error": (err)})
                Set toColumnar = 0
            } Else {
                Do applied.%Push({"name": (table), "type": "table_columnar", "ddl": (ddl)})
                Do ##class(ETLWizard.Model.Event).Append(runId, "index.created", "",
                    {"table": (table), "type": "table_columnar", "ddl": (ddl)})
            }
        }
        Set list = spec.%Get("indexes", [])
        If $IsObject(list) {
            Set it = list.%GetIterator()
            While it.%GetNext(.i, .idx) {
                Set col = $ZStrip(idx.%Get("column", ""), "<>W")
                Set type = $ZConvert($ZStrip(idx.%Get("type", ""), "<>W"), "L")
                Set name = $ZStrip(idx.%Get("name", ""), "<>W")
                If name = "" {
                    Set name = ..IndexName(baseName, col, type)
                }
                If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
                    Do failed.%Push({"name": (name), "error": "invalid index name"})
                    Continue
                }
                // a multi-column index arrives as "a,b" — validate each part
                Set colsOk = 1, colSql = ""
                For p = 1:1:$Length(col, ",") {
                    Set one = $ZStrip($Piece(col, ",", p), "<>W")
                    If '##class(ETLWizard.Tools.Util).ValidIdent(one) {
                        Set colsOk = 0
                        Quit
                    }
                    Set colSql = colSql _ $Select(colSql = "": "", 1: ", ") _ one
                }
                If 'colsOk {
                    Do failed.%Push({"name": (name), "error": ("invalid column list: " _ col)})
                    Continue
                }
                If (type = "none") || (type = "") {
                    Continue
                }
                If (type = "columnar") && toColumnar {
                    Do failed.%Push({"name": (name), "type": (type),
                        "error": "skipped - the whole table is already columnar, so this index would duplicate it"})
                    Continue
                }
                Set keyword = $Case(type, "bitmap": "BITMAP ", "bitslice": "BITSLICE ",
                    "columnar": "COLUMNAR ", "unique": "UNIQUE ", : "")
                Set ddl = "CREATE " _ keyword _ "INDEX " _ name _ " ON " _ table _ " (" _ colSql _ ")"
                Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
                If err '= "" {
                    Do failed.%Push({"name": (name), "type": (type), "error": (err)})
                    Continue
                }
                Do applied.%Push({"name": (name), "type": (type), "column": (col), "ddl": (ddl)})
                Do ##class(ETLWizard.Model.Event).Append(runId, "index.created", "",
                    {"table": (table), "name": (name), "type": (type), "column": (col), "ddl": (ddl)})
            }
        }
        // %BuildIndices only matters when rows are already there. Built before
        // the first load (the deploy path), the table is empty and the load
        // maintains the indexes as it inserts.
        Set built = ""
        If applied.%Size() > 0 {
            Set rows = +##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ table)
            Set built = $Select(rows > 0: ..BuildIndices(baseName),
                                1: "empty table - the load will maintain these indexes as it inserts")
        }
        // Remember what was built, so a later run (or a human) can see it
        Do ..RecordOnPipeline(runId, applied, toColumnar)
        Return {"table": (table), "applied": (applied), "failed": (failed), "built": (built)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Populate new indexes over the rows already in the table. A fresh CREATE INDEX
/// on a populated table is not usable until its data is built.
ClassMethod BuildIndices(baseName As %String) As %String [ Internal ]
{
    Try {
        Set cls = ##class(ETLWizard.Tools.Util).ScalarQuery(
            "SELECT CLASSNAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLW_TARGET' AND TABLE_NAME = ?",
            baseName)
        If ($Extract(cls, 1, 5) = "ERROR") || (cls = "") {
            Return "index data not built: class for " _ baseName _ " not found"
        }
        // %BuildIndices writes progress to the current device; the caller is an
        // HTTP response that must stay pure JSON, so send it to a temp file.
        Set io = $IO
        Open "/tmp/idx_build":("WNS"):1
        Use "/tmp/idx_build"
        Set sc = $ClassMethod(cls, "%BuildIndices")
        Use io
        Close "/tmp/idx_build"
        If $$$ISERR(sc) {
            Return "index data build failed: " _ $System.Status.GetErrorText(sc)
        }
        Return "index data built over existing rows"
    } Catch ex {
        Return "index data build failed: " _ ex.DisplayString()
    }
}

/// Append the built indexes to the pipeline metadata, alongside the transform
/// and layer definitions.
ClassMethod RecordOnPipeline(runId As %String, applied As %DynamicArray, tableColumnar As %Boolean) As %String [ Internal ]
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return ""
        }
        Set pipeline = run.Pipeline
        Set meta = {}
        Try {
            Set meta = ##class(%DynamicObject).%FromJSON(pipeline.MetadataJson)
        } Catch {
            Set meta = {}
        }
        Set meta.indexes = {"tableColumnar": ($Select(tableColumnar: 1, 1: 0)), "created": (applied)}
        Set pipeline.MetadataJson = meta.%ToJSON()
        Do pipeline.%Save()
        Return ""
    } Catch {
        Return ""
    }
}

/// The indexes that exist on the target now — so the step can show what is
/// already there instead of proposing it again.
Method ListTargetIndexes(baseName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(baseName) {
        Return "ERROR: invalid baseName"
    }
    // two steps rather than a join: the table's class name first, then its
    // indexes. IDKEY and %%DDLBEIndex are IRIS's own bookkeeping, not something
    // the user chose, so they are not worth showing.
    Set cls = ##class(ETLWizard.Tools.Util).ScalarQuery(
        "SELECT CLASSNAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLW_TARGET' AND TABLE_NAME = ?",
        baseName)
    If ($Extract(cls, 1, 5) = "ERROR") || (cls = "") {
        Return "{""rows"":[],""row_count"":0}"
    }
    Return ##class(ETLWizard.Tools.Util).RunSelect(
        "SELECT SqlName AS index_name, Type AS index_type, Properties AS columns " _
        "FROM %Dictionary.CompiledIndex WHERE parent = '" _ cls _ "' " _
        "AND Name NOT IN ('IDKEY', 'DDLBEIndex')", 100)
}

}
