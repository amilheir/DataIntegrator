/// Transformation tools (spec §10.2) — P2 scope: read-only mapping proposals
/// and SQL previews. create_view / create_staging_table DDL execution lives
/// in Tools.Load (gated). Nothing here mutates state.
Class ETLWizard.Tools.Transformation Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Propose source->target field mappings for a mounted foreign table:
/// identity mappings plus conversion hints (collation, timestamps). The
/// user edits these in the mapping grid (spec §11 step 8).
Method ProposeMappings(foreignTable As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(foreignTable) {
            Return "ERROR: invalid foreignTable"
        }
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
            "WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute(foreignTable)
        Set mappings = []
        While rs.%Next() {
            Set colName = rs.%GetData(1)
            Set dtype = $ZConvert(rs.%GetData(2), "L")
            Set m = {}
            Set m.source = colName
            Set m.target = colName
            Set m.conversion = ""
            Set m.comment = $Case(dtype,
                "varchar": "Foreign tables default to EXACT collation - use %SQLUPPER() in joins/filters against local SQLUPPER data (spec 6.3)",
                "timestamp": "Candidate watermark / incremental predicate column",
                : "")
            Do mappings.%Push(m)
        }
        If mappings.%Size() = 0 {
            Return "ERROR: foreign table ETLWIZARD." _ foreignTable _ " not found"
        }
        Return {"foreignTable": (foreignTable), "mappings": (mappings)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Bounded preview of any SELECT (mapping/transform candidate). Never
/// executes DDL/DML (spec §16.3).
Method PreviewQuery(sql As %String, maxRows As %Integer = 10) As %String
{
    If '##class(ETLWizard.Tools.Util).IsSelectOnly(sql) {
        Return "ERROR: preview accepts a single SELECT statement only"
    }
    If maxRows > 20 {
        Set maxRows = 20
    }
    Return ##class(ETLWizard.Tools.Util).RunSelect(sql, maxRows)
}

/// Query plan for a SELECT — verifies what is pushed down to the remote
/// server before committing to an ELT shape (spec §6.3).
Method ExplainQuery(sql As %String) As %String
{
    If '##class(ETLWizard.Tools.Util).IsSelectOnly(sql) {
        Return "ERROR: explain accepts a single SELECT statement only"
    }
    Return ##class(ETLWizard.Tools.Util).RunSelect("EXPLAIN " _ sql, 100)
}

}
