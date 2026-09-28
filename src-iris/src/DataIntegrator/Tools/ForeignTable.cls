/// Foreign Server / Foreign Table DDL tools (spec §10.2). Every tool in this
/// class is destructive DDL and is gated by ETLWizard.Policy.Auth via the
/// requires_auth requirement on the ToolSet <Include> — execution suspends
/// until a human approves it on the canvas (spec §10.3, §16.2).
/// All objects live in the ETLWIZARD SQL schema (spec §6.2).
Class ETLWizard.Tools.ForeignTable Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Create a foreign server. wrapper must be JDBC (connectionOrDirectory =
/// the SQL Gateway connection name) or CSV (connectionOrDirectory = the
/// directory that holds the files). Records the node and the exact DDL.
Method CreateForeignServer(runId As %String, serverName As %String, wrapper As %String, connectionOrDirectory As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(serverName) {
            Return "ERROR: invalid server name (letters, digits, underscores only)"
        }
        Set wrapper = $ZConvert(wrapper, "U")
        If wrapper = "JDBC" {
            If '##class(ETLWizard.Tools.Util).ValidIdent(connectionOrDirectory) {
                Return "ERROR: invalid gateway connection name"
            }
            Set ddl = "CREATE FOREIGN SERVER ETLWIZARD." _ serverName _
                      " FOREIGN DATA WRAPPER JDBC CONNECTION '" _ connectionOrDirectory _ "'"
        } ElseIf wrapper = "CSV" {
            If (connectionOrDirectory [ "'") || (connectionOrDirectory [ ";") {
                Return "ERROR: invalid directory path"
            }
            Set ddl = "CREATE FOREIGN SERVER ETLWIZARD." _ serverName _
                      " FOREIGN DATA WRAPPER CSV HOST '" _ connectionOrDirectory _ "'"
        } Else {
            Return "ERROR: wrapper must be JDBC or CSV"
        }
        // A foreign server is shared, not per-pipeline: the dropzone server is the
        // same object for every CSV pipeline, so the second one would die on
        // "SQLCODE -201 ... already exists". Reuse it when it points at the same
        // place, and say so plainly when it does not.
        Set existing = ..ForeignServerTarget(serverName, .exWrapper)
        If existing '= "" {
            If ($ZConvert(existing, "U") = $ZConvert(connectionOrDirectory, "U")) && (exWrapper = wrapper) {
                Do ##class(ETLWizard.Tools.Util).CatalogNode(runId, "foreign_server",
                    "ETLWIZARD." _ serverName, ddl, {"wrapper": (wrapper), "target": (connectionOrDirectory), "reused": 1}.%ToJSON())
                Return "Reusing foreign server ETLWIZARD." _ serverName _ " (" _ wrapper _ ", already points at " _ existing _ ")"
            }
            Return "ERROR: foreign server ETLWIZARD." _ serverName _ " already exists but points at " _
                existing _ " (" _ exWrapper _ "), not " _ connectionOrDirectory _ " (" _ wrapper _
                "). Choose a different server name."
        }
        Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
        If err '= "" {
            Return err
        }
        Do ##class(ETLWizard.Tools.Util).CatalogNode(runId, "foreign_server",
            "ETLWIZARD." _ serverName, ddl, {"wrapper": (wrapper), "target": (connectionOrDirectory)}.%ToJSON())
        Return "Created foreign server ETLWIZARD." _ serverName _ " (" _ wrapper _ ")"
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Clear the way for a foreign table called ETLWIZARD.<localName>.
/// Re-mounting the same file or table is routine — the wizard is re-run, or the
/// source has changed shape — but CREATE FOREIGN TABLE fails with "SQLCODE -201
/// ... already exists". Drop a previous FOREIGN table of that name so the mount
/// re-imports cleanly; refuse when the name belongs to something else (a real
/// table, or an ODBC-linked view) rather than destroying it silently.
/// Returns "" when the name is free, or an error message.
ClassMethod ClearForeignTableName(localName As %String) As %String [ Internal ]
{
    Try {
        Set isForeign = 0
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.FOREIGN_TABLES " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND UPPER(TABLE_NAME) = ?", $ZConvert(localName, "U"))
        If rs.%Next() {
            Set isForeign = +rs.%GetData(1)
        }
        If isForeign {
            Return ##class(ETLWizard.Tools.Util).RunDDL("DROP FOREIGN TABLE ETLWIZARD." _ localName)
        }
        Set rs2 = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND UPPER(TABLE_NAME) = ?", $ZConvert(localName, "U"))
        If rs2.%Next() {
            Return "ERROR: ETLWIZARD." _ localName _ " already exists as a " _
                $ZConvert(rs2.%GetData(1), "L") _ " and is not a foreign table. Mount it under another name."
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// What an existing foreign server points at ("" when there is no such server),
/// with .wrapper set to JDBC or CSV. INFORMATION_SCHEMA.FOREIGN_SERVERS reports
/// it as a parameter string: CONNECTION="name" for JDBC, HOST="/dir" for CSV.
ClassMethod ForeignServerTarget(serverName As %String, Output wrapper As %String) As %String [ Internal ]
{
    Set wrapper = ""
    Try {
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT FOREIGN_DATA_WRAPPER, PARAMETERS FROM INFORMATION_SCHEMA.FOREIGN_SERVERS " _
            "WHERE SERVER_SCHEMA = 'ETLWIZARD' AND UPPER(SERVER_NAME) = ?", $ZConvert(serverName, "U"))
        If 'rs.%Next() {
            Return ""
        }
        Set wrapper = $Select(rs.%GetData(1) [ "Csv": "CSV", 1: "JDBC")
        Set params = rs.%GetData(2)
        Set key = $Select(wrapper = "CSV": "HOST=""", 1: "CONNECTION=""")
        If params '[ key {
            Return ""
        }
        Return $Piece($Piece(params, key, 2), """", 1)
    } Catch {
        Return ""
    }
}

/// Mount a remote table over an ODBC SQL Gateway connection as an IRIS LINKED
/// table, then expose it as a view ETLWIZARD.<localName> so the rest of the
/// wizard treats it exactly like a foreign table. ODBC is used because some
/// drivers (e.g. psqlODBC under IRIS's iODBC) cannot service the foreign-table
/// block-fetch, but the linked-table row cursor works. A primary key is REQUIRED
/// (ODBC catalogs often do not report one, so the caller supplies it).
Method CreateLinkedTableOdbc(runId As %String, localName As %String, connection As %String, schemaName As %String, tableName As %String, primaryKeys As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(localName) {
            Return "ERROR: invalid local table name"
        }
        If $ZStrip(primaryKeys, "<>W") = "" {
            Return "ERROR: a primary key column is required for a linked table (ODBC cannot auto-detect it)"
        }
        If (connection [ "'") || (schemaName [ "'") || (tableName [ "'") {
            Return "ERROR: invalid connection/schema/table"
        }
        // class names cannot contain '_' (it is the package separator), so strip it
        // for the class; the SQL table/view keep the underscore.
        Set cls = "ETLWizard.Link." _ $Translate(localName, "_", "")
        Set link = "lk_" _ localName
        // drop any prior class + view so a redeploy is clean
        Do ##class(%SYSTEM.OBJ).Delete(cls, "-d")
        Do ##class(ETLWizard.Tools.Util).RunDDL("DROP VIEW ETLWIZARD." _ localName)
        // CreateLinkedTable compiles the generated class and writes progress to the
        // current device; redirect it to a temp file so it never pollutes the HTTP
        // response (which must be pure JSON).
        Set io = $IO
        Open "/tmp/lt_compile":("WNS"):1
        Use "/tmp/lt_compile"
        Set sc = ##class(%SYSTEM.SQL.Schema).CreateLinkedTable(connection, schemaName, tableName, primaryKeys, cls, link)
        Use io
        Close "/tmp/lt_compile"
        If $$$ISERR(sc) {
            Return "ERROR creating linked table: " _ $System.Status.GetErrorText(sc)
        }
        Set err = ##class(ETLWizard.Tools.Util).RunDDL(
            "CREATE VIEW ETLWIZARD." _ localName _ " AS SELECT * FROM ETLWizard_Link." _ link)
        If err '= "" {
            Return err
        }
        Do ##class(ETLWizard.Tools.Util).CatalogNode(runId, "foreign_table",
            "ETLWIZARD." _ localName, "linked via ODBC " _ connection,
            {"connection": (connection), "schema": (schemaName), "table": (tableName),
             "primaryKeys": (primaryKeys), "kind": "linked"}.%ToJSON())
        Set cols = ##class(ETLWizard.Tools.Util).RunSelect(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = '" _ localName _ "' ORDER BY ORDINAL_POSITION", 100)
        Return "Linked ODBC table ETLWIZARD." _ localName _ " (PK " _ primaryKeys _ "). Columns: " _ cols
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Mount a remote JDBC table as a foreign table with automatic schema import
/// (spec §4.2). remoteTable is 'schema.table' on the source. Returns the
/// imported column metadata.
Method CreateForeignTableJdbc(runId As %String, localName As %String, serverName As %String, remoteTable As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(localName) {
            Return "ERROR: invalid local table name"
        }
        If '##class(ETLWizard.Tools.Util).ValidIdent(serverName) {
            Return "ERROR: invalid server name"
        }
        If '##class(ETLWizard.Tools.Util).ValidQualified(remoteTable) {
            Return "ERROR: invalid remote table (use schema.table)"
        }
        Set clear = ..ClearForeignTableName(localName)
        If clear '= "" {
            Return clear
        }
        Set ddl = "CREATE FOREIGN TABLE ETLWIZARD." _ localName _
                  " SERVER ETLWIZARD." _ serverName _ " TABLE '" _ remoteTable _ "'"
        Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
        If err '= "" {
            Return err
        }
        Do ##class(ETLWizard.Tools.Util).CatalogNode(runId, "foreign_table",
            "ETLWIZARD." _ localName, ddl, {"server": (serverName), "remoteTable": (remoteTable)}.%ToJSON())
        // Report the columns IRIS imported automatically
        Set cols = ##class(ETLWizard.Tools.Util).RunSelect(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = '" _ localName _ "' " _
            "ORDER BY ORDINAL_POSITION", 100)
        Return "Created foreign table ETLWIZARD." _ localName _ ". Imported columns: " _ cols
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Mount a CSV file as a foreign table. columnDefs is an explicit column
/// list like "SaleId INTEGER, SaleDate DATE, Amount NUMERIC(12,2)".
/// hasHeader = 1 when the first line holds column names.
Method CreateForeignTableCsv(runId As %String, localName As %String, serverName As %String, fileName As %String, columnDefs As %String, hasHeader As %Boolean = 1) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(localName) {
            Return "ERROR: invalid local table name"
        }
        If '##class(ETLWizard.Tools.Util).ValidIdent(serverName) {
            Return "ERROR: invalid server name"
        }
        If (fileName [ "/") || (fileName [ "\") || (fileName [ "'") {
            Return "ERROR: fileName must be a bare file name inside the server directory"
        }
        If '##class(ETLWizard.Tools.Util).ValidColumnDefs(columnDefs) {
            Return "ERROR: invalid column definition list"
        }
        Set clear = ..ClearForeignTableName(localName)
        If clear '= "" {
            Return clear
        }
        Set using = $Select(hasHeader: " USING {""from"":{""file"":{""header"":1}}}", 1: "")
        Set ddl = "CREATE FOREIGN TABLE ETLWIZARD." _ localName _ " (" _ columnDefs _ ")" _
                  " SERVER ETLWIZARD." _ serverName _ " FILE '" _ fileName _ "'" _ using
        Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
        If err '= "" {
            Return err
        }
        Do ##class(ETLWizard.Tools.Util).CatalogNode(runId, "foreign_table",
            "ETLWIZARD." _ localName, ddl, {"server": (serverName), "file": (fileName)}.%ToJSON())
        Return "Created CSV foreign table ETLWIZARD." _ localName _ " over " _ fileName
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Drop a previously created foreign object. objectType is SERVER or TABLE.
Method DropForeignObject(runId As %String, objectType As %String, name As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
            Return "ERROR: invalid object name"
        }
        Set objectType = $ZConvert(objectType, "U")
        If objectType = "TABLE" {
            Set ddl = "DROP FOREIGN TABLE ETLWIZARD." _ name
        } ElseIf objectType = "SERVER" {
            Set ddl = "DROP FOREIGN SERVER ETLWIZARD." _ name
        } Else {
            Return "ERROR: objectType must be SERVER or TABLE"
        }
        Set err = ##class(ETLWizard.Tools.Util).RunDDL(ddl)
        If err '= "" {
            Return err
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "",
            {"name": ("ETLWIZARD." _ name), "status": "dropped", "ddl": (ddl)})
        Return "Dropped foreign " _ $ZConvert(objectType, "L") _ " ETLWIZARD." _ name
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

}
