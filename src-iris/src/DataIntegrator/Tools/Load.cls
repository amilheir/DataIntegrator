/// Layered load tools (spec §6.1, §7, §10.2): landing/staging/target DDL and
/// the load strategies (full, incremental timestamp + upsert). Everything in
/// this class is destructive and gated by requires_auth (spec §16.2).
/// Layer naming per spec §6.1/§22: ETLW_LANDING.<base>_raw,
/// ETLW_STAGING.<base>_delta, ETLW_TARGET.<base>.
/// Watermarks are updated only on success (spec §7).
Class ETLWizard.Tools.Load Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Create the landing, staging and target tables for a pipeline from the
/// columns of a mounted foreign table. pkColumns is a comma-separated list
/// (e.g. "customer_id"). Records nodes with the exact DDL and links them.
Method CreateLayerTables(runId As %String, baseName As %String, foreignTable As %String, pkColumns As %String) As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        // Primary key is optional: append-only / snapshot / csv-arrival targets
        // accumulate rows and have no natural key.
        Set pkColumns = $ZStrip(pkColumns, "<>W")
        If pkColumns '= "" {
            For i = 1:1:$Length(pkColumns, ",") {
                If '$ClassMethod(util, "ValidIdent", $ZStrip($Piece(pkColumns, ",", i), "<>W")) {
                    Return "ERROR: invalid primary key column list"
                }
            }
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }

        Set landing = "ETLW_LANDING." _ baseName _ "_raw"
        Set staging = "ETLW_STAGING." _ baseName _ "_delta"
        Set target = "ETLW_TARGET." _ baseName

        Set pkClause = $Select(pkColumns '= "": ", PRIMARY KEY (" _ pkColumns _ ")", 1: "")
        Set ddlLanding = "CREATE TABLE " _ landing _ " (" _ ddlDefs _
            ", etl_run_id VARCHAR(32), etl_load_ts TIMESTAMP, etl_source VARCHAR(128))"
        Set ddlStaging = "CREATE TABLE " _ staging _ " (" _ ddlDefs _ ")"
        Set ddlTarget = "CREATE TABLE " _ target _ " (" _ ddlDefs _
            ", etl_created_at TIMESTAMP, etl_updated_at TIMESTAMP" _ pkClause _ ")"

        For ddl = ddlLanding, ddlStaging, ddlTarget {
            Set err = $ClassMethod(util, "RunDDL", ddl)
            If err '= "" {
                Return err
            }
        }

        Do $ClassMethod(util, "CatalogNode", runId, "landing", landing, ddlLanding, "")
        Do $ClassMethod(util, "CatalogNode", runId, "staging", staging, ddlStaging, "")
        Do $ClassMethod(util, "CatalogNode", runId, "target", target, ddlTarget, "")

        // Lineage edges FT -> landing -> staging -> target (best effort)
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        Do cat.CatalogLink(runId, "ETLWIZARD." _ foreignTable, landing, "Extract")
        Do cat.CatalogLink(runId, landing, staging, "Delta")
        Do cat.CatalogLink(runId, staging, target, "Merge/Upsert")

        Return "Created layer tables: " _ landing _ ", " _ staging _ ", " _ target
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Run an incremental timestamp load with merge/upsert (spec §22):
/// foreign table -> landing (stamped) -> staging delta -> INSERT OR UPDATE
/// target. The watermark advances only when everything succeeded. The first
/// run (no watermark yet) extracts all rows. Returns row-count stats JSON.
/// Serialized per base: the production poll, the executor and the wizard can
/// all trigger loads — concurrent runs of the same pipeline must not race.
Method RunIncrementalLoad(runId As %String, baseName As %String, foreignTable As %String, watermarkColumn As %String) As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunIncrementalLoadInner(runId, baseName, foreignTable, watermarkColumn)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunIncrementalLoadInner(runId As %String, baseName As %String, foreignTable As %String, watermarkColumn As %String) As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        If '$ClassMethod(util, "ValidIdent", watermarkColumn) {
            Return "ERROR: invalid watermarkColumn"
        }
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        Set landing = "ETLW_LANDING." _ baseName _ "_raw"
        Set staging = "ETLW_STAGING." _ baseName _ "_delta"
        Set target = "ETLW_TARGET." _ baseName

        // Previous watermark (empty = first load, full extract)
        Set prevWm = ""
        Set wmObj = ##class(ETLWizard.Model.Watermark).PipelineIdxOpen(run.Pipeline.%Id())
        If $IsObject(wmObj) {
            Set prevWm = wmObj.LastValue
        }

        // 1. Extract into landing. etl_run_id carries a unique per-execution
        // batch id so repeated loads within one wizard run never re-stage
        // earlier batches.
        Set execId = runId _ "-" _ $Increment(^ETLWizard.ExecSeq)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (landing), "status": "running"})
        // InsertFromSelect (not RunDML) so an ODBC-linked source, which no
        // set-based INSERT ... SELECT can read, streams through the cursor
        // fallback instead of failing to compile
        Set extractCols = colList _ ", etl_run_id, etl_load_ts, etl_source"
        Set sql = "SELECT " _ colList _ ", ?, CURRENT_TIMESTAMP, ? FROM ETLWIZARD." _ foreignTable
        If prevWm '= "" {
            Set sql = sql _ " WHERE " _ watermarkColumn _ " > ?"
            Set res = $ClassMethod(util, "InsertFromSelect", landing, extractCols, sql, execId, foreignTable, prevWm)
        } Else {
            Set res = $ClassMethod(util, "InsertFromSelect", landing, extractCols, sql, execId, foreignTable)
        }
        If $Extract(res, 1, 5) = "ERROR" {
            Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (landing), "status": "failed", "error": (res)})
            Return res
        }
        Set rowsExtracted = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (landing), "status": "succeeded", "rowCount": (rowsExtracted)})

        // Nothing new: don't re-stage the previous batch
        If rowsExtracted = 0 {
            Return {"rowsExtracted": 0, "rowsStaged": 0, "rowsUpserted": 0,
                    "previousWatermark": (prevWm), "newWatermark": (prevWm),
                    "note": "no rows newer than the watermark"}.%ToJSON()
        }

        // 2. Rebuild staging delta from this run's landing rows
        Do $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ staging)
        Set res = $ClassMethod(util, "RunDML",
            "INSERT INTO " _ staging _ " (" _ colList _ ") SELECT " _ colList _ " FROM " _ landing _ " WHERE etl_run_id = ?", execId)
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set rowsStaged = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (staging), "status": "succeeded", "rowCount": (rowsStaged)})

        // 3. Upsert into target
        Set res = $ClassMethod(util, "RunDML",
            "INSERT OR UPDATE INTO " _ target _ " (" _ colList _ ", etl_created_at, etl_updated_at) " _
            "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM " _ staging)
        If $Extract(res, 1, 5) = "ERROR" {
            Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "failed", "error": (res)})
            Return res
        }
        Set rowsUpserted = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "succeeded", "rowCount": (rowsUpserted)})

        // 4. Advance the watermark (success only, spec §7)
        Set newWm = $ClassMethod(util, "ScalarQuery", "SELECT MAX(" _ watermarkColumn _ ") FROM " _ staging)
        If ($Extract(newWm, 1, 5) '= "ERROR") && (newWm '= "") {
            If '$IsObject(wmObj) {
                Set wmObj = ##class(ETLWizard.Model.Watermark).%New()
                Set wmObj.Pipeline = run.Pipeline
                Set wmObj.Type = "timestamp"
                Set wmObj.ColumnName = watermarkColumn
            }
            Set wmObj.LastValue = newWm
            Set wmObj.UpdatedByRun = run
            Set wmObj.UpdatedAt = $ZDateTime($ZTimeStamp, 3, , 3)
            Set sc = wmObj.%Save()
            If $$$ISOK(sc) {
                Do ##class(ETLWizard.Model.Event).Append(runId, "watermark.updated", "",
                    {"column": (watermarkColumn), "previous": (prevWm), "current": (newWm)})
            }
        }

        Set stats = {"rowsExtracted": (rowsExtracted), "rowsStaged": (rowsStaged),
                     "rowsUpserted": (rowsUpserted), "previousWatermark": (prevWm),
                     "newWatermark": ($Select(newWm '= "": newWm, 1: prevWm))}
        Return stats.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Full load: truncate the target and reload every source row (spec §7).
/// Serialized per base (see RunIncrementalLoad).
Method RunFullLoad(runId As %String, baseName As %String, foreignTable As %String) As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunFullLoadInner(runId, baseName, foreignTable)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunFullLoadInner(runId As %String, baseName As %String, foreignTable As %String) As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        Set target = "ETLW_TARGET." _ baseName
        Set res = $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ target)
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set res = $ClassMethod(util, "InsertFromSelect", target,
            colList _ ", etl_created_at, etl_updated_at",
            "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM ETLWIZARD." _ foreignTable)
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set rows = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "succeeded", "rowCount": (rows)})
        Return {"rowsLoaded": (rows), "strategy": "full"}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Snapshot load (spec §7): full point-in-time copy into a dated snapshot
/// table ETLW_TARGET.<base>_snap_<timestamp>. History policy "snapshot".
/// Serialized per base (see RunIncrementalLoad).
Method RunSnapshotLoad(runId As %String, baseName As %String, foreignTable As %String) As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunSnapshotLoadInner(runId, baseName, foreignTable)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunSnapshotLoadInner(runId As %String, baseName As %String, foreignTable As %String) As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        // timestamp + monotonic counter so concurrent/same-second runs never collide
        Set suffix = $Translate($ZDateTime($ZTimeStamp, 8), " :", "_") _ "_" _ $Increment(^ETLWizard.SnapSeq)
        Set snap = "ETLW_TARGET." _ baseName _ "_snap_" _ suffix
        Set ddl = "CREATE TABLE " _ snap _ " (" _ ddlDefs _ ", etl_snapshot_at TIMESTAMP)"
        Set res = $ClassMethod(util, "RunDDL", ddl)
        If res '= "" {
            Return res
        }
        Set res = $ClassMethod(util, "InsertFromSelect", snap, colList _ ", etl_snapshot_at",
            "SELECT " _ colList _ ", CURRENT_TIMESTAMP FROM ETLWIZARD." _ foreignTable)
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set rows = +$Piece(res, ":", 2)
        Do $ClassMethod(util, "CatalogNode", runId, "target", snap, ddl, "")
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (snap), "status": "succeeded", "rowCount": (rows)})
        Return {"strategy": "snapshot", "snapshotTable": (snap), "rowsLoaded": (rows)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Append-only load (spec §7): insert new rows only, never update or delete.
/// With watermarkColumn (timestamp OR increasing numeric id) only rows beyond
/// the pipeline watermark are appended — this is also the Incremental Numeric
/// Watermark strategy. Without it, every source row is appended (logs/events
/// tables without a unique constraint).
/// Serialized per base (see RunIncrementalLoad).
Method RunAppendOnlyLoad(runId As %String, baseName As %String, foreignTable As %String, watermarkColumn As %String = "") As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunAppendOnlyLoadInner(runId, baseName, foreignTable, watermarkColumn)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunAppendOnlyLoadInner(runId As %String, baseName As %String, foreignTable As %String, watermarkColumn As %String = "") As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        If (watermarkColumn '= "") && ('$ClassMethod(util, "ValidIdent", watermarkColumn)) {
            Return "ERROR: invalid watermarkColumn"
        }
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        Set target = "ETLW_TARGET." _ baseName
        Set prevWm = ""
        Set wmObj = ##class(ETLWizard.Model.Watermark).PipelineIdxOpen(run.Pipeline.%Id())
        If $IsObject(wmObj) {
            Set prevWm = wmObj.LastValue
        }
        Set appendCols = colList _ ", etl_created_at, etl_updated_at"
        Set sql = "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM ETLWIZARD." _ foreignTable
        If (watermarkColumn '= "") && (prevWm '= "") {
            Set res = $ClassMethod(util, "InsertFromSelect", target, appendCols, sql _ " WHERE " _ watermarkColumn _ " > ?", prevWm)
        } Else {
            Set res = $ClassMethod(util, "InsertFromSelect", target, appendCols, sql)
        }
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set rows = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "succeeded", "rowCount": (rows)})
        Set newWm = prevWm
        If (watermarkColumn '= "") && (rows > 0) {
            // %EXTERNAL, not a bare MAX(): on a %TimeStamp column IRIS returns the
            // LOGICAL value (1154709446288886490), and that is what used to be
            // persisted as the watermark. The next run then filtered
            // "WHERE ordered_at > 1154709446288886490" against the source's real
            // timestamp, matched nothing, and reported SUCCESS having loaded zero
            // rows - silently, on every incremental run after the first. It also
            // made the watermark record itself claim Type="numeric" on a
            // timestamp column, because the logical form is a number.
            // %EXTERNAL returns "2026-08-28 18:28:02.039514", which compares
            // correctly and types correctly.
            Set maxWm = $ClassMethod(util, "ScalarQuery", "SELECT %EXTERNAL(MAX(" _ watermarkColumn _ ")) FROM ETLWIZARD." _ foreignTable)
            If ($Extract(maxWm, 1, 5) '= "ERROR") && (maxWm '= "") {
                If '$IsObject(wmObj) {
                    Set wmObj = ##class(ETLWizard.Model.Watermark).%New()
                    Set wmObj.Pipeline = run.Pipeline
                    Set wmObj.Type = $Select($IsValidNum(maxWm): "numeric", 1: "timestamp")
                    Set wmObj.ColumnName = watermarkColumn
                }
                Set wmObj.LastValue = maxWm
                Set wmObj.UpdatedByRun = run
                Set wmObj.UpdatedAt = $ZDateTime($ZTimeStamp, 3, , 3)
                Set sc = wmObj.%Save()
                If $$$ISOK(sc) {
                    Set newWm = maxWm
                    Do ##class(ETLWizard.Model.Event).Append(runId, "watermark.updated", "",
                        {"column": (watermarkColumn), "previous": (prevWm), "current": (maxWm)})
                }
            }
        }
        Return {"strategy": "append_only", "rowsAppended": (rows),
                "previousWatermark": (prevWm), "newWatermark": (newWm)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// CSV Incremental by File Arrival (spec §7): loads every not-yet-processed
/// file from the dropzone CSV foreign server into ETLW_TARGET.<base> by
/// remounting a per-file foreign table. Processed files are remembered per
/// baseName and skipped on later runs.
Method RunCsvArrivalLoad(runId As %String, baseName As %String, csvServerName As %String, columnDefs As %String) As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunCsvArrivalLoadInner(runId, baseName, csvServerName, columnDefs)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunCsvArrivalLoadInner(runId As %String, baseName As %String, csvServerName As %String, columnDefs As %String) As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", csvServerName) {
            Return "ERROR: invalid csvServerName"
        }
        If '$ClassMethod(util, "ValidColumnDefs", columnDefs) {
            Return "ERROR: invalid column definition list"
        }
        // Column names from the defs ("SaleId INTEGER, Amount NUMERIC(18,4)"
        // -> "SaleId, Amount"): commas inside type parens must not split
        Set cleaned = ""
        Set depth = 0
        For j = 1:1:$Length(columnDefs) {
            Set ch = $Extract(columnDefs, j)
            If ch = "(" {
                Set depth = depth + 1
            }
            If ch = ")" {
                Set depth = depth - 1
            }
            Set cleaned = cleaned _ $Select((ch = ",") && (depth > 0): ";", 1: ch)
        }
        Set colList = ""
        For i = 1:1:$Length(cleaned, ",") {
            Set colName = $Piece($ZStrip($Piece(cleaned, ",", i), "<>W"), " ", 1)
            Set colList = colList _ $Select(colList = "": "", 1: ", ") _ colName
        }
        Set target = "ETLW_TARGET." _ baseName
        Set ftName = baseName _ "_csvfile"
        Set files = []
        Set totalRows = 0
        Set processed = 0
        Set rs = ##class(%ResultSet).%New("%File:FileSet")
        Set sc = rs.Execute("/opt/irisbuild/dropzone", "*.csv")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        While rs.Next() {
            Set fileName = rs.Get("ItemName")
            If $Data(^ETLWizard.CsvProcessed(baseName, fileName)) {
                Continue
            }
            // Remount the per-file foreign table
            Do $ClassMethod(util, "RunDDL", "DROP FOREIGN TABLE ETLWIZARD." _ ftName)
            Set ddl = "CREATE FOREIGN TABLE ETLWIZARD." _ ftName _ " (" _ columnDefs _ ")" _
                      " SERVER ETLWIZARD." _ csvServerName _ " FILE '" _ fileName _ "'" _
                      " USING {""from"":{""file"":{""header"":1}}}"
            Set res = $ClassMethod(util, "RunDDL", ddl)
            If res '= "" {
                Do files.%Push({"file": (fileName), "error": (res)})
                Continue
            }
            Set res = $ClassMethod(util, "RunDML",
                "INSERT INTO " _ target _ " (" _ colList _ ", etl_created_at, etl_updated_at) " _
                "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM ETLWIZARD." _ ftName)
            If $Extract(res, 1, 5) = "ERROR" {
                Do files.%Push({"file": (fileName), "error": (res)})
                Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (fileName), "status": "failed", "error": (res)})
                Continue
            }
            Set rows = +$Piece(res, ":", 2)
            Set ^ETLWizard.CsvProcessed(baseName, fileName) = $ZDateTime($ZTimeStamp, 3, , 3)
            Set totalRows = totalRows + rows
            Set processed = processed + 1
            Do files.%Push({"file": (fileName), "rows": (rows)})
            Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "",
                {"name": (fileName), "status": "succeeded", "rowCount": (rows)})
        }
        Return {"strategy": "csv_file_arrival", "filesProcessed": (processed),
                "rowsLoaded": (totalRows), "files": (files)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Create the rejected-row quarantine table ETLW_AUDIT.<base>_quarantine
/// (spec §8, §17) shaped like the foreign table plus reason/timestamp.
/// (Lives here rather than DataQuality so it shares the class auth gate.)
Method CreateQuarantineTable(runId As %String, baseName As %String, foreignTable As %String) As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        Set quarantine = "ETLW_AUDIT." _ baseName _ "_quarantine"
        Set ddl = "CREATE TABLE " _ quarantine _ " (" _ ddlDefs _ ", etl_reason VARCHAR(200), etl_quarantined_at TIMESTAMP)"
        Set res = $ClassMethod(util, "RunDDL", ddl)
        If res '= "" {
            Return res
        }
        Do $ClassMethod(util, "CatalogNode", runId, "quarantine", quarantine, ddl, "")
        Return "Created quarantine table " _ quarantine
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Route staging rows with a NULL primary key to the quarantine table and
/// remove them from staging, so they never reach the target (spec §17).
/// Run between staging and the merge step.
Method RouteInvalidRows(runId As %String, baseName As %String, foreignTable As %String, pkColumn As %String) As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "ValidIdent", pkColumn) {
            Return "ERROR: invalid pkColumn"
        }
        Set err = ..GetFtColumns(foreignTable, .colList, .ddlDefs)
        If err '= "" {
            Return err
        }
        Set staging = "ETLW_STAGING." _ baseName _ "_delta"
        Set quarantine = "ETLW_AUDIT." _ baseName _ "_quarantine"
        Set res = $ClassMethod(util, "RunDML",
            "INSERT INTO " _ quarantine _ " (" _ colList _ ", etl_reason, etl_quarantined_at) " _
            "SELECT " _ colList _ ", 'null primary key', CURRENT_TIMESTAMP FROM " _ staging _
            " WHERE " _ pkColumn _ " IS NULL")
        If $Extract(res, 1, 5) = "ERROR" {
            Return res
        }
        Set routed = +$Piece(res, ":", 2)
        If routed > 0 {
            Do $ClassMethod(util, "RunDML", "DELETE FROM " _ staging _ " WHERE " _ pkColumn _ " IS NULL")
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "check.result", "",
            {"check": "quarantine_null_pk", "routed": (routed), "table": (quarantine)})
        Return {"rowsQuarantined": (routed), "quarantineTable": (quarantine)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Bounded preview of a custom transform SELECT (read-only, ungated): returns
/// the result columns + a sample so the user/agent can validate joins,
/// cleansing, derivation, aggregation and filtering before deploying.
Method PreviewTransform(transformSql As %String, maxRows As %Integer = 10) As %String
{
    Set util = "ETLWizard.Tools.Util"
    If '$ClassMethod(util, "IsSelectOnly", transformSql) {
        Return "ERROR: transform must be a single SELECT statement"
    }
    Set err = $ClassMethod(util, "GetSelectColumns", transformSql, .ddlDefs, .colList)
    If err '= "" {
        Return err
    }
    If maxRows > 50 {
        Set maxRows = 50
    }
    Set sample = $ClassMethod(util, "RunSelect", transformSql, maxRows)
    Try {
        Set out = {}
        Set out.columnDefs = ddlDefs
        Set out.columnList = colList
        // Columns whose alias was missing or not a valid identifier get named
        // col2/col3... — usable, but poor target column names. Say so.
        Set generated = ""
        For i = 1:1:$Length(colList, ",") {
            Set c = $ZStrip($Piece(colList, ",", i), "<>W")
            If (c ? 1"col"1.N) || (c ? 1"Expression_"1.N) {
                Set generated = generated _ $Select(generated = "": "", 1: ", ") _ c
            }
        }
        If generated '= "" {
            Set out.note = "These columns had no usable alias and were auto-named: " _ generated _
                ". Add ""AS a_clear_name"" (letters, digits, underscore) for better target columns."
        }
        Set out.sample = ##class(%DynamicObject).%FromJSON(sample)
        Return out.%ToJSON()
    } Catch {
        Return "{""columnDefs"":""" _ $Replace(ddlDefs, """", "\""") _ """,""sample"":" _ sample _ "}"
    }
}

/// Build the staging + target tables for a CUSTOM TRANSFORM pipeline, shaped to
/// the transform SELECT's result columns (spec §6.1). The SELECT may join
/// several mounted foreign tables and do cleansing / standardization /
/// derivation / aggregation / filtering — all in SQL. pkColumns is optional
/// (aggregations have none). Gated.
Method DeployTransform(runId As %String, baseName As %String, transformSql As %String, pkColumns As %String = "", sources As %String = "", loadConfig As %String = "") As %String
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        Set err = $ClassMethod(util, "GetSelectColumns", transformSql, .ddlDefs, .colList)
        If err '= "" {
            Return err
        }
        Set pkColumns = $ZStrip(pkColumns, "<>W")
        If pkColumns '= "" {
            For i = 1:1:$Length(pkColumns, ",") {
                If '$ClassMethod(util, "ValidIdent", $ZStrip($Piece(pkColumns, ",", i), "<>W")) {
                    Return "ERROR: invalid primary key column list"
                }
            }
        }
        Set staging = "ETLW_STAGING." _ baseName _ "_delta"
        Set target = "ETLW_TARGET." _ baseName
        Set pkClause = $Select(pkColumns '= "": ", PRIMARY KEY (" _ pkColumns _ ")", 1: "")

        // drop-and-recreate so a re-deploy with a changed transform re-shapes cleanly
        Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ staging)
        Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ target)
        Set err = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ staging _ " (" _ ddlDefs _ ")")
        If err '= "" {
            Return err
        }
        Set err = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ target _ " (" _ ddlDefs _
            ", etl_created_at TIMESTAMP, etl_updated_at TIMESTAMP" _ pkClause _ ")")

        If err '= "" {
            Return err
        }
        // Quarantine table for rows the target cannot accept (IMPROVEMENTS_SPEC
        // DA-5). Built here, next to the target, so the deterministic wizard
        // path has somewhere to put bad rows - previously CreateQuarantineTable
        // and RouteInvalidRows existed but NOTHING called them, so defective
        // rows were simply merged into the target or failed the run.
        // Single-column keys only: a composite key has no single "is null" test.
        If (pkColumns '= "") && ($Length(pkColumns, ",") = 1) {
            Set quarantine = "ETLW_AUDIT." _ baseName _ "_quarantine"
            Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ quarantine)
            Set qErr = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ quarantine _
                " (" _ ddlDefs _ ", etl_reason VARCHAR(200), etl_quarantined_at TIMESTAMP)")
            If qErr = "" {
                Do $ClassMethod(util, "CatalogNode", runId, "quarantine", quarantine, "", "")
            }
        }
        // VALIDATION LAYER: prepare the EXACT staging INSERT the runtime will run,
        // so a transform that is a valid SELECT but forms an invalid load DML
        // (e.g. a trailing comment swallowing the wrapper's ")") is rejected here
        // at save time — before any production item is created.
        Set innerV = $ClassMethod(util, "StripOrderBy", $ClassMethod(util, "StripSqlComments", transformSql))
        Set selectV = "SELECT * FROM (" _ innerV _ ") etl_t"
        Set stmtV = ##class(%SQL.Statement).%New()
        Set scV = stmtV.%Prepare("INSERT INTO " _ staging _ " (" _ colList _ ") " _ selectV)
        If $$$ISERR(scV) {
            // The set-based INSERT will not compile. That is fatal only if the
            // SELECT itself is bad — for an ODBC-linked source the load runs
            // through the cursor fallback instead, so check the SELECT alone
            // before rejecting the transform.
            Set stmtS = ##class(%SQL.Statement).%New()
            Set scS = stmtS.%Prepare(selectV)
            If $$$ISERR(scS) {
                Return "ERROR: the transform is a valid SELECT but does not form a valid load statement: " _
                    $System.Status.GetErrorText(scV) _ " — edit the SQL and preview again."
            }
        }
        // Idempotent re-deploy: clear this pipeline's prior graph so a second
        // deploy does not accumulate duplicate / stale (e.g. failed) nodes.
        Set run0 = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If $IsObject(run0) {
            Set pid0 = run0.Pipeline.%Id()
            Set ed = ##class(%SQL.Statement).%New()
            If $$$ISOK(ed.%Prepare("DELETE FROM ETLWizard_Model.Edge WHERE Pipeline = ?")) { Do ed.%Execute(pid0) }
            Set nd = ##class(%SQL.Statement).%New()
            If $$$ISOK(nd.%Prepare("DELETE FROM ETLWizard_Model.Node WHERE Pipeline = ?")) { Do nd.%Execute(pid0) }
        }
        Set xform = baseName _ "_transform"
        Do $ClassMethod(util, "CatalogNode", runId, "transform_view", xform, transformSql, "")
        Do $ClassMethod(util, "CatalogNode", runId, "staging", staging, "", "")
        Do $ClassMethod(util, "CatalogNode", runId, "target", target, "", "")
        Set cat = ##class(ETLWizard.Tools.Catalog).%New()
        // one foreign_table node per source, so the saved graph shows the Sources
        // cluster (skip any already recorded on this pipeline to avoid dup names)
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        For i = 1:1:$Length(sources, ",") {
            Set src = $ZStrip($Piece(sources, ",", i), "<>W")
            If src = "" {
                Continue
            }
            If '$IsObject(##class(ETLWizard.Model.Node).PipelineNameIdxOpen(run.Pipeline.%Id(), src)) {
                Do $ClassMethod(util, "CatalogNode", runId, "foreign_table", src, "", "")
            }
            Do cat.CatalogLink(runId, src, xform, "Source")
        }
        Do cat.CatalogLink(runId, xform, staging, "Transform")
        // load-config box between staging and target (the user's PK/strategy/
        // watermark/interval choices), so the saved graph carries them too
        If $ZStrip(loadConfig, "<>W") '= "" {
            Do $ClassMethod(util, "CatalogNode", runId, "load_config", "Load config", "", loadConfig)
            Do cat.CatalogLink(runId, staging, "Load config", $Select(pkColumns '= "": "Merge/Upsert", 1: "Insert"))
            Do cat.CatalogLink(runId, "Load config", target, "")
        } Else {
            Do cat.CatalogLink(runId, staging, target, $Select(pkColumns '= "": "Merge/Upsert", 1: "Insert"))
        }
        Return "Built transform target " _ target _ " (" _ colList _ ")"
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Run a custom-transform load: staging <- transform SELECT (optionally
/// watermark-filtered), then target <- staging by the chosen strategy
/// (merge when a PK exists, full when mode=full, else append). Gated,
/// serialized per base. Returns stats JSON.
Method RunTransformLoad(runId As %String, baseName As %String, transformSql As %String, mode As %String = "incremental", watermarkColumn As %String = "") As %String
{
    Lock +^ETLWizard.LoadLock(baseName):20
    If '$Test {
        Return "ERROR: another load for '" _ baseName _ "' is already running - try again shortly"
    }
    Set result = ..RunTransformLoadInner(runId, baseName, transformSql, mode, watermarkColumn)
    Lock -^ETLWizard.LoadLock(baseName)
    Return result
}

Method RunTransformLoadInner(runId As %String, baseName As %String, transformSql As %String, mode As %String, watermarkColumn As %String) As %String [ Internal, Private ]
{
    Try {
        Set util = "ETLWizard.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            Return "ERROR: invalid baseName"
        }
        If '$ClassMethod(util, "IsSelectOnly", transformSql) {
            Return "ERROR: transform must be a single SELECT statement"
        }
        If (watermarkColumn '= "") && ('$ClassMethod(util, "ValidIdent", watermarkColumn)) {
            Return "ERROR: invalid watermarkColumn"
        }
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set err = $ClassMethod(util, "GetSelectColumns", transformSql, .ddlDefs, .colList)
        If err '= "" {
            Return err
        }
        Set staging = "ETLW_STAGING." _ baseName _ "_delta"
        Set target = "ETLW_TARGET." _ baseName

        // previous watermark (incremental transforms)
        Set prevWm = ""
        Set prevWmType = ""
        Set wmObj = ##class(ETLWizard.Model.Watermark).PipelineIdxOpen(run.Pipeline.%Id())
        If $IsObject(wmObj) {
            Set prevWmType = wmObj.Type
            Set prevWm = wmObj.LastValue
        }

        // 1. Rebuild staging from the transform SELECT (join/cleanse/derive/aggregate/filter)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (baseName _ "_transform"), "status": "running"})
        Do $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ staging)
        // Insert POSITIONALLY (SELECT *), never by name: colList holds the names
        // we synthesized for the target (col2/col3 for unaliased expressions,
        // customer_id_2 for a duplicate from "a.*, b.*"). Those names exist only
        // in our DDL — selecting them from the subquery fails with
        // "Field 'COL2' not found". SELECT * projects the columns in the same
        // order the metadata gave us, so the mapping is exact.
        // A trailing ORDER BY is illegal inside the derived table below (and
        // pointless when loading a table), so drop it.
        Set innerSql = $ClassMethod(util, "StripOrderBy", $ClassMethod(util, "StripSqlComments", transformSql))
        Set stageSelect = "SELECT * FROM (" _ innerSql _ ") etl_t"
        // InsertFromSelect, not RunDML: an ODBC-linked source cannot be read by a
        // set-based INSERT ... SELECT (see Util.InsertFromSelect) and falls back
        // to a cursor copy there
        If (mode = "incremental") && (watermarkColumn '= "") && (prevWm '= "") {
            // CAST(? AS TIMESTAMP), not a bare "?", for a timestamp watermark.
            // Wrapping the transform in a derived table loses the column's
            // TIMESTAMP typing, so the bound string is compared against the
            // logical value and matches NOTHING - the run then reports success
            // having loaded zero rows. Measured on 45 genuinely new rows:
            //   ... FROM ETLWIZARD.ext_orders WHERE ordered_at > ?        -> 45
            //   ... FROM (<transform>) etl_t WHERE etl_t.ordered_at > ?   ->  0
            //   ... FROM (<transform>) etl_t WHERE ... > CAST(? AS TIMESTAMP) -> 45
            // A numeric watermark must NOT be cast, hence the type test.
            Set wmParam = $Select(prevWmType = "timestamp": "CAST(? AS TIMESTAMP)", 1: "?")
            Set res = $ClassMethod(util, "InsertFromSelect", staging, colList,
                stageSelect _ " WHERE etl_t." _ watermarkColumn _ " > " _ wmParam, prevWm)
        } Else {
            Set res = $ClassMethod(util, "InsertFromSelect", staging, colList, stageSelect)
        }
        If $Extract(res, 1, 5) = "ERROR" {
            Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (baseName _ "_transform"), "status": "failed", "error": (res)})
            Return res
        }
        Set rowsStaged = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (staging), "status": "succeeded", "rowCount": (rowsStaged)})

        If rowsStaged = 0 {
            Return {"strategy": "transform", "rowsStaged": 0, "rowsLoaded": 0,
                    "previousWatermark": (prevWm), "newWatermark": (prevWm),
                    "note": "no rows from transform (nothing new)"}.%ToJSON()
        }

        // 1b. Quarantine rows the target cannot key (IMPROVEMENTS_SPEC DA-5).
        // Rows with a NULL primary key are moved OUT of staging into
        // ETLW_AUDIT.<base>_quarantine before the target load, so they are
        // isolated and counted rather than silently dropped or failing the run.
        //
        // The key is read from the pipeline's own metadata rather than passed
        // in, deliberately: this method is called from the wizard, the runtime
        // executor and the production Load operation, and none of their
        // signatures has to change for all three to gain the behaviour.
        Set rowsQuarantined = 0
        Set pkCol = ""
        Try {
            If run.Pipeline.MetadataJson '= "" {
                Set metaObj = ##class(%DynamicObject).%FromJSON(run.Pipeline.MetadataJson)
                If $IsObject(metaObj.%Get("transform", "")) {
                    Set pkCol = $ZStrip(metaObj.transform.%Get("pkColumns", ""), "<>W")
                }
            }
        } Catch {
            Set pkCol = ""
        }
        If (pkCol '= ""), $Length(pkCol, ",") = 1, $ClassMethod(util, "ValidIdent", pkCol) {
            Set quarantine = "ETLW_AUDIT." _ baseName _ "_quarantine"
            Set qExists = +$ClassMethod(util, "ScalarQuery",
                "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLW_AUDIT' AND TABLE_NAME = ?",
                baseName _ "_quarantine")
            If qExists {
                // A full recompute re-stages every row, so it re-rejects every
                // bad row too: without this the audit table accumulates a
                // duplicate set on EVERY scheduled run, and the "rejected"
                // figure climbs forever while the data is unchanged. Only an
                // incremental delta legitimately ADDS to the existing rejects.
                Set fullRebuild = '((mode = "incremental") && (watermarkColumn '= "") && (prevWm '= ""))
                If fullRebuild {
                    Do $ClassMethod(util, "RunDML", "DELETE FROM " _ quarantine)
                }
                Set qRes = $ClassMethod(util, "RunDML",
                    "INSERT INTO " _ quarantine _ " (" _ colList _ ", etl_reason, etl_quarantined_at) " _
                    "SELECT " _ colList _ ", 'null primary key', CURRENT_TIMESTAMP FROM " _ staging _
                    " WHERE " _ pkCol _ " IS NULL")
                If $Extract(qRes, 1, 5) '= "ERROR" {
                    Set rowsQuarantined = +$Piece(qRes, ":", 2)
                    If rowsQuarantined > 0 {
                        Do $ClassMethod(util, "RunDML", "DELETE FROM " _ staging _ " WHERE " _ pkCol _ " IS NULL")
                        Set rowsStaged = rowsStaged - rowsQuarantined
                    }
                    Do ##class(ETLWizard.Model.Event).Append(runId, "check.result", "",
                        {"check": "quarantine_null_pk", "routed": (rowsQuarantined), "table": (quarantine)})
                }
            }
        }

        // 2. Load target from staging by strategy.
        //    - append: accumulate rows.
        //    - incremental WITH a watermark: staging is a delta -> merge/upsert.
        //    - otherwise (full, or a transform with no watermark): staging is a
        //      full recompute of the join/aggregation, so REPLACE the target so
        //      re-runs are idempotent (a plain merge would hit PK violations).
        If mode = "snapshot" {
            // dated point-in-time copy, so history is kept per run (spec §7/§8)
            Set suffix = $Translate($ZDateTime($ZTimeStamp, 8), " :", "_") _ "_" _ $Increment(^ETLWizard.SnapSeq)
            Set snap = "ETLW_TARGET." _ baseName _ "_snap_" _ suffix
            Set ddlErr = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ snap _ " (" _ ddlDefs _ ", etl_snapshot_at TIMESTAMP)")
            If ddlErr '= "" {
                Return ddlErr
            }
            Set res = $ClassMethod(util, "RunDML",
                "INSERT INTO " _ snap _ " (" _ colList _ ", etl_snapshot_at) " _
                "SELECT " _ colList _ ", CURRENT_TIMESTAMP FROM " _ staging)
            If $Extract(res, 1, 5) '= "ERROR" {
                Do $ClassMethod(util, "CatalogNode", runId, "target", snap, "", "")
                Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "",
                    {"name": (snap), "status": "succeeded", "rowCount": (+$Piece(res, ":", 2))})
            }
        } ElseIf mode = "append" {
            Set res = $ClassMethod(util, "RunDML",
                "INSERT INTO " _ target _ " (" _ colList _ ", etl_created_at, etl_updated_at) " _
                "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM " _ staging)
        } ElseIf (mode = "incremental") && (watermarkColumn '= "") {
            Set res = $ClassMethod(util, "RunDML",
                "INSERT OR UPDATE INTO " _ target _ " (" _ colList _ ", etl_created_at, etl_updated_at) " _
                "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM " _ staging)
        } Else {
            Do $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ target)
            Set res = $ClassMethod(util, "RunDML",
                "INSERT INTO " _ target _ " (" _ colList _ ", etl_created_at, etl_updated_at) " _
                "SELECT " _ colList _ ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM " _ staging)
        }
        If $Extract(res, 1, 5) = "ERROR" {
            // A unique-check failure here almost always means the target has a
            // primary key while the strategy keeps adding rows — say so plainly
            // instead of leaving the user with a bare SQLCODE.
            If (res [ "-119") || ($ZConvert(res, "L") [ "unique check") {
                Set res = res _ " || The target has a primary key but this run inserted a key that is already there. " _
                    "For a recomputed result use Merge/Upsert or Full reload; for a true append log, redeploy without a primary key."
            }
            Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "failed", "error": (res)})
            Return res
        }
        Set rowsLoaded = +$Piece(res, ":", 2)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "", {"name": (target), "status": "succeeded", "rowCount": (rowsLoaded)})

        // 3. Advance watermark on success (incremental transforms only)
        Set newWm = prevWm
        If (mode = "incremental") && (watermarkColumn '= "") {
            // %EXTERNAL, not a bare MAX(): on a %TimeStamp column IRIS returns the
            // LOGICAL value (1154709446288886490), and that is what used to be
            // persisted as the watermark. The next run then filtered
            // "WHERE ordered_at > 1154709446288886490" against the source's real
            // timestamp, matched nothing, and reported SUCCESS having loaded zero
            // rows - silently, on every incremental run after the first. It also
            // made the watermark record itself claim Type="numeric" on a
            // timestamp column, because the logical form is a number.
            // %EXTERNAL returns "2026-08-28 18:28:02.039514", which compares
            // correctly and types correctly.
            Set maxWm = $ClassMethod(util, "ScalarQuery", "SELECT %EXTERNAL(MAX(" _ watermarkColumn _ ")) FROM " _ staging)
            If ($Extract(maxWm, 1, 5) '= "ERROR") && (maxWm '= "") {
                If '$IsObject(wmObj) {
                    Set wmObj = ##class(ETLWizard.Model.Watermark).%New()
                    Set wmObj.Pipeline = run.Pipeline
                    Set wmObj.Type = $Select($IsValidNum(maxWm): "numeric", 1: "timestamp")
                    Set wmObj.ColumnName = watermarkColumn
                }
                Set wmObj.LastValue = maxWm
                Set wmObj.UpdatedByRun = run
                Set wmObj.UpdatedAt = $ZDateTime($ZTimeStamp, 3, , 3)
                If $$$ISOK(wmObj.%Save()) {
                    Set newWm = maxWm
                    Do ##class(ETLWizard.Model.Event).Append(runId, "watermark.updated", "",
                        {"column": (watermarkColumn), "previous": (prevWm), "current": (maxWm)})
                }
            }
        }
        Return {"strategy": "transform", "rowsStaged": (rowsStaged), "rowsLoaded": (rowsLoaded),
                "rowsQuarantined": (rowsQuarantined),
                "previousWatermark": (prevWm), "newWatermark": (newWm)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Single strategy dispatch used by BOTH the manual executor and the
/// production LoadOperation, so every trigger path (wizard, manual Run,
/// scheduled production) runs a strategy identically (spec §13, §23.5).
/// mode: full | incremental | snapshot | append | csv_arrival.
/// When transformSql is non-empty the pipeline is a CUSTOM TRANSFORM (may join
/// multiple foreign tables + cleanse/derive/aggregate/filter) — staging is
/// populated from that SELECT rather than a single foreign table.
/// Returns {load, reconcile} stats JSON, or ERROR text.
Method RunPlan(runId As %String, baseName As %String, foreignTable As %String, mode As %String, wmColumn As %String = "", csvServer As %String = "", columnDefs As %String = "", transformSql As %String = "") As %String
{
    Try {
        If mode = "bulk" {
            Set result = ##class(ETLWizard.Tools.BulkLoad).RunBulkLoad(runId, baseName)
        } ElseIf transformSql '= "" {
            Set result = ..RunTransformLoad(runId, baseName, transformSql, mode, wmColumn)
        } ElseIf mode = "full" {
            Set result = ..RunFullLoad(runId, baseName, foreignTable)
        } ElseIf mode = "snapshot" {
            Set result = ..RunSnapshotLoad(runId, baseName, foreignTable)
        } ElseIf mode = "append" {
            Set result = ..RunAppendOnlyLoad(runId, baseName, foreignTable, wmColumn)
        } ElseIf mode = "csv_arrival" {
            Set result = ..RunCsvArrivalLoad(runId, baseName, csvServer, columnDefs)
        } Else {
            Set result = ..RunIncrementalLoad(runId, baseName, foreignTable, wmColumn)
        }
        If $Extract(result, 1, 5) = "ERROR" {
            Return result
        }
        Set stats = {}
        Try {
            Set stats.load = ##class(%DynamicObject).%FromJSON(result)
        } Catch {
            Set stats.load = result
        }
        // Count reconciliation only makes sense for latest-state loads where the
        // target should mirror a single source. Snapshot/append/csv-arrival
        // accumulate, and transforms reshape the data, so no match is expected.
        If (transformSql = "") && ($ListFind($ListBuild("full", "incremental"), mode) > 0) {
            Set dq = ##class(ETLWizard.Tools.DataQuality).%New()
            Set reconcile = dq.ReconcileCounts(runId, "ETLWIZARD." _ foreignTable, "ETLW_TARGET." _ baseName)
            Try {
                Set stats.reconcile = ##class(%DynamicObject).%FromJSON(reconcile)
            } Catch {
                Set stats.reconcile = reconcile
            }
        }
        Return stats.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Column list + DDL definitions of a mounted foreign table.
ClassMethod GetFtColumns(foreignTable As %String, Output colList As %String, Output ddlDefs As %String) As %String [ Internal, Private ]
{
    Set colList = ""
    Set ddlDefs = ""
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(
            "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(foreignTable)
        While rs.%Next() {
            Set name = rs.%GetData(1)
            Set dtype = $ZConvert(rs.%GetData(2), "L")
            Set maxLen = rs.%GetData(3)
            Set sqlType = $Case(dtype,
                "bigint": "BIGINT",
                "integer": "INTEGER",
                "smallint": "INTEGER",
                // JDBC FT auto-import reports CHARACTER_MAXIMUM_LENGTH=1 for
                // varchar (build 162 quirk) - treat <=1 as unknown
                "varchar": "VARCHAR(" _ $Select(+maxLen > 1: maxLen, 1: 500) _ ")",
                "timestamp": "TIMESTAMP",
                "date": "DATE",
                "numeric": "NUMERIC(18,4)",
                "double": "DOUBLE",
                "bit": "BIT",
                : "VARCHAR(500)")
            Set colList = colList _ $Select(colList = "": "", 1: ", ") _ name
            Set ddlDefs = ddlDefs _ $Select(ddlDefs = "": "", 1: ", ") _ name _ " " _ sqlType
        }
        If colList = "" {
            Return "ERROR: foreign table ETLWIZARD." _ foreignTable _ " not found or has no columns"
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

}
