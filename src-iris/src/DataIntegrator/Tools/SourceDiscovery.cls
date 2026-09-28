/// Read-only source discovery and profiling tools (spec §10.2). All remote
/// reads go through THROUGH passthrough queries (SELECT-only, bounded) so
/// nothing is mounted or moved before the user approves it.
Class ETLWizard.Tools.SourceDiscovery Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// List the pre-defined SQL Gateway JDBC connections available for
/// CREATE FOREIGN SERVER ... CONNECTION '<name>'.
Method ListGatewayConnections() As %String
{
    Return ##class(ETLWizard.Tools.Util).RunSelect(
        "SELECT Connection_Name AS Name, URL, driver FROM %Library.sys_SQLConnection WHERE isJDBC = 1", 50)
}

/// Connectivity smoke test for an existing foreign server: runs
/// THROUGH <server> SELECT 1 and reports success or the connection error.
Method TestConnection(serverName As %String) As %String
{
    Set result = ##class(ETLWizard.Tools.Util).Through(serverName, "SELECT 1", 1)
    If $Extract(result, 1, 5) = "ERROR" {
        Return result
    }
    Return "Connection OK through foreign server ETLWIZARD." _ serverName
}

/// List schemas and tables on the remote source (via information_schema).
Method DiscoverSchema(serverName As %String) As %String
{
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT table_schema, table_name FROM information_schema.tables " _
        "WHERE table_type = 'BASE TABLE' " _
        "AND table_schema NOT IN ('pg_catalog', 'information_schema') " _
        "ORDER BY table_schema, table_name", 100)
}

/// List columns, data types and nullability of one remote table.
Method DiscoverColumns(serverName As %String, schemaName As %String, tableName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT column_name, data_type, is_nullable, column_default " _
        "FROM information_schema.columns " _
        "WHERE table_schema = '" _ schemaName _ "' AND table_name = '" _ tableName _ "' " _
        "ORDER BY ordinal_position", 100)
}

/// List the primary-key columns of one remote table.
Method DiscoverPrimaryKey(serverName As %String, schemaName As %String, tableName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT kcu.column_name " _
        "FROM information_schema.table_constraints tc " _
        "JOIN information_schema.key_column_usage kcu " _
        "  ON tc.constraint_name = kcu.constraint_name " _
        " AND tc.table_schema = kcu.table_schema " _
        "WHERE tc.constraint_type = 'PRIMARY KEY' " _
        "  AND tc.table_schema = '" _ schemaName _ "' AND tc.table_name = '" _ tableName _ "' " _
        "ORDER BY kcu.ordinal_position", 20)
}

/// Find candidate watermark columns (timestamp/date or increasing numeric id)
/// for incremental loading, with their current MIN/MAX values.
Method DetectWatermarks(serverName As %String, schemaName As %String, tableName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    Set colsJson = ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT column_name, data_type FROM information_schema.columns " _
        "WHERE table_schema = '" _ schemaName _ "' AND table_name = '" _ tableName _ "' " _
        "AND (data_type LIKE 'timestamp%' OR data_type IN ('date', 'integer', 'bigint', 'numeric'))", 50)
    If $Extract(colsJson, 1, 5) = "ERROR" {
        Return colsJson
    }
    Try {
        Set cols = ##class(%DynamicObject).%FromJSON(colsJson)
        Set candidates = []
        Set iter = cols.rows.%GetIterator()
        While iter.%GetNext(.i, .col) {
            Set colName = col."column_name"
            If '##class(ETLWizard.Tools.Util).ValidIdent(colName) {
                Continue
            }
            Set mm = ##class(ETLWizard.Tools.Util).Through(serverName,
                "SELECT MIN(" _ colName _ ") AS min_value, MAX(" _ colName _ ") AS max_value, " _
                "COUNT(*) AS total_rows, COUNT(" _ colName _ ") AS non_null_rows " _
                "FROM " _ schemaName _ "." _ tableName, 1)
            Set cand = {}
            Set cand.column = colName
            Set cand.dataType = col."data_type"
            Try {
                Set mmObj = ##class(%DynamicObject).%FromJSON(mm)
                Set cand.stats = mmObj.rows.%Get(0)
            } Catch {
                Set cand.stats = mm
            }
            Set cand.hint = $Select(
                $Extract(col."data_type", 1, 9) = "timestamp": "Incremental Timestamp Load candidate; verify bulk backfills also set it",
                col."data_type" = "date": "Coarse timestamp candidate (day resolution)",
                1: "Incremental Numeric Watermark candidate if strictly increasing")
            Do candidates.%Push(cand)
        }
        Return {"candidates": (candidates)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Row-count estimate for a remote table.
Method EstimateRows(serverName As %String, schemaName As %String, tableName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT COUNT(*) AS row_count FROM " _ schemaName _ "." _ tableName, 1)
}

/// Bounded sample of remote rows (maxRows capped at 20 — spec §27.4).
Method SampleRows(serverName As %String, schemaName As %String, tableName As %String, maxRows As %Integer = 10) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    If maxRows > 20 {
        Set maxRows = 20
    }
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT * FROM " _ schemaName _ "." _ tableName _ " LIMIT " _ (maxRows + 0), maxRows)
}

/// Null/distinct/min/max profile of one remote column.
Method ProfileColumn(serverName As %String, schemaName As %String, tableName As %String, columnName As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(schemaName) {
        Return "ERROR: invalid schema name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(columnName) {
        Return "ERROR: invalid column name"
    }
    Return ##class(ETLWizard.Tools.Util).Through(serverName,
        "SELECT COUNT(*) AS total_rows, COUNT(" _ columnName _ ") AS non_null_rows, " _
        "COUNT(DISTINCT " _ columnName _ ") AS distinct_values, " _
        "MIN(" _ columnName _ ") AS min_value, MAX(" _ columnName _ ") AS max_value " _
        "FROM " _ schemaName _ "." _ tableName, 1)
}

/// Open an ODBC SQL Gateway connection by its registered name. ODBC sources
/// have no foreign server to run THROUGH, so discovery goes straight at the
/// driver's catalog (SQLTables / SQLColumns / SQLPrimaryKeys) using the DSN and
/// credentials already stored in the SQL Gateway registry.
/// Returns the connected object, or "" (with .err set) on failure.
ClassMethod OdbcConnect(connection As %String, Output err As %String) As %ObjectHandle [ Internal ]
{
    Set err = ""
    If '##class(ETLWizard.Tools.Util).ValidIdent(connection) {
        Set err = "ERROR: invalid connection name"
        Return ""
    }
    Set def = ##class(%Library.SQLConnection).NameIndexOpen(connection)
    If '$IsObject(def) {
        Set err = "ERROR: no SQL Gateway connection named '" _ connection _ "'"
        Return ""
    }
    If def.isJDBC {
        Set err = "ERROR: '" _ connection _ "' is a JDBC connection, not ODBC"
        Return ""
    }
    Set conn = ##class(%Library.SQLGatewayConnection).%New()
    Set sc = conn.Connect(def.DSN, def.Usr, def.pwd, 0)
    If $$$ISERR(sc) {
        Set err = "ERROR connecting to DSN '" _ def.DSN _ "': " _ $System.Status.GetErrorText(sc)
        Return ""
    }
    Return conn
}

/// Drain an ODBC catalog result set into a list of %List rows. The gateway
/// hands back one $LIST per row; FetchRows is batched, so keep asking until a
/// short batch comes back (or the row cap is hit).
ClassMethod OdbcFetchAll(conn As %ObjectHandle, hstmt As %String, maxRows As %Integer = 500) As %List [ Internal ]
{
    Set all = ""
    Set batch = 50
    For {
        Set sc = conn.FetchRows(hstmt, .rows, batch)
        If $$$ISERR(sc) {
            Quit
        }
        Set got = $ListLength($Get(rows))
        For i = 1:1:got {
            Set all = all _ $ListBuild($List(rows, i))
        }
        If (got < batch) || ($ListLength(all) >= maxRows) {
            Quit
        }
    }
    Return all
}

/// List the schemas visible over an ODBC SQL Gateway connection, with how many
/// tables each holds — the ODBC equivalent of DiscoverSchema's first level.
/// SQLTables columns: 1 TABLE_CAT, 2 TABLE_SCHEM, 3 TABLE_NAME, 4 TABLE_TYPE.
Method DiscoverOdbcSchemas(connection As %String) As %String
{
    Try {
        Set conn = ..OdbcConnect(connection, .err)
        If err '= "" {
            Return err
        }
        Set sc = conn.AllocateStatement(.h)
        If $$$ISERR(sc) {
            Do conn.Disconnect()
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set sc = conn.Tables(h, "", "", "", "TABLE,VIEW")
        If $$$ISERR(sc) {
            Do conn.DropStatement(h)
            Do conn.Disconnect()
            Return "ERROR listing tables: " _ $System.Status.GetErrorText(sc)
        }
        Set rows = ..OdbcFetchAll(conn, h, 2000)
        Do conn.DropStatement(h)
        Do conn.Disconnect()
        Set counts = ""
        For i = 1:1:$ListLength(rows) {
            Set row = $List(rows, i)
            Set schema = $ListGet(row, 2)
            If schema = "" {
                Set schema = $ListGet(row, 1)
            }
            If schema = "" {
                Continue
            }
            Set counts(schema) = $Get(counts(schema)) + 1
        }
        Set out = []
        Set schema = ""
        For {
            Set schema = $Order(counts(schema))
            Quit:schema=""
            Do out.%Push({"schema": (schema), "tables": (counts(schema))})
        }
        Return {"schemas": (out), "connection": (connection)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// List the tables in one ODBC schema, each with the primary key the driver
/// reports. The PK matters here because a linked table cannot be created
/// without one — the wizard pre-fills it and flags the tables that have none.
Method DiscoverOdbcTables(connection As %String, schemaName As %String = "", maxTables As %Integer = 200) As %String
{
    Try {
        If (schemaName '= "") && ('##class(ETLWizard.Tools.Util).ValidIdent(schemaName)) {
            Return "ERROR: invalid schema name"
        }
        Set conn = ..OdbcConnect(connection, .err)
        If err '= "" {
            Return err
        }
        Set sc = conn.AllocateStatement(.h)
        If $$$ISERR(sc) {
            Do conn.Disconnect()
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set sc = conn.Tables(h, "", schemaName, "", "TABLE,VIEW")
        If $$$ISERR(sc) {
            Do conn.DropStatement(h)
            Do conn.Disconnect()
            Return "ERROR listing tables: " _ $System.Status.GetErrorText(sc)
        }
        Set rows = ..OdbcFetchAll(conn, h, maxTables)
        Do conn.DropStatement(h)
        Set out = []
        For i = 1:1:$ListLength(rows) {
            Set row = $List(rows, i)
            Set schema = $ListGet(row, 2), table = $ListGet(row, 3), type = $ListGet(row, 4)
            If table = "" {
                Continue
            }
            If (schemaName '= "") && (schema '= schemaName) {
                Continue
            }
            Set pk = ..OdbcPrimaryKeyList(conn, schema, table)
            Do out.%Push({"table_schema": (schema), "table_name": (table),
                          "table_type": (type), "primary_key": (pk)})
        }
        Do conn.Disconnect()
        Return {"rows": (out), "rowCount": (out.%Size()), "schema": (schemaName)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Comma-separated primary-key columns for one table on an open ODBC
/// connection, "" when the driver reports none.
/// SQLPrimaryKeys columns: 4 COLUMN_NAME, 5 KEY_SEQ.
ClassMethod OdbcPrimaryKeyList(conn As %ObjectHandle, schemaName As %String, tableName As %String) As %String [ Internal ]
{
    Try {
        Set sc = conn.AllocateStatement(.h)
        If $$$ISERR(sc) {
            Return ""
        }
        Set sc = conn.PrimaryKeys(h, "", schemaName, tableName)
        If $$$ISERR(sc) {
            Do conn.DropStatement(h)
            Return ""
        }
        Set rows = ..OdbcFetchAll(conn, h, 20)
        Do conn.DropStatement(h)
        Set cols = ""
        For i = 1:1:$ListLength(rows) {
            Set col = $ListGet($List(rows, i), 4)
            If col '= "" {
                Set cols = cols _ $Select(cols = "": "", 1: ",") _ col
            }
        }
        Return cols
    } Catch {
        Return ""
    }
}

/// Columns of one ODBC table (name + driver type), for profiling a linked
/// table before it is mounted.
/// SQLColumns columns: 4 COLUMN_NAME, 6 TYPE_NAME.
Method DiscoverOdbcColumns(connection As %String, schemaName As %String, tableName As %String) As %String
{
    Try {
        Set conn = ..OdbcConnect(connection, .err)
        If err '= "" {
            Return err
        }
        Set sc = conn.AllocateStatement(.h)
        If $$$ISERR(sc) {
            Do conn.Disconnect()
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set sc = conn.Columns(h, "", schemaName, tableName, "")
        If $$$ISERR(sc) {
            Do conn.DropStatement(h)
            Do conn.Disconnect()
            Return "ERROR listing columns: " _ $System.Status.GetErrorText(sc)
        }
        Set rows = ..OdbcFetchAll(conn, h, 300)
        Do conn.DropStatement(h)
        Set pk = ..OdbcPrimaryKeyList(conn, schemaName, tableName)
        Do conn.Disconnect()
        Set out = []
        For i = 1:1:$ListLength(rows) {
            Set row = $List(rows, i)
            Do out.%Push({"column_name": ($ListGet(row, 4)), "data_type": ($ListGet(row, 6))})
        }
        Return {"rows": (out), "primary_key": (pk)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Bounded SELECT against a mounted foreign table (ETLWIZARD schema) to
/// verify it works after creation.
Method TestForeignTable(tableName As %String, maxRows As %Integer = 5) As %String
{
    If '##class(ETLWizard.Tools.Util).ValidIdent(tableName) {
        Return "ERROR: invalid table name"
    }
    If maxRows > 20 {
        Set maxRows = 20
    }
    // ODBC-linked sources are exposed as a VIEW over a linked table, and TOP on
    // that view comes back empty (the row limit is pushed at a source that has
    // no TOP). RunSelect stops reading at maxRows anyway, so drop TOP for views.
    Set isView = 0
    Set chk = ##class(%SQL.Statement).%ExecDirect(,
        "SELECT TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ?",
        tableName)
    If chk.%Next() {
        Set isView = ($ZConvert(chk.%GetData(1), "U") = "VIEW")
    }
    If isView {
        Return ##class(ETLWizard.Tools.Util).RunSelect(
            "SELECT * FROM ETLWIZARD." _ tableName, maxRows)
    }
    Return ##class(ETLWizard.Tools.Util).RunSelect(
        "SELECT TOP " _ (maxRows + 0) _ " * FROM ETLWIZARD." _ tableName, maxRows)
}

}
