/// File bulk-load source (spec add-on): load a CSV — or an auto-converted .xlsx —
/// straight into a target table with IRIS LOAD DATA / LOAD BULK DATA, bypassing
/// the foreign-table + transform path. Files live in the dropzone on the IRIS
/// server filesystem (LOAD [BULK] DATA reads server-side files by path).
Class DataIntegrator.Tools.BulkLoad Extends %RegisteredObject
{

/// Rows scanned to decide day-first vs month-first ordering (see DayFirst()).
Parameter DAYFIRSTROWS = 5000;

Parameter DROPZONE = "/opt/irisbuild/dropzone";

/// Bare column names from a "col TYPE, col TYPE" list (commas inside type parens
/// like NUMERIC(18,4) must not split).
ClassMethod ColNames(columnDefs As %String) As %String [ Internal ]
{
    Set cleaned = "", depth = 0
    For j = 1:1:$Length(columnDefs) {
        Set ch = $Extract(columnDefs, j)
        If ch = "(" { Set depth = depth + 1 }
        If ch = ")" { Set depth = depth - 1 }
        Set cleaned = cleaned _ $Select((ch = ",") && (depth > 0): $Char(1), 1: ch)
    }
    Set out = ""
    For i = 1:1:$Length(cleaned, ",") {
        Set nm = $Piece($ZStrip($Piece(cleaned, ",", i), "<>W"), " ", 1)
        If nm '= "" {
            Set out = out _ $Select(out = "": "", 1: ", ") _ nm
        }
    }
    Return out
}

/// Convert an .xlsx (active sheet) to a sibling .csv via openpyxl. Streaming
/// read_only so large books do not blow memory. Returns "" on success.
ClassMethod PyXlsxToCsv(src As %String, dst As %String) As %String [ Internal, Language = python ]
{
    import openpyxl, csv
    try:
        wb = openpyxl.load_workbook(src, read_only=True, data_only=True)
        ws = wb.active
        with open(dst, 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f, lineterminator='\n')
            for row in ws.iter_rows(values_only=True):
                w.writerow(['' if v is None else v for v in row])
        wb.close()
        return ''
    except Exception as e:
        return 'ERROR: ' + str(e)
}

/// Convert dropzone/<xlsx> to dropzone/<same>.csv. Returns the bare csv file
/// name, or an ERROR string.
ClassMethod XlsxToCsv(fileName As %String) As %String
{
    Try {
        If (fileName [ "/") || (fileName [ "\") || (fileName [ "..") {
            Return "ERROR: fileName must be a bare file name in the dropzone"
        }
        Set src = ..#DROPZONE _ "/" _ fileName
        If '##class(%File).Exists(src) {
            Return "ERROR: file not found: " _ fileName
        }
        Set csvName = $Piece(fileName, ".", 1, $Length(fileName, ".") - 1) _ ".csv"
        Set dst = ..#DROPZONE _ "/" _ csvName
        Set rc = ..PyXlsxToCsv(src, dst)
        If rc '= "" {
            Return rc
        }
        Return csvName
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Infer column DDL from a dropzone CSV (reuses the CSV profiler). Returns the
/// InferCsvTypes JSON: {columnDefs, columns, sampledRows}.
ClassMethod InferColumns(fileName As %String) As %String
{
    Set csv = ##class(DataIntegrator.Tools.CsvProfiling).%New()
    Return csv.InferCsvTypes(fileName)
}

/// The USING separator char: accept a literal char, or "\t" for TAB.
ClassMethod SepChar(separator As %String) As %String [ Internal ]
{
    If separator = "\t" { Return $Char(9) }
    If separator = "" { Return "," }
    Return $Extract(separator, 1)
}

/// Build the LOAD [BULK] DATA statement.
ClassMethod BuildLoadSql(target As %String, colList As %String, path As %String, bulk As %Boolean, header As %Boolean, separator As %String) As %String
{
    Set using = {"from": {"file": {"header": ($Select(header: 1, 1: 0)), "columnseparator": (..SepChar(separator))}}}
    Return "LOAD " _ $Select(bulk: "BULK ", 1: "") _ "DATA FROM FILE '" _ path _ "' INTO " _ target _
        " (" _ colList _ ") USING " _ using.%ToJSON()
}

/// Where an ingested file lands: DATAINTEGRATOR.ext_<name>, the same shape the
/// mounted sources use, so everything the Data Sources tab produces is findable
/// in one place. A name that already carries the prefix is not double-prefixed.
ClassMethod SourceTableName(baseName As %String) As %String
{
    Set bare = baseName
    If $ZConvert($Extract(bare, 1, 4), "L") = "ext_" {
        Set bare = $Extract(bare, 5, *)
    }
    Return "DATAINTEGRATOR.ext_" _ bare
}

/// Repair the two file shapes that this loader cannot read, writing a cleaned
/// sibling rather than touching the upload.
///
/// 1. EVERY LINE WRAPPED IN QUOTES. Some exports quote the whole row, so
///    "a, b, c" is - correctly, per RFC4180 - a single field containing commas.
///    A one-column CSV whose only column name contains the separator is never
///    what anyone meant, so it is unwrapped.
/// 2. HEADER NAMES THAT ARE NOT IDENTIFIERS ("Date/Time", "User ID"). The target
///    columns must be valid SQL names, and LOAD DATA matches the target's names
///    against the file's header - so the file needs the sanitised names too, or
///    the two cannot agree.
///
/// Returns "" and leaves `newName` empty when the file is already loadable.
ClassMethod NormalizeCsv(fileName As %String, separator As %String = ",", Output newName As %String, Output note As %String) As %String
{
    Set newName = "", note = ""
    Try {
        Set path = ..#DROPZONE _ "/" _ fileName
        If '##class(%File).Exists(path) {
            Return "ERROR: file not found in dropzone: " _ fileName
        }
        Set sep = ..SepChar(separator)
        Set in = ##class(%Stream.FileCharacter).%New()
        If $$$ISERR(in.LinkToFile(path)) {
            Return "ERROR: could not read " _ fileName
        }
        If in.AtEnd {
            Return "ERROR: " _ fileName _ " is empty"
        }
        Set header = $ZStrip(in.ReadLine(), ">", $Char(13))
        If $Extract(header, 1, 3) = $Char(239, 187, 191) {
            Set header = $Extract(header, 4, *)
        }
        // Release the file before the scans below. %Stream.FileCharacter holds
        // an exclusive handle: LinkToFile() on a path this process already has
        // open FAILS, and every scanner here answers a failed open with its
        // "nothing to do" value. So each of them silently reported nothing
        // while this stream was open - HasEmptyRows() has been doing that since
        // it was written, which is why a file of blank rows was never detected.
        // The scans reopen the file themselves; the rewrite below opens it again
        // once they are done.
        Set in = ""

        // Shape 1: the whole line is one quoted field that still contains the
        // separator.
        Set nFields = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(header, sep, .headFld)
        Set wrapped = 0
        If (nFields = 1) && ($Get(headFld(1)) [ sep) {
            Set wrapped = 1
            Set header = headFld(1)
            Set nFields = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(header, sep, .headFld)
        }

        // Shape 2: any header cell that is not already a usable identifier.
        Set renamed = 0, names = "", seen = ","
        For c = 1:1:nFields {
            Set original = $ZStrip($Get(headFld(c)), "<>W")
            Set safe = ##class(DataIntegrator.Tools.CsvProfiling).SafeColumnName(original, c)
            // duplicate names after sanitising would be ambiguous in the target
            If seen [ ("," _ $ZConvert(safe, "U") _ ",") {
                Set safe = safe _ "_" _ c
            }
            Set seen = seen _ $ZConvert(safe, "U") _ ","
            If safe '= original {
                Set renamed = renamed + 1
            }
            Set names = names _ $Select(names = "": "", 1: sep) _ safe
        }
        Set dayFirst = ..DayFirst(path, sep)
        Set tsFix = ..HasIsoTimestamp(path, sep, dayFirst)
        If 'wrapped && (renamed = 0) && 'tsFix && '..HasEmptyRows(path, sep) {
            Return ""
        }

        Set newName = $Piece(fileName, ".", 1, $Length(fileName, ".") - 1) _ "_clean.csv"
        // reopen for the rewrite pass and step over the header again
        Set in = ##class(%Stream.FileCharacter).%New()
        If $$$ISERR(in.LinkToFile(path)) {
            Set newName = ""
            Return "ERROR: could not read " _ fileName
        }
        Do in.ReadLine()
        Set out = ##class(%Stream.FileCharacter).%New()
        Set out.Filename = ..#DROPZONE _ "/" _ newName
        Do out.WriteLine(names)
        Set rows = 0, dropped = 0
        While 'in.AtEnd {
            Set line = $ZStrip(in.ReadLine(), ">", $Char(13))
            If $ZStrip(line, "<>W") = "" {
                Continue
            }
            If wrapped {
                Set n = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(line, sep, .f)
                // A wrapped row unwraps to exactly one field; anything else is a
                // row that was not wrapped, and is passed through untouched
                // rather than silently mangled.
                If (n = 1) && ($Get(f(1)) [ sep) {
                    Set line = f(1)
                }
            }
            // Re-emit from the PARSED fields rather than passing the line
            // through. Passing it through preserved the source's cosmetic
            // damage - " Positive" with a leading space, inconsistent quoting -
            // and the loader accepted the file and inserted nothing, with no
            // error to explain why. Rebuilding guarantees the output is
            // well-formed whatever the input looked like.
            Set nf = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(line, sep, .chk)
            Set allEmpty = 1
            For k = 1:1:nf {
                If $ZStrip($Get(chk(k)), "<>W") '= "" {
                    Set allEmpty = 0
                    Quit
                }
            }
            // A row that is empty ONCE THE QUOTES COME OFF - a bare `""`, which
            // this file ends with twice. Not a blank line, so a string
            // comparison misses it, and it reaches the loader as a one-field row
            // where seven are expected. The Java loader's answer to that is
            // `java.lang.InterruptedException`, which names nothing useful.
            If allEmpty {
                Set dropped = dropped + 1
                Continue
            }
            Set rebuilt = ""
            For k = 1:1:nFields {
                Set value = $ZStrip($Get(chk(k)), "<>W")
                If tsFix {
                    Set value = ..NormalizeTimestamp(value, dayFirst)
                }
                Set rebuilt = rebuilt _ $Select(k = 1: "", 1: sep) _
                    ..CsvField(value, sep)
            }
            Do out.WriteLine(rebuilt)
            Set rows = rows + 1
        }
        Set sc = out.%Save()
        If $$$ISERR(sc) {
            Set newName = ""
            Return "ERROR: could not write " _ newName _ ": " _ $System.Status.GetErrorText(sc)
        }
        Set note = "rewrote " _ fileName _ " as " _ newName _ " (" _ rows _ " rows"
        If wrapped {
            Set note = note _ "; every line was wrapped in quotes and has been unwrapped"
        }
        If renamed > 0 {
            Set note = note _ "; " _ renamed _ " column name(s) made SQL-safe"
        }
        If dropped > 0 {
            Set note = note _ "; " _ dropped _ " empty row(s) dropped"
        }
        If tsFix {
            Set note = note _ "; timestamps rewritten as YYYY-MM-DD HH:MM:SS"
            If 'dayFirst {
                Set note = note _ " (slash dates read as month first)"
            }
        }
        Set note = note _ ")"
        Return ""
    } Catch ex {
        Set newName = ""
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// One CSV field, quoted only when it has to be. RFC4180: a field containing
/// the separator, a quote or a newline is quoted, and inner quotes are doubled.
ClassMethod CsvField(value As %String, sep As %String) As %String [ Internal ]
{
    If (value [ sep) || (value [ """") || (value [ $Char(10)) || (value [ $Char(13)) {
        Return """" _ $Replace(value, """", """""") _ """"
    }
    Return value
}

/// Does the file carry rows that are empty once quoting is accounted for?
/// Cheap enough to check up front, and the difference between a clean load and
/// `java.lang.InterruptedException`.
/// Which of the first two components of a "nn/nn/yyyy" value is the day.
///
/// A single value cannot say: 01/01/2025 is the same date either way, and
/// guessing wrong silently moves every reading to the wrong month. So decide
/// from the whole file - the first component above 12 can only be a day, the
/// second above 12 can only be a day in the other order - and scan until one of
/// them settles it. A file of nothing but the first twelve days of each month
/// never settles, and there the process's own date format is the best available
/// answer, which on this instance means day first.
ClassMethod DayFirst(path As %String, sep As %String) As %Boolean [ Internal ]
{
    Set stream = ##class(%Stream.FileCharacter).%New()
    If $$$ISERR(stream.LinkToFile(path)) {
        Return 1
    }
    If 'stream.AtEnd {
        Do stream.ReadLine()
    }
    Set scanned = 0
    While ('stream.AtEnd) && (scanned < ..#DAYFIRSTROWS) {
        Set line = $ZStrip(stream.ReadLine(), ">", $Char(13))
        If $ZStrip(line, "<>W") = "" {
            Continue
        }
        Set scanned = scanned + 1
        Set nf = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(line, sep, .chk)
        For k = 1:1:nf {
            Set v = $ZStrip($Get(chk(k)), "<>W")
            If '($Extract(v, 1, 10) ? 2N1"/"2N1"/"4N) {
                Continue
            }
            Set a = +$Piece($Extract(v, 1, 10), "/", 1)
            Set b = +$Piece($Extract(v, 1, 10), "/", 2)
            If a > 12 {
                Return 1
            }
            If b > 12 {
                Return 0
            }
        }
    }
    // Undecidable from the data: follow the process's date format, where 1 is
    // the American month-first ordering and everything else is day first.
    Try {
        Set fmt = ##class(%SYS.NLS.Format).%New("current")
        Return (fmt.DateFormat '= 1)
    } Catch ex {
    }
    Return 1
}

/// True when the first data row carries an ISO-8601 date+time value, i.e. one
/// with a "T" separator or no seconds. IRIS %TimeStamp only validates
/// "YYYY-MM-DD HH:MM:SS", so such a value cannot be loaded into a TIMESTAMP
/// column as it stands - it either fails validation or forces the column to
/// VARCHAR, which then reads as non-temporal and disqualifies the table from
/// time-series modelling. One row is enough to decide: a timestamp column is a
/// timestamp column from its first value.
ClassMethod HasIsoTimestamp(path As %String, sep As %String, dayFirst As %Boolean = 1) As %Boolean [ Internal ]
{
    Set stream = ##class(%Stream.FileCharacter).%New()
    If $$$ISERR(stream.LinkToFile(path)) {
        Return 0
    }
    If 'stream.AtEnd {
        Do stream.ReadLine()
    }
    While 'stream.AtEnd {
        Set line = $ZStrip(stream.ReadLine(), ">", $Char(13))
        If $ZStrip(line, "<>W") = "" {
            Continue
        }
        Set nf = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(line, sep, .chk)
        For k = 1:1:nf {
            Set v = $ZStrip($Get(chk(k)), "<>W")
            If ..NormalizeTimestamp(v, dayFirst) '= v {
                Return 1
            }
        }
        Return 0
    }
    Return 0
}

/// Rewrite an ISO-8601 date+time as the only form IRIS %TimeStamp accepts:
/// "YYYY-MM-DD HH:MM:SS". Handles the "T" separator and a missing seconds
/// field ("1980-01-01T00:00" -> "1980-01-01 00:00:00"), and drops a fractional
/// part, which %TimeStamp tolerates but AutoML has no use for. Anything that
/// is not such a value is returned untouched.
ClassMethod NormalizeTimestamp(v As %String, dayFirst As %Boolean = 1) As %String [ Internal ]
{
    If $Length(v) < 16 {
        Return v
    }
    Set datePart = $Extract(v, 1, 10)
    Set link = $Extract(v, 11)
    If datePart ? 4N1"-"2N1"-"2N {
        // already ISO: only the separator and the seconds may need fixing
        If (link '= "T") && (link '= " ") {
            Return v
        }
    } ElseIf datePart ? 2N1"/"2N1"/"4N {
        // "01/01/2025 00:00:00.000000" - INMET and most Brazilian exports.
        // dayFirst says which of the first two components is the day; the
        // caller works that out from the whole file, because a value like
        // 01/01 says nothing on its own.
        If link '= " " {
            Return v
        }
        Set a = $Piece(datePart, "/", 1), b = $Piece(datePart, "/", 2)
        Set datePart = $Piece(datePart, "/", 3) _ "-" _
                       $Select(dayFirst: b, 1: a) _ "-" _
                       $Select(dayFirst: a, 1: b)
    } Else {
        Return v
    }
    Set timePart = $Piece($Extract(v, 12, *), ".", 1)
    If timePart ? 2N1":"2N {
        Set timePart = timePart _ ":00"
    } ElseIf '(timePart ? 2N1":"2N1":"2N) {
        Return v
    }
    Return datePart _ " " _ timePart
}

ClassMethod HasEmptyRows(path As %String, sep As %String) As %Boolean [ Internal ]
{
    Set stream = ##class(%Stream.FileCharacter).%New()
    If $$$ISERR(stream.LinkToFile(path)) {
        Return 0
    }
    If 'stream.AtEnd {
        Do stream.ReadLine()
    }
    While 'stream.AtEnd {
        Set line = $ZStrip(stream.ReadLine(), ">", $Char(13))
        If $ZStrip(line, "<>W") = "" {
            Continue
        }
        Set nf = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(line, sep, .chk)
        Set allEmpty = 1
        For k = 1:1:nf {
            If $ZStrip($Get(chk(k)), "<>W") '= "" {
                Set allEmpty = 0
                Quit
            }
        }
        If allEmpty {
            Return 1
        }
    }
    Return 0
}

/// Pre-flight validation: file present + readable, header column count matches
/// the target columns, and the LOAD statement prepares cleanly. Returns "" or an
/// ERROR string — called before any table/production is created.
ClassMethod Validate(fileName As %String, columnDefs As %String, header As %Boolean, separator As %String, Output colList As %String) As %String
{
    Set colList = ""
    If '##class(DataIntegrator.Tools.Util).ValidColumnDefs(columnDefs) {
        Return "ERROR: invalid column definition list"
    }
    If (fileName [ "/") || (fileName [ "\") || (fileName [ "..") {
        Return "ERROR: fileName must be a bare file name in the dropzone"
    }
    Set path = ..#DROPZONE _ "/" _ fileName
    If '##class(%File).Exists(path) {
        Return "ERROR: file not found in dropzone: " _ fileName
    }
    Set colList = ..ColNames(columnDefs)
    Set nCols = $Length(colList, ",")
    // header column count == target column count
    Set stream = ##class(%Stream.FileCharacter).%New()
    If $$$ISOK(stream.LinkToFile(path)) && ('stream.AtEnd) {
        Set first = $ZStrip(stream.ReadLine(), ">", $Char(13))
        // Quote-aware: a comma inside "New York, NY" is data. Counting with
        // $Length() made a fully quote-wrapped header look like 7 columns when
        // it is one, so validation passed and the LOAD then failed on a name
        // mismatch instead.
        Set nFile = ##class(DataIntegrator.Tools.CsvProfiling).SplitAll(first, ..SepChar(separator), .probe)
        If nFile '= nCols {
            Return "ERROR: the file's first row has " _ nFile _ " column(s) but the target expects " _
                nCols _ " (" _ colList _ ") — check the delimiter and header setting"
        }
    }
    Return ""
}

/// The nearest legal table name to what the caller asked for, so the error can
/// suggest something instead of only refusing. Same shaping as
/// CsvProfiling:SafeColumnName(), including the prefix for a leading digit.
ClassMethod SafeBaseName(raw As %String) As %String [ Internal ]
{
    Set out = ""
    For i = 1:1:$Length(raw) {
        Set ch = $Extract(raw, i)
        If (ch ? 1AN) || (ch = "_") {
            Set out = out _ ch
        } ElseIf $Extract(out, *) '= "_" {
            Set out = out _ "_"
        }
    }
    Set out = $ZStrip(out, "<>", "_")
    If (out '= "") && '($Extract(out) ? 1A) {
        Set out = "t_" _ out
    }
    Return $Select(out = "": "bulk_data", 1: $Extract(out, 1, 60))
}

/// The column names an existing table actually has, comma separated, in
/// declaration order. Empty when the table does not exist.
ClassMethod TableColumns(target As %String) As %String [ Internal ]
{
    Set schema = $Piece(target, ".", 1), tbl = $Piece(target, ".", 2)
    Set out = ""
    Try {
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COLUMN_NAME c FROM INFORMATION_SCHEMA.COLUMNS "_
            "WHERE UPPER(TABLE_SCHEMA)=? AND UPPER(TABLE_NAME)=? ORDER BY ORDINAL_POSITION",
            $ZConvert(schema, "U"), $ZConvert(tbl, "U"))
        While rs.%Next() {
            Set out = out _ $Select(out = "": "", 1: ",") _ rs.%Get("c")
        }
    } Catch {
    }
    Return out
}

/// Do an existing table's columns match the ones the file will load into?
/// LOAD DATA matches the file's header against the target's column NAMES, so
/// order does not matter but the set must be identical - a near-miss would load
/// nothing useful and is worth refusing over.
ClassMethod SameColumnSet(a As %String, b As %String) As %Boolean [ Internal ]
{
    If $Length(a, ",") '= $Length(b, ",") {
        Return 0
    }
    For i = 1:1:$Length(a, ",") {
        Set have = 0
        Set one = $ZConvert($ZStrip($Piece(a, ",", i), "<>W"), "U")
        For j = 1:1:$Length(b, ",") {
            If one = $ZConvert($ZStrip($Piece(b, ",", j), "<>W"), "U") {
                Set have = 1
                Quit
            }
        }
        If 'have {
            Return 0
        }
    }
    Return 1
}

/// Build target, validate, and first-load the file. strategy: full | append.
/// Returns stats JSON {rowsLoaded, target, ...} or an ERROR string.
ClassMethod Deploy(runId As %String, baseName As %String, fileName As %String, columnDefs As %String, strategy As %String = "full", bulk As %Boolean = 1, header As %Boolean = 1, separator As %String = ",") As %String
{
    Try {
        Set util = "DataIntegrator.Tools.Util"
        If '$ClassMethod(util, "ValidIdent", baseName) {
            // "invalid baseName" on its own named neither the value nor the
            // rule, and the rule that actually bites is the first character:
            // a file called 2INMETSAOPAULO2025.CSV suggests the base name
            // "2INMETSAOPAULO2025", and an SQL identifier cannot start with a
            // digit.
            Return "ERROR: invalid baseName '" _ baseName _ "' - a table name must "_
                   "start with a letter and contain only letters, digits and "_
                   "underscores. Try '" _ ..SafeBaseName(baseName) _ "'."
        }
        Set err = ..Validate(fileName, columnDefs, header, separator, .colList)
        If err '= "" {
            Return err
        }
        // A bulk load lands in DATAINTEGRATOR.ext_*, beside the mounted sources, NOT
        // in ETLW_TARGET. It belongs to the Data Sources tab: it is something to
        // build an ETL FROM, not the output of one. The difference from the
        // other ext_* tables is that this one is a real table holding a copy -
        // the file was ingested once - where a mounted CSV is a foreign table
        // read through on every query. Both are sources; only this one survives
        // the file being deleted.
        Set target = ..SourceTableName(baseName)
        Set path = ..#DROPZONE _ "/" _ fileName

        // APPEND means append. This used to DROP + CREATE unconditionally, so
        // deploying a second file with strategy "append" replaced the table it
        // was supposed to add to and the previous rows were gone - the one
        // outcome the strategy exists to avoid.
        //
        // So: append onto an existing, same-shaped table loads straight onto it.
        // Anything else (full reload, or append when there is no table yet)
        // builds the table fresh, shaped exactly to the file's columns (no audit
        // cols, so the LOAD column list matches 1:1).
        Set appending = 0
        Set rowsBefore = 0
        If (strategy = "append") && $SYSTEM.SQL.Schema.TableExists(target) {
            Set existing = ..TableColumns(target)
            If '..SameColumnSet(existing, colList) {
                // Silently dropping here is how the rows went missing. Refuse and
                // say what differs, so the choice is the user's.
                Return "ERROR: cannot append to " _ target _ " - its columns (" _ existing _
                       ") do not match this file's (" _ colList _ "). Use Full reload to "_
                       "rebuild the table, or append a file with the same columns."
            }
            Set appending = 1
            Set rowsBefore = ..CountRows(target)
        } Else {
            Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ target)
            Set err = $ClassMethod(util, "RunDDL", "CREATE TABLE " _ target _ " (" _ columnDefs _ ")")
            If err '= "" {
                Return err
            }
        }

        // VALIDATION LAYER: prepare the exact LOAD statement before executing
        Set loadSql = ..BuildLoadSql(target, colList, path, bulk, header, separator)
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(loadSql)
        If $$$ISERR(sc) {
            Return "ERROR: the file does not form a valid load statement: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR loading file (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
        Set rows = ..CountRows(target)

        // graph: source(file) -> bulk_load -> source table
        Set srcName = "file: " _ fileName
        Set cfg = {"file": (fileName), "strategy": (strategy), "bulk": (bulk),
                   "header": (header), "separator": (separator)}
        Do $ClassMethod(util, "CatalogNode", runId, "source", srcName, "", cfg.%ToJSON())
        Do $ClassMethod(util, "CatalogNode", runId, "bulk_load", baseName _ "_bulk", loadSql, cfg.%ToJSON())
        Do $ClassMethod(util, "CatalogNode", runId, "source_table", target, "", "")
        Set cat = ##class(DataIntegrator.Tools.Catalog).%New()
        Do cat.CatalogLink(runId, srcName, baseName _ "_bulk", $Select(bulk: "LOAD BULK DATA", 1: "LOAD DATA"))
        Do cat.CatalogLink(runId, baseName _ "_bulk", target, $Select(strategy = "append": "Append", 1: "Full reload"))

        Return {"strategy": ("bulk"), "rowsLoaded": (rows), "target": (target),
                "sourceTable": (target), "bulk": (bulk), "file": (fileName),
                "appended": (appending), "rowsBefore": (rowsBefore),
                "rowsAdded": (rows - rowsBefore)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Re-run entry (executor / production). Reads file + options from the pipeline
/// metadata. Full = TRUNCATE then LOAD; Append = LOAD onto existing rows.
ClassMethod RunBulkLoad(runId As %String, baseName As %String) As %String
{
    Try {
        Set util = "DataIntegrator.Tools.Util"
        Set run = ##class(DataIntegrator.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set meta = ##class(%DynamicObject).%FromJSON(run.Pipeline.MetadataJson)
        If '$IsObject(meta.source) {
            Return "ERROR: pipeline metadata has no source"
        }
        Set fileName = meta.source.%Get("file", "")
        Set columnDefs = meta.source.%Get("columnDefs", "")
        Set strategy = meta.source.%Get("strategy", "full")
        Set bulk = meta.source.%Get("bulk", 1)
        Set header = meta.source.%Get("header", 1)
        Set separator = meta.source.%Get("separator", ",")
        // The same table Deploy() built: DATAINTEGRATOR.ext_<base>. This said
        // "ETLW_TARGET." _ baseName, a table no bulk load ever creates, so every
        // re-run (manual Run and the production LoadOperation) loaded into
        // nothing - append had nothing to append to.
        Set target = ..SourceTableName(baseName)
        If '$SYSTEM.SQL.Schema.TableExists(target) {
            Return "ERROR: " _ target _ " does not exist - deploy the bulk load before re-running it"
        }
        // Only meaningful when appending: a full reload truncates first, so
        // "rows before" would just make rowsAdded come out negative.
        Set appending = $Select(strategy = "append": 1, 1: 0)
        Set rowsBefore = $Select(appending: ..CountRows(target), 1: 0)

        Set err = ..Validate(fileName, columnDefs, header, separator, .colList)
        If err '= "" {
            Return err
        }
        If strategy '= "append" {
            Do $ClassMethod(util, "RunDML", "TRUNCATE TABLE " _ target)
        }
        Set loadSql = ..BuildLoadSql(target, colList, ..#DROPZONE _ "/" _ fileName, bulk, header, separator)
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(loadSql)
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR loading file (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
        Set rows = ..CountRows(target)
        Return {"strategy": ("bulk"), "rowsLoaded": (rows), "target": (target),
                "appended": (appending),
                "rowsBefore": (rowsBefore), "rowsAdded": (rows - rowsBefore)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Row count of a target table.
ClassMethod CountRows(target As %String) As %Integer [ Internal ]
{
    Set n = 0
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt.%Prepare("SELECT COUNT(*) c FROM " _ target)) {
            Set rs = stmt.%Execute()
            If rs.%Next() { Set n = rs.%Get("c") }
        }
    } Catch {
    }
    Return n
}

}
