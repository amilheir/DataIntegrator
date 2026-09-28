/// Shared helpers for tool classes. NOT part of the ToolSet (not %AI.Tool),
/// so nothing here is exposed to the agent. Implements the SQL-safety rules
/// of spec §16.3: identifier validation, SELECT-only passthrough, single
/// statement, bounded reads, and the standard result envelope
/// {rows, row_count, truncated, elapsed_ms}.
Class DataIntegrator.Tools.Util Extends %RegisteredObject
{

/// Bare SQL identifier: letter followed by letters/digits/underscores.
ClassMethod ValidIdent(name As %String) As %Boolean
{
    Return name ? 1A.(1AN,1"_")
}

/// Qualified name with at most one dot (schema.table). Each part validated.
ClassMethod ValidQualified(name As %String) As %Boolean
{
    Set parts = $Length(name, ".")
    If parts > 2 {
        Return 0
    }
    For i = 1:1:parts {
        If '..ValidIdent($Piece(name, ".", i)) {
            Return 0
        }
    }
    Return 1
}

/// Column-definition list for CSV foreign tables: "Name TYPE, Name TYPE(n,m)".
/// Restricted character set — no quotes, semicolons, or statement text.
ClassMethod ValidColumnDefs(defs As %String) As %Boolean
{
    If defs = "" {
        Return 0
    }
    Set ok = 1
    For i = 1:1:$Length(defs) {
        Set ch = $Extract(defs, i)
        If ('$Match(ch, "[A-Za-z0-9_(),. ]")) {
            Set ok = 0
            Quit
        }
    }
    Return ok
}

/// Reject anything that is not a single SELECT statement (spec §16.3).
ClassMethod IsSelectOnly(sql As %String) As %Boolean
{
    Set trimmed = $ZStrip(sql, "<>W")
    // strip one optional trailing semicolon, then reject embedded ones
    If $Extract(trimmed, *) = ";" {
        Set trimmed = $Extract(trimmed, 1, * - 1)
    }
    If trimmed [ ";" {
        Return 0
    }
    Return $ZConvert($Extract(trimmed, 1, 6), "U") = "SELECT"
}

/// Execute a bounded SELECT and return the standard JSON envelope as a string.
ClassMethod RunSelect(sql As %String, maxRows As %Integer = 50) As %String
{
    Set start = $ZHorolog
    Try {
        If maxRows > 200 {
            Set maxRows = 200
        }
        Set stmt = ##class(%SQL.Statement).%New()
        // %SelectMode 1 (ODBC), not the default 0 (logical). Everything this
        // method produces is for DISPLAY - the transform preview, the mount
        // probe, passthrough results - and in logical mode a %TimeStamp column
        // reaches the screen as 1154705814002363000. Numbers and strings are
        // unaffected by the mode; dates, times and booleans are the point.
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR preparing SQL: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR: SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message
        }
        Set meta = rs.%GetMetadata()
        Set colCount = meta.columnCount
        Set rows = []
        Set count = 0
        Set truncated = 0
        While rs.%Next() {
            If count >= maxRows {
                Set truncated = 1
                Quit
            }
            Set row = {}
            For c = 1:1:colCount {
                Set colName = meta.columns.GetAt(c).colName
                Do row.%Set(colName, rs.%GetData(c))
            }
            Do rows.%Push(row)
            Set count = count + 1
        }
        Set elapsed = $Number(($ZHorolog - start) * 1000, 0)
        Return {"rows": (rows), "row_count": (count), "truncated": (truncated), "elapsed_ms": (elapsed)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Execute a SELECT-only passthrough query on a foreign server:
/// THROUGH <server> <remoteSql> (spec §4.2, §6.2). serverName is the bare
/// name within the DATAINTEGRATOR schema.
ClassMethod Through(serverName As %String, remoteSql As %String, maxRows As %Integer = 50) As %String
{
    If '..ValidIdent(serverName) {
        Return "ERROR: invalid server name: " _ serverName
    }
    If '..IsSelectOnly(remoteSql) {
        Return "ERROR: passthrough queries must be a single SELECT statement"
    }
    Return ..RunSelect("THROUGH SERVER DATAINTEGRATOR." _ serverName _ " " _ remoteSql, maxRows)
}

/// Execute a single DDL statement (already validated/assembled by the caller).
/// Returns "" on success or an error message.
ClassMethod RunDDL(sql As %String) As %String
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR preparing DDL: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR: SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Execute a single parameterized DML statement (INSERT/UPDATE/TRUNCATE).
/// Returns "OK:<rowcount>" or "ERROR: ...".
ClassMethod RunDML(sql As %String, args...) As %String
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR preparing DML: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(args...)
        If rs.%SQLCODE < 0 {
            Return "ERROR: SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message
        }
        Return "OK:" _ rs.%ROWCOUNT
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Load a staging table from a SELECT, coping with sources IRIS cannot compile
/// an INSERT ... SELECT against.
///
/// ODBC-linked tables are one such source: SELECT from the link works, and so
/// does INSERT ... SELECT from a JDBC foreign table, but the two together crash
/// the SQL compiler with
///   <UNDEFINED>parseExtFromNode+1^%qaqcmx *mt("f","1^ETLW_STAGING....")
/// (verified on 2026.3.0AI build 125). So: try the set-based INSERT first — it
/// is the fast path and stays the norm for JDBC/CSV/local sources — and when it
/// will not prepare, stream the rows through a cursor instead. Same result,
/// same "OK:<rows>" contract as RunDML.
ClassMethod InsertFromSelect(targetTable As %String, colList As %String, selectSql As %String, args...) As %String
{
    Set insertSql = "INSERT INTO " _ targetTable _ " (" _ colList _ ") " _ selectSql
    Set stmt = ##class(%SQL.Statement).%New()
    If $$$ISOK(stmt.%Prepare(insertSql)) {
        Return ..RunDML(insertSql, args...)
    }
    Return ..InsertFromSelectByRow(targetTable, colList, selectSql, args...)
}

/// Cursor fallback for InsertFromSelect: read the SELECT, insert row by row.
/// Slower than a set-based INSERT, so it is only ever reached when the compiler
/// rejects the set-based form.
ClassMethod InsertFromSelectByRow(targetTable As %String, colList As %String, selectSql As %String, args...) As %String [ Internal ]
{
    Try {
        Set src = ##class(%SQL.Statement).%New()
        Set sc = src.%Prepare(selectSql)
        If $$$ISERR(sc) {
            Return "ERROR preparing DML: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = src.%Execute(args...)
        If rs.%SQLCODE < 0 {
            Return "ERROR: SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message
        }
        Set cols = $Length(colList, ",")
        Set marks = ""
        For i = 1:1:cols {
            Set marks = marks _ $Select(i = 1: "", 1: ",") _ "?"
        }
        Set ins = ##class(%SQL.Statement).%New()
        Set sc = ins.%Prepare("INSERT INTO " _ targetTable _ " (" _ colList _ ") VALUES (" _ marks _ ")")
        If $$$ISERR(sc) {
            Return "ERROR preparing DML: " _ $System.Status.GetErrorText(sc)
        }
        Set rows = 0
        TSTART
        While rs.%Next() {
            Kill vals
            Set vals = cols
            For i = 1:1:cols {
                Set vals(i) = rs.%GetData(i)
            }
            Set irs = $Method(ins, "%Execute", vals...)
            If irs.%SQLCODE < 0 {
                TROLLBACK
                Return "ERROR: SQLCODE " _ irs.%SQLCODE _ ": " _ irs.%Message
            }
            Set rows = rows + 1
        }
        TCOMMIT
        Return "OK:" _ rows
    } Catch ex {
        If $TLevel > 0 {
            TROLLBACK
        }
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// First column of the first row of a parameterized SELECT ("" when no row).
/// Errors return "ERROR: ...".
ClassMethod ScalarQuery(sql As %String, args...) As %String
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR preparing SQL: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(args...)
        If rs.%SQLCODE < 0 {
            Return "ERROR: SQLCODE " _ rs.%SQLCODE _ ": " _ rs.%Message
        }
        If rs.%Next() {
            Return rs.%GetData(1)
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Remove a trailing top-level ORDER BY clause.
/// A transform SELECT gets wrapped in a derived table ( SELECT ... ) etl_t to
/// load it, and SQL forbids ORDER BY there ("')' expected, IDENTIFIER (ORDER)
/// found"). Row order is meaningless when inserting into a table anyway, so the
/// clause is simply dropped. ORDER BY nested inside parentheses or inside a
/// string literal is left untouched.
ClassMethod StripOrderBy(sql As %String) As %String
{
    Set depth = 0
    Set inStr = 0
    Set cut = 0
    Set up = $ZConvert(sql, "U")
    For i = 1:1:$Length(sql) {
        Set ch = $Extract(sql, i)
        If inStr {
            If ch = "'" {
                Set inStr = 0
            }
            Continue
        }
        If ch = "'" {
            Set inStr = 1
            Continue
        }
        If ch = "(" {
            Set depth = depth + 1
            Continue
        }
        If ch = ")" {
            Set depth = depth - 1
            Continue
        }
        If (depth '= 0) || ($Extract(up, i, i + 4) '= "ORDER") {
            Continue
        }
        // must start a word
        If i > 1 {
            Set prev = $Extract(sql, i - 1)
            If '((prev = " ") || (prev = $Char(9)) || (prev = $Char(10)) || (prev = $Char(13)) || (prev = ")")) {
                Continue
            }
        }
        // next word must be BY (skip any whitespace, incl. newlines)
        Set j = i + 5
        While j <= $Length(sql) {
            Set w = $Extract(sql, j)
            If (w '= " ") && (w '= $Char(9)) && (w '= $Char(10)) && (w '= $Char(13)) {
                Quit
            }
            Set j = j + 1
        }
        If $Extract(up, j, j + 1) = "BY" {
            Set cut = i
        }
    }
    If cut > 0 {
        Return $ZStrip($Extract(sql, 1, cut - 1), "<>W")
    }
    Return sql
}

/// Strip SQL comments — block /* ... */ and line -- ... — from a statement,
/// string-literal aware so a comment marker inside a quoted string is kept.
/// A trailing comment is what breaks "SELECT * FROM (<sql>) etl_t": the comment
/// runs past the closing paren (e.g. IRIS's own /*#OPTIONS {"DynamicSQL":1} */),
/// so the wrapper never sees its ")". Removing comments first makes the wrap safe.
ClassMethod StripSqlComments(sql As %String) As %String
{
    Set out = "", i = 1, len = $Length(sql), inStr = 0
    While i <= len {
        Set ch = $Extract(sql, i)
        If inStr {
            Set out = out _ ch
            If ch = "'" { Set inStr = 0 }
            Set i = i + 1
            Continue
        }
        If ch = "'" {
            Set out = out _ ch, inStr = 1, i = i + 1
            Continue
        }
        If (ch = "-") && ($Extract(sql, i + 1) = "-") {
            While (i <= len) && ($Extract(sql, i) '= $Char(10)) { Set i = i + 1 }
            Set out = out _ " "
            Continue
        }
        If (ch = "/") && ($Extract(sql, i + 1) = "*") {
            Set i = i + 2
            While (i <= len) && '(($Extract(sql, i) = "*") && ($Extract(sql, i + 1) = "/")) { Set i = i + 1 }
            Set i = i + 2
            Set out = out _ " "
            Continue
        }
        Set out = out _ ch
        Set i = i + 1
    }
    Return $ZStrip(out, "<>W")
}

/// Extract the top-level GROUP BY column list from a SELECT, reduced to bare
/// column identifiers (any "alias." prefix stripped). Returns a comma-separated
/// list, or "" if the query has no GROUP BY. Paren- and string-literal-aware so
/// commas inside function calls / subqueries do not split a group item. Only
/// plain identifiers are returned — a grouped expression like EXTRACT(...) has
/// no single result column and is skipped. These grouping columns are the
/// natural primary key of an aggregated result (spec §9 upsert grain).
ClassMethod GroupByColumns(sql As %String) As %String
{
    Set depth = 0, inStr = 0, start = 0, stop = 0
    Set up = $ZConvert(sql, "U")
    Set len = $Length(sql)
    For i = 1:1:len {
        Set ch = $Extract(sql, i)
        If inStr { If ch = "'" { Set inStr = 0 } Continue }
        If ch = "'" { Set inStr = 1 Continue }
        If ch = "(" { Set depth = depth + 1 Continue }
        If ch = ")" { Set depth = depth - 1 Continue }
        If depth '= 0 { Continue }
        // find the start of the GROUP BY list (once)
        If (start = 0) && ($Extract(up, i, i + 4) = "GROUP") && ..WordStart(sql, i) {
            Set j = ..SkipWs(sql, i + 5)
            If $Extract(up, j, j + 1) = "BY" {
                Set start = ..SkipWs(sql, j + 2)
            }
            Continue
        }
        // once inside the list, a top-level HAVING / ORDER ends it
        If start '= 0 {
            If (($Extract(up, i, i + 5) = "HAVING") && ..WordStart(sql, i)) ||
               (($Extract(up, i, i + 4) = "ORDER") && ..WordStart(sql, i)) {
                Set stop = i - 1
                Quit
            }
        }
    }
    If start = 0 { Return "" }
    If stop = 0 { Set stop = len }
    Set segment = $ZStrip($Extract(sql, start, stop), "<>W")
    // split on top-level commas
    Set out = "", d2 = 0, s2 = 0, cur = ""
    For i = 1:1:$Length(segment) {
        Set ch = $Extract(segment, i)
        If s2 { If ch = "'" { Set s2 = 0 } Set cur = cur _ ch Continue }
        If ch = "'" { Set s2 = 1 Set cur = cur _ ch Continue }
        If ch = "(" { Set d2 = d2 + 1 Set cur = cur _ ch Continue }
        If ch = ")" { Set d2 = d2 - 1 Set cur = cur _ ch Continue }
        If (ch = ",") && (d2 = 0) {
            Set out = out _ $ListBuild(cur)
            Set cur = ""
            Continue
        }
        Set cur = cur _ ch
    }
    If $ZStrip(cur, "<>W") '= "" { Set out = out _ $ListBuild(cur) }
    // reduce each item to a bare identifier (strip alias prefix); drop expressions
    Set result = "", p = 0
    While $ListNext(out, p, item) {
        Set item = $ZStrip(item, "<>W")
        Set bare = $Piece(item, ".", *)          // c.customer_id -> customer_id
        If ..ValidIdent(bare) {
            Set result = result _ $Select(result = "": "", 1: ", ") _ bare
        }
    }
    Return result
}

/// True if position i in sql begins a word (preceded by start-of-string or a
/// non-identifier character).
ClassMethod WordStart(sql As %String, i As %Integer) As %Boolean [ Internal ]
{
    If i <= 1 { Return 1 }
    Set prev = $Extract(sql, i - 1)
    Return '(prev?1(1A,1N,1"_"))
}

/// Return the index of the first non-whitespace character at or after i.
ClassMethod SkipWs(sql As %String, i As %Integer) As %Integer [ Internal ]
{
    Set len = $Length(sql)
    While i <= len {
        Set w = $Extract(sql, i)
        If (w '= " ") && (w '= $Char(9)) && (w '= $Char(10)) && (w '= $Char(13)) { Quit }
        Set i = i + 1
    }
    Return i
}

/// Prepare a SELECT and derive DDL column definitions + a plain column list
/// from its result-set metadata. This lets a target/staging table be built to
/// fit ANY transform SELECT (joins, aggregates, computed columns), so a pipeline
/// is no longer tied to a single source table's shape.
/// Returns "" on success (ddlDefs/colList by ref) or an error message.
ClassMethod GetSelectColumns(sql As %String, Output ddlDefs As %String, Output colList As %String) As %String
{
    Set ddlDefs = ""
    Set colList = ""
    Try {
        If '..IsSelectOnly(sql) {
            Return "ERROR: transform must be a single SELECT statement"
        }
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR preparing transform SELECT: " _ $System.Status.GetErrorText(sc)
        }
        Set md = stmt.%Metadata
        If '$IsObject(md) || (md.columns.Count() = 0) {
            Return "ERROR: transform SELECT produced no columns"
        }
        Kill seen
        For i = 1:1:md.columns.Count() {
            Set col = md.columns.GetAt(i)
            Set name = col.colName
            // Result columns can be unnamed (Expression_N) or duplicated; make safe idents
            If (name = "") || ('..ValidIdent(name)) {
                Set name = "col" _ i
            }
            // "SELECT a.*, b.*" across joined tables repeats names (customer_id
            // in both): suffix duplicates so the target DDL stays valid
            Set key = $ZConvert(name, "U")
            If $Data(seen(key)) {
                Set seen(key) = seen(key) + 1
                Set name = name _ "_" _ seen(key)
            } Else {
                Set seen(key) = 1
            }
            Set type = ..ODBCToDDL(col.ODBCType, col.precision, col.scale)
            Set ddlDefs = ddlDefs _ $Select(ddlDefs = "": "", 1: ", ") _ name _ " " _ type
            Set colList = colList _ $Select(colList = "": "", 1: ", ") _ name
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Map an ODBC SQL type code (+ precision/scale) to an IRIS DDL type.
/// Types are deliberately GENEROUS: transform outputs are often expression
/// columns (UPPER, COALESCE, SUM, CASE) whose JDBC-reported precision/scale is
/// unreliable (e.g. a computed VARCHAR reports precision 1). Over-sizing the
/// target column is harmless in IRIS; under-sizing silently truncates data.
ClassMethod ODBCToDDL(odbc As %Integer, precision As %Integer, scale As %Integer) As %String [ Internal ]
{
    // integer family
    If $ListFind($ListBuild(-5, 4, 5, -6), odbc) > 0 {
        Return "BIGINT"
    }
    // decimal / numeric -> fixed generous precision so aggregate decimals survive
    //
    // Scale is CAPPED at 6, not merely defaulted to it. Precision is fixed at
    // 19, so every decimal place costs an integer digit: an expression whose
    // reported scale is 17 - which is what IRIS reports for a division or an
    // AVG() - would yield NUMERIC(19,17), leaving two integer digits. A value
    // of 33333.38866666666667 then fails the staging insert with SQLCODE -104,
    // at deploy time rather than at preview (preview reads columns and never
    // builds the staging table). Capping trades rounding beyond 6 decimals for
    // a column that accepts the magnitudes an ETL actually produces.
    // Two bounds meet at one value. Scale must be at least 6, or an expression
    // that under-reports its scale (a computed column reporting 0 while
    // producing 1.5) rounds on the way in. It must be at most 6, or the integer
    // half of the column is too small for the magnitudes above. Precision is
    // fixed, so 6 is the only scale that satisfies both - hence a constant
    // rather than a clamp.
    If (odbc = 2) || (odbc = 3) {
        Return "NUMERIC(19,6)"
    }
    // float / real / double
    If $ListFind($ListBuild(6, 7, 8), odbc) > 0 {
        Return "DOUBLE"
    }
    // date / time / timestamp (ODBC 9/91, 10/92, 11/93)
    If (odbc = 91) || (odbc = 9) {
        Return "DATE"
    }
    If (odbc = 92) || (odbc = 10) {
        Return "TIME"
    }
    If (odbc = 93) || (odbc = 11) {
        Return "TIMESTAMP"
    }
    // character/other -> generous VARCHAR (reported precision is unreliable for
    // expressions, so never go below 4000 to avoid truncation)
    Set len = +precision
    If (len < 4000) {
        Set len = 4000
    }
    If (len > 32000) {
        Set len = 32000
    }
    Return "VARCHAR(" _ len _ ")"
}

/// Record a DAG node + node.created event (shared by DDL tools).
ClassMethod CatalogNode(runId As %String, kind As %String, name As %String, sqlText As %String = "", configJson As %String = "") As %String
{
    Set cat = ##class(DataIntegrator.Tools.Catalog).%New()
    Return cat.CatalogRecord(runId, kind, name, sqlText, configJson)
}

}
