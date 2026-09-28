/// Data-quality check tools (spec §10.2) — P2 scope: run checks and report;
/// quarantine table generation lands in P4. Read-only, no gate.
/// Table arguments accept the layer-qualified names the wizard uses
/// (e.g. ETLW_TARGET.customer, ETLWIZARD.ext_customer).
Class ETLWizard.Tools.DataQuality Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Count NULL / empty values in one column of a table.
Method NullCheck(runId As %String, tableName As %String, columnName As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidQualified(tableName) {
            Return "ERROR: invalid table name"
        }
        If '##class(ETLWizard.Tools.Util).ValidIdent(columnName) {
            Return "ERROR: invalid column name"
        }
        Set result = ##class(ETLWizard.Tools.Util).RunSelect(
            "SELECT COUNT(*) AS total_rows, SUM(CASE WHEN " _ columnName _ " IS NULL THEN 1 ELSE 0 END) AS null_rows FROM " _ tableName, 1)
        Do ..EmitCheck(runId, "null_check", tableName _ "." _ columnName, result)
        Return result
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Count duplicate values of a column (or comma-separated column list).
Method UniqueCheck(runId As %String, tableName As %String, columns As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidQualified(tableName) {
            Return "ERROR: invalid table name"
        }
        For i = 1:1:$Length(columns, ",") {
            If '##class(ETLWizard.Tools.Util).ValidIdent($ZStrip($Piece(columns, ",", i), "<>W")) {
                Return "ERROR: invalid column list"
            }
        }
        Set result = ##class(ETLWizard.Tools.Util).RunSelect(
            "SELECT COUNT(*) AS duplicate_groups FROM (SELECT " _ columns _ " FROM " _ tableName _
            " GROUP BY " _ columns _ " HAVING COUNT(*) > 1)", 1)
        Do ..EmitCheck(runId, "unique_check", tableName _ "(" _ columns _ ")", result)
        Return result
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Source vs target row-count reconciliation (spec §23.6).
Method ReconcileCounts(runId As %String, sourceTable As %String, targetTable As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidQualified(sourceTable) {
            Return "ERROR: invalid source table"
        }
        If '##class(ETLWizard.Tools.Util).ValidQualified(targetTable) {
            Return "ERROR: invalid target table"
        }
        Set src = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ sourceTable)
        If $Extract(src, 1, 5) = "ERROR" {
            Return src
        }
        Set tgt = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ targetTable)
        If $Extract(tgt, 1, 5) = "ERROR" {
            Return tgt
        }
        Set result = {"source": (sourceTable), "sourceCount": (+src),
                      "target": (targetTable), "targetCount": (+tgt),
                      "match": (+src = +tgt)}.%ToJSON()
        Do ..EmitCheck(runId, "reconcile_counts", sourceTable _ " vs " _ targetTable, result)
        Return result
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// check.result event so the canvas shows quality outcomes (spec §14.2).
ClassMethod EmitCheck(runId As %String, checkType As %String, subject As %String, resultJson As %String) [ Internal, Private ]
{
    Try {
        Set payload = {}
        Set payload.check = checkType
        Set payload.subject = subject
        Try {
            Set payload.result = ##class(%DynamicObject).%FromJSON(resultJson)
        } Catch {
            Set payload.result = resultJson
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "check.result", "", payload)
    } Catch {
    }
}

}
