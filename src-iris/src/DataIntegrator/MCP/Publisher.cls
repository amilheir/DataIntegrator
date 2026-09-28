Include %occStatus

/// Publishes the target tables Data Integration built as MCP tools
/// (mds/mcp-tab-plan.md).
///
/// One fixed endpoint, one regenerated ToolSet. Publishing rewrites the XData
/// of ETLWizard.MCP.ToolSet and recompiles it; config.toml never changes, so
/// no MCP-server restart is needed to add a table.
///
/// Tools are <Query> elements - SQL, no ObjectScript. The %AI.ToolSet compiler
/// builds the JSON Schema from Arguments, binds the :name placeholders and
/// enforces MaxRows for us.
Class ETLWizard.MCP.Publisher Extends %RegisteredObject
{

Parameter TOOLSETCLASS = "ETLWizard.MCP.ToolSet";

Parameter SERVICECLASS = "ETLWizard.MCP.Service";

Parameter ENDPOINT = "/mcp/irisaihub";

/// Hard ceiling on any tool's MaxRows. An MCP client has no approval gate, so
/// this is enforced here and not in the textarea.
Parameter MAXROWS = 1000;

/// Default row cap for a generated "all rows" tool.
Parameter DEFAULTMAXROWS = 200;

/// Schemas a published query may read. ETLW_* are ours; ETLWIZARD holds the
/// mounted foreign tables; INFORMATION_SCHEMA is what the _schema tools read.
ClassMethod AllowedSchemas() As %List [ Internal ]
{
    Return $ListBuild("ETLW_TARGET", "ETLW_STAGING", "ETLW_LANDING", "ETLWIZARD", "INFORMATION_SCHEMA")
}

/// Where the published spec is kept so the tab can re-edit it. The compiled
/// class is the truth; this is the editable source it was built from, and
/// Publish writes both or neither.
ClassMethod SpecNode() As %String [ Internal ]
{
    Return "^ETLWizard.MCP"
}

// ---------------------------------------------------------------- discovery

/// Every ETLW_TARGET table, with row count and columns - the pick list for
/// step 1 of the tab.
ClassMethod ListPublishable() As %DynamicArray
{
    Set out = []
    Try {
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES " _
            "WHERE TABLE_SCHEMA = 'ETLW_TARGET' ORDER BY TABLE_NAME")
        While rs.%Next() {
            Set name = rs.%GetData(1)
            Set full = "ETLW_TARGET." _ name
            Set rows = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ full)
            If $Extract(rows, 1, 5) = "ERROR" {
                Set rows = ""
            }
            Do out.%Push({"name": (name), "full": (full), "rows": (rows),
                          "columns": (..Columns(name))})
        }
    } Catch ex {
    }
    Return out
}

/// Columns of an ETLW_TARGET table, with the type buckets the proposer needs.
ClassMethod Columns(table As %String) As %DynamicArray [ Internal ]
{
    Set out = []
    Set bare = $Piece(table, ".", *)
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
        "WHERE TABLE_SCHEMA = 'ETLW_TARGET' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")
    If $$$ISERR(sc) {
        Return out
    }
    Set rs = stmt.%Execute(bare)
    While rs.%Next() {
        Set name = rs.%GetData(1), type = $ZConvert(rs.%GetData(2), "L")
        Set numeric = ((type [ "int") || (type [ "numeric") || (type [ "decimal") ||
                       (type [ "double") || (type [ "float") || (type [ "money"))
        Set temporal = ((type [ "date") || (type [ "time"))
        Set textual = ((type [ "char") || (type = "varchar"))
        Do out.%Push({"name": (name), "type": (type), "numeric": (''numeric),
                      "temporal": (''temporal), "textual": (''textual)})
    }
    Return out
}

// ----------------------------------------------------------------- proposer

/// The default tools for one table: rows, schema, and one aggregate per
/// low-cardinality text column. Returned as editable specs, not as XML - the
/// tab shows them, the user edits them, and only then are they published.
ClassMethod ProposeTools(table As %String) As %DynamicObject
{
    Try {
        Set bare = $Piece(table, ".", *)
        If '##class(ETLWizard.Tools.Util).ValidIdent(bare) {
            Return {"error": ("not a valid table name: " _ table)}
        }
        Set full = "ETLW_TARGET." _ bare
        Set cols = ..Columns(bare)
        If cols.%Size() = 0 {
            Return {"error": ("no such table, or it has no columns: " _ full)}
        }

        Set prefix = ..ToolPrefix(bare)
        Set tools = []
        Set rowCount = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(*) FROM " _ full)
        If $Extract(rowCount, 1, 5) = "ERROR" {
            Set rowCount = "?"
        }

        // --- 1. bounded raw rows ---------------------------------------
        // The description says "sample" out loud: without it a model happily
        // sums a truncated payload and reports it as the total.
        Do tools.%Push({
            "name": (prefix _ "_rows"),
            "table": (full),
            "description": ("A SAMPLE of at most " _ ..#DEFAULTMAXROWS _ " rows from " _ full _
                " (the table holds " _ rowCount _ " rows). Use it to see what the data looks like. " _
                "Do NOT sum or count this payload - it is truncated; use the aggregate tools for totals."),
            "arguments": "",
            "maxRows": (..#DEFAULTMAXROWS),
            "sql": ("SELECT " _ ..ColumnList(cols) _ " FROM " _ full)
        })

        // --- 2. schema ---------------------------------------------------
        // The cheap first call: one small payload instead of a 200-row dump.
        Do tools.%Push({
            "name": (prefix _ "_schema"),
            "table": (full),
            "description": ("Column names and SQL types of " _ full _
                ". Call this first to find out what can be charted."),
            "arguments": "",
            "maxRows": 200,
            "sql": ("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " _
                "WHERE TABLE_SCHEMA = 'ETLW_TARGET' AND TABLE_NAME = '" _ bare _ "' " _
                "ORDER BY ORDINAL_POSITION")
        })

        // --- 3. one aggregate per plausible group-by column --------------
        Set measure = ..PickMeasure(cols)
        Set iter = cols.%GetIterator()
        Set considered = 0
        While iter.%GetNext(.k, .col) {
            If 'col.textual {
                Continue
            }
            If considered >= 8 {
                Continue
            }
            Set considered = considered + 1
            Set distinct = ..DistinctCount(full, col.name)
            // A group-by over a near-unique column is a listing, not a chart.
            If (distinct < 2) || (distinct > 60) {
                Continue
            }
            Do tools.%Push(..AggregateSpec(full, prefix, col.name, measure, distinct))
        }

        Return {"table": (full), "rows": (rowCount), "tools": (tools)}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// One group-by tool: counts always, plus a SUM when there is a measure worth
/// summing. topN is an argument because a parameter binds in the TOP clause.
ClassMethod AggregateSpec(full As %String, prefix As %String, col As %String, measure As %String, distinct As %Integer) As %DynamicObject [ Internal ]
{
    Set label = ..Slug(col)
    Set desc = "Rows grouped by " _ col _ " in " _ full _ " (" _ distinct _
        " distinct values), ordered by the largest first. Use this for charts and totals"
    If measure '= "" {
        // "total_total_value" reads like a bug; a measure already named total_*
        // is its own best result-column name.
        Set mslug = ..Slug(measure)
        Set alias = $Select($Extract(mslug, 1, 5) = "total": mslug, 1: "total_" _ mslug)
        Set desc = desc _ " - it returns both a row count and the summed " _ measure
        Set select = "SELECT TOP :topN " _ col _ " AS " _ label _ ", COUNT(*) AS row_count, " _
            "SUM(" _ measure _ ") AS " _ alias _ " FROM " _ full _
            " GROUP BY " _ col _ " ORDER BY SUM(" _ measure _ ") DESC"
    } Else {
        Set desc = desc _ " - it returns a row count per group"
        Set select = "SELECT TOP :topN " _ col _ " AS " _ label _ ", COUNT(*) AS row_count " _
            "FROM " _ full _ " GROUP BY " _ col _ " ORDER BY COUNT(*) DESC"
    }
    Set desc = desc _ ". Raise topN to see more groups."
    Return {"name": (prefix _ "_by_" _ label), "table": (full), "description": (desc),
            "arguments": "topN As %Integer = 10", "maxRows": 200, "sql": (select)}
}

/// The numeric column most worth summing. Name beats position: a column called
/// total_value is a measure, one called customer_id is an identifier that
/// happens to be numeric, and summing it produces confident nonsense.
ClassMethod PickMeasure(cols As %DynamicArray) As %String [ Internal ]
{
    Set best = "", bestRank = 0
    Set iter = cols.%GetIterator()
    While iter.%GetNext(.k, .col) {
        If 'col.numeric {
            Continue
        }
        Set lower = $ZConvert(col.name, "L")
        // never sum a key or a surrogate id
        If (lower [ "_id") || (lower = "id") || ($Extract(lower, 1, 3) = "id_") {
            Continue
        }
        Set rank = 1
        If (lower [ "total") || (lower [ "amount") || (lower [ "revenue") ||
           (lower [ "value") || (lower [ "sales") {
            Set rank = 3
        } ElseIf (lower [ "price") || (lower [ "cost") || (lower [ "qty") ||
                 (lower [ "quantity") || (lower [ "count") {
            Set rank = 2
        }
        If rank > bestRank {
            Set bestRank = rank, best = col.name
        }
    }
    Return best
}

/// COUNT(DISTINCT col), or -1 when it cannot be counted. Used only to decide
/// whether a column is worth grouping by.
ClassMethod DistinctCount(full As %String, col As %String) As %Integer [ Internal ]
{
    Set res = ##class(ETLWizard.Tools.Util).ScalarQuery("SELECT COUNT(DISTINCT " _ col _ ") FROM " _ full)
    If ($Extract(res, 1, 5) = "ERROR") || (res = "") {
        Return -1
    }
    Return +res
}

/// Comma-separated column list, so a generated SELECT names its columns
/// instead of leaning on * (which changes shape when the table does).
ClassMethod ColumnList(cols As %DynamicArray) As %String [ Internal ]
{
    Set out = ""
    Set iter = cols.%GetIterator()
    While iter.%GetNext(.k, .col) {
        Set out = out _ $Select(out = "": "", 1: ", ") _ col.name
    }
    Return $Select(out = "": "*", 1: out)
}

/// Table name -> tool-name prefix. Already an identifier by construction, but
/// a stray character here becomes an invalid tool name at compile time.
ClassMethod ToolPrefix(bare As %String) As %String [ Internal ]
{
    Return ..Slug(bare)
}

/// Lowercase identifier safe for a tool or result-column name.
ClassMethod Slug(text As %String) As %String [ Internal ]
{
    Set out = ""
    For i = 1:1:$Length(text) {
        Set ch = $Extract(text, i)
        If (ch ? 1AN) || (ch = "_") {
            Set out = out _ ch
        } Else {
            Set out = out _ "_"
        }
    }
    Set out = $ZConvert(out, "L")
    // a tool name must start with a letter
    If '($Extract(out) ? 1A) {
        Set out = "t_" _ out
    }
    Return $Extract(out, 1, 60)
}

// ---------------------------------------------------------------- validation

/// Validate one tool spec. Returns "" when it is publishable, else the reason.
///
/// This is the whole security boundary: what passes here is reachable by any
/// MCP client with no approval step in between.
ClassMethod ValidateTool(tool As %DynamicObject) As %String [ Internal ]
{
    Set name = $ZStrip(tool.%Get("name", ""), "<>W")
    If name = "" {
        Return "every tool needs a name"
    }
    If '##class(ETLWizard.Tools.Util).ValidIdent(name) {
        Return "tool name '" _ name _ "' must start with a letter and contain only letters, digits and underscores"
    }
    If $Length(name) > 64 {
        Return "tool name '" _ name _ "' is longer than 64 characters"
    }
    If $ZStrip(tool.%Get("description", ""), "<>W") = "" {
        Return "tool '" _ name _ "' needs a description - it is what the model reads to decide whether to call it"
    }

    Set sql = $ZStrip(tool.%Get("sql", ""), "<>W")
    If sql = "" {
        Return "tool '" _ name _ "' has no SQL"
    }
    If '##class(ETLWizard.Tools.Util).IsSelectOnly(sql) {
        Return "tool '" _ name _ "' must be a single SELECT statement"
    }
    If sql [ "]]>" {
        Return "tool '" _ name _ "' contains ']]>', which cannot be embedded in the ToolSet XML"
    }
    Set bad = ..CheckTables(sql)
    If bad '= "" {
        Return "tool '" _ name _ "': " _ bad
    }

    Set maxRows = +tool.%Get("maxRows", ..#DEFAULTMAXROWS)
    If (maxRows < 1) || (maxRows > ..#MAXROWS) {
        Return "tool '" _ name _ "' needs maxRows between 1 and " _ ..#MAXROWS
    }

    Return ..CheckArguments(name, tool.%Get("arguments", ""), sql)
}

/// Every table read by the statement must live in a schema we own. Returns ""
/// when clean, else the complaint.
///
/// Checks the token after each FROM / JOIN rather than every dotted name: an
/// alias-qualified column (a.customer_id) is not a schema reference, and
/// treating it as one rejected every legitimate join.
ClassMethod CheckTables(sql As %String) As %String [ Internal ]
{
    Set clean = ##class(ETLWizard.Tools.Util).StripSqlComments(sql)
    Set clean = ..BlankLiterals(clean)
    Set allowed = ..AllowedSchemas()
    Set upper = $ZConvert(clean, "U")
    Set len = $Length(clean)
    Set i = 1, seen = 0
    While i <= len {
        Set word = ""
        // read one token of identifier characters
        While i <= len {
            Set ch = $Extract(clean, i)
            If (ch ? 1AN) || (ch = "_") || (ch = "%") || (ch = ".") {
                Set word = word _ ch
                Set i = i + 1
            } Else {
                Quit
            }
        }
        If word = "" {
            Set i = i + 1
            Continue
        }
        Set kw = $ZConvert(word, "U")
        If (kw '= "FROM") && (kw '= "JOIN") {
            Continue
        }
        // the token after FROM/JOIN is the table (or an opening paren)
        Set j = ..SkipSpace(clean, i)
        If $Extract(clean, j) = "(" {
            // derived table - its own FROM is scanned by this same loop
            Set i = j + 1
            Continue
        }
        Set target = ""
        While j <= len {
            Set ch = $Extract(clean, j)
            If (ch ? 1AN) || (ch = "_") || (ch = "%") || (ch = ".") || (ch = """") {
                Set target = target _ ch
                Set j = j + 1
            } Else {
                Quit
            }
        }
        Set i = j
        If target = "" {
            Continue
        }
        Set seen = seen + 1
        If target '[ "." {
            Return "table '" _ target _ "' is not schema-qualified - name it as ETLW_TARGET." _ target
        }
        // delimited identifiers arrive quoted ("ETLW_TARGET".x); $ZStrip masks
        // cannot express "just these two characters", so replace them outright
        Set schema = $ZConvert($Replace($Piece(target, ".", 1), """", ""), "U")
        If '$ListFind(allowed, schema) {
            Return "schema '" _ schema _ "' is not one of Data Integration's own (" _
                $ListToString(allowed, ", ") _ ")"
        }
    }
    If seen = 0 {
        Return "no table found - a published tool must read from a table"
    }
    Return ""
}

/// Replace the contents of quoted literals with spaces so keyword scanning
/// never trips over a FROM inside a string.
ClassMethod BlankLiterals(sql As %String) As %String [ Internal ]
{
    Set out = "", inStr = 0
    For i = 1:1:$Length(sql) {
        Set ch = $Extract(sql, i)
        If ch = "'" {
            Set inStr = 'inStr
            Set out = out _ ch
            Continue
        }
        Set out = out _ $Select(inStr: " ", 1: ch)
    }
    Return out
}

ClassMethod SkipSpace(sql As %String, i As %Integer) As %Integer [ Internal ]
{
    While i <= $Length(sql) {
        Set ch = $Extract(sql, i)
        If (ch '= " ") && (ch '= $Char(9)) && (ch '= $Char(10)) && (ch '= $Char(13)) {
            Quit
        }
        Set i = i + 1
    }
    Return i
}

/// Arguments must parse as "name As %Type [= default]" and every declared name
/// must actually appear as :name in the SQL - a declared-but-unused argument
/// compiles fine and then silently ignores whatever the model passes.
ClassMethod CheckArguments(name As %String, spec As %String, sql As %String) As %String [ Internal ]
{
    Set spec = $ZStrip(spec, "<>W")
    If spec = "" {
        Return ""
    }
    For p = 1:1:$Length(spec, ",") {
        Set part = $ZStrip($Piece(spec, ",", p), "<>W")
        If part = "" {
            Return "tool '" _ name _ "' has an empty argument declaration"
        }
        Set argName = $ZStrip($Piece(part, " ", 1), "<>W")
        If '##class(ETLWizard.Tools.Util).ValidIdent(argName) {
            Return "tool '" _ name _ "': '" _ argName _ "' is not a valid argument name"
        }
        Set kw = $ZConvert($ZStrip($Piece(part, " ", 2), "<>W"), "U")
        If kw '= "AS" {
            Return "tool '" _ name _ "': argument '" _ argName _ "' must read '" _ argName _ " As %Type'"
        }
        Set type = $ZStrip($Piece($Piece(part, " ", 3), "=", 1), "<>W")
        If $Extract(type) '= "%" {
            Return "tool '" _ name _ "': argument '" _ argName _ "' needs an ObjectScript type such as %Integer or %String"
        }
        If '..MentionsParam(sql, argName) {
            Return "tool '" _ name _ "': argument '" _ argName _ "' is declared but never used as :" _ argName _ " in the SQL"
        }
    }
    Return ""
}

/// Does the SQL contain :name as a whole token?
ClassMethod MentionsParam(sql As %String, argName As %String) As %Boolean [ Internal ]
{
    Set target = ":" _ $ZConvert(argName, "U")
    Set upper = $ZConvert(sql, "U")
    Set pos = 0
    For {
        Set pos = $Find(upper, target, pos)
        If pos = 0 {
            Return 0
        }
        Set after = $Extract(upper, pos)
        If (after = "") || '((after ? 1AN) || (after = "_")) {
            Return 1
        }
    }
}

// ------------------------------------------------------------------ publish

/// Render the ToolSet XData for a list of validated specs, or "ERROR ...".
ClassMethod BuildXData(tools As %DynamicArray) As %String
{
    If '$IsObject(tools) {
        Return "ERROR: no tools given"
    }
    Set nl = $Char(10)
    Set seen = ""
    Set body = ""
    Set iter = tools.%GetIterator()
    While iter.%GetNext(.k, .tool) {
        Set err = ..ValidateTool(tool)
        If err '= "" {
            Return "ERROR: " _ err
        }
        Set name = $ZStrip(tool.%Get("name"), "<>W")
        If seen [ ("," _ $ZConvert(name, "U") _ ",") {
            Return "ERROR: two tools are both named '" _ name _ "'"
        }
        Set seen = seen _ "," _ $ZConvert(name, "U") _ ","

        Set body = body _ "  <Query Name=""" _ ..XmlAttr(name) _ """" _ nl
        Set body = body _ "         Description=""" _ ..XmlAttr(..OneLine(tool.%Get("description"))) _ """" _ nl
        Set args = $ZStrip(tool.%Get("arguments", ""), "<>W")
        If args '= "" {
            Set body = body _ "         Arguments=""" _ ..XmlAttr(args) _ """" _ nl
        }
        Set body = body _ "         MaxRows=""" _ (+tool.%Get("maxRows", ..#DEFAULTMAXROWS)) _ """>" _ nl
        // Always CDATA: a WHERE clause with < or > is the common case, and
        // ']]>' is rejected in validation.
        Set body = body _ "    <![CDATA[" _ nl _ "    " _ ..OneLine(tool.%Get("sql")) _ nl _ "    ]]>" _ nl
        Set body = body _ "  </Query>" _ nl _ nl
    }
    If body = "" {
        Return "ERROR: no tools to publish"
    }
    Set xml = "<ToolSet Name=""DataIntegration"">" _ nl
    Set xml = xml _ "  <Description>Live query tools over the tables InterSystems IRIS Data Integration built</Description>" _ nl _ nl
    Set xml = xml _ body _ "</ToolSet>"
    Return xml
}

/// Collapse whitespace onto one line. The Description reaches the MCP client
/// with the XML indentation intact, so a multi-line attribute arrives with
/// ragged spacing baked into the text the model reads.
ClassMethod OneLine(text As %String) As %String [ Internal ]
{
    Set out = ""
    For i = 1:1:$Length(text) {
        Set ch = $Extract(text, i)
        If (ch = $Char(10)) || (ch = $Char(13)) || (ch = $Char(9)) {
            Set ch = " "
        }
        If (ch = " ") && ($Extract(out, *) = " ") {
            Continue
        }
        Set out = out _ ch
    }
    Return $ZStrip(out, "<>W")
}

ClassMethod XmlAttr(text As %String) As %String [ Internal ]
{
    Set out = $Replace(text, "&", "&amp;")
    Set out = $Replace(out, "<", "&lt;")
    Set out = $Replace(out, ">", "&gt;")
    Set out = $Replace(out, """", "&quot;")
    Return out
}

/// Publish: write the ToolSet class, compile it, and report back the tools the
/// %AI discovery actually found. Publishing nothing is an error, not a no-op -
/// an empty ToolSet compiles happily and leaves the endpoint mute.
ClassMethod Publish(tools As %DynamicArray) As %DynamicObject
{
    Try {
        Set xml = ..BuildXData(tools)
        If $Extract(xml, 1, 5) = "ERROR" {
            Return {"error": ($Extract(xml, 8, *))}
        }
        Set err = ..EnsureService()
        If err '= "" {
            Return {"error": (err)}
        }

        Set err = ..WriteToolSetClass(..#TOOLSETCLASS, xml)
        If err '= "" {
            Return {"error": (err)}
        }

        Set discovered = ..Discover(.derr)
        If derr '= "" {
            Return {"error": (derr)}
        }
        If discovered.%Size() = 0 {
            Return {"error": "the ToolSet compiled but no tools were discovered - check the SQL in each tool"}
        }

        // spec and class are written together: the class is the truth, this is
        // the editable source it came from
        Set @..SpecNode()@("spec") = tools.%ToJSON()
        Set @..SpecNode()@("publishedAt") = $ZDateTime($Horolog, 3)

        Return {"endpoint": (..#ENDPOINT), "count": (discovered.%Size()),
                "tools": (discovered), "publishedAt": ($ZDateTime($Horolog, 3))}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// Write and compile a %AI.ToolSet subclass around a rendered XData block.
/// Returns "" on success, else the reason.
ClassMethod WriteToolSetClass(cls As %String, xml As %String) As %String [ Internal ]
{
    Set nl = $Char(10)
    Set src = "/// MCP tools over the tables Data Integration built." _ nl
    Set src = src _ "/// GENERATED by ETLWizard.MCP.Publisher - edit the tools in the MCP Tools tab," _ nl
    Set src = src _ "/// not here. Every publish overwrites this class." _ nl
    Set src = src _ "Class " _ cls _ " Extends %AI.ToolSet" _ nl _ "{" _ nl _ nl
    Set src = src _ "XData Definition [ MimeType = application/xml ]" _ nl _ "{" _ nl
    Set src = src _ xml _ nl _ "}" _ nl _ nl _ "}" _ nl

    Set stream = ##class(%Stream.TmpCharacter).%New()
    Do stream.Write(src)
    Set sc = $System.OBJ.LoadStream(stream, "ck-d", .errLog, .loaded)
    If $$$ISERR(sc) {
        Return "the ToolSet did not compile: " _ $System.Status.GetErrorText(sc)
    }
    // A recompiled ToolSet leaves stale cached queries behind; without this the
    // next call dies with <CLASS DOES NOT EXIST> %sqlcq...
    Do $System.SQL.Purge()
    Return ""
}

/// Run ONE unpublished tool spec exactly the way a published one runs: compile
/// it into a throwaway single-tool ToolSet and execute it through %AI.ToolMgr.
///
/// Compiling a class to answer a Test button is not free, but the alternative -
/// running the SQL directly and calling it a test - would exercise a different
/// code path than the one being published, which is precisely the thing the
/// button exists to check.
///
/// The throwaway class is left compiled rather than deleted: it is overwritten
/// by the next preview, it is referenced by no service, and deleting it on
/// every Test would churn the class dictionary for no gain.
ClassMethod PreviewTool(tool As %DynamicObject, args As %DynamicObject = {{}}) As %DynamicObject
{
    Try {
        Set one = []
        Do one.%Push(tool)
        Set xml = ..BuildXData(one)
        If $Extract(xml, 1, 5) = "ERROR" {
            Return {"error": ($Extract(xml, 8, *))}
        }
        Set cls = ..#TOOLSETCLASS _ "Preview"
        Set err = ..WriteToolSetClass(cls, xml)
        If err '= "" {
            Return {"error": (err)}
        }
        Set mgr = ##class(%AI.ToolMgr).%New()
        Set sc = mgr.RegisterToolSet(cls)
        If $$$ISERR(sc) {
            Return {"error": ($System.Status.GetErrorText(sc))}
        }
        Set res = mgr.ExecuteTool(tool.%Get("name"), args)
        If $IsObject(res) && (res.%GetTypeOf("value") = "object") {
            Return res.value
        }
        Return res
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// What the endpoint currently serves, straight from the compiled class, plus
/// the spec it was built from so the tab can re-open it for editing.
ClassMethod Published() As %DynamicObject
{
    Set out = {"endpoint": (..#ENDPOINT), "tools": [], "spec": [],
               "publishedAt": ($Get(@..SpecNode()@("publishedAt"), ""))}
    Try {
        If '##class(%Dictionary.CompiledClass).%ExistsId(..#TOOLSETCLASS) {
            Return out
        }
        Set out.tools = ..Discover(.derr)
        If derr '= "" {
            Set out.error = derr
        }
        Set spec = $Get(@..SpecNode()@("spec"), "")
        If spec '= "" {
            Set out.spec = ##class(%DynamicAbstractObject).%FromJSON(spec)
        }
    } Catch ex {
        Set out.error = ex.DisplayString()
    }
    Return out
}

/// Ask %AI what tools the compiled ToolSet exposes - the same discovery the
/// MCP sidecar performs, so what this returns is what a client will see.
ClassMethod Discover(Output err As %String) As %DynamicArray [ Internal ]
{
    Set err = ""
    Try {
        If '##class(%Dictionary.CompiledClass).%ExistsId(..#TOOLSETCLASS) {
            Return []
        }
        Set mgr = ##class(%AI.ToolMgr).%New()
        Set sc = mgr.RegisterToolSet(..#TOOLSETCLASS)
        If $$$ISERR(sc) {
            Set err = "could not register the ToolSet: " _ $System.Status.GetErrorText(sc)
            Return []
        }
        Return mgr.%Discover()
    } Catch ex {
        Set err = ex.DisplayString()
        Return []
    }
}

/// Run one published tool in-process. This is the tab's Test button, and it is
/// the same code path an MCP client takes, minus the transport.
ClassMethod TestTool(name As %String, args As %DynamicObject = {{}}) As %DynamicObject
{
    Try {
        If '##class(%Dictionary.CompiledClass).%ExistsId(..#TOOLSETCLASS) {
            Return {"error": "nothing is published yet"}
        }
        Set mgr = ##class(%AI.ToolMgr).%New()
        Set sc = mgr.RegisterToolSet(..#TOOLSETCLASS)
        If $$$ISERR(sc) {
            Return {"error": ($System.Status.GetErrorText(sc))}
        }
        Set res = mgr.ExecuteTool(name, args)
        // ExecuteTool wraps the payload as {timing, value}; the tab wants the
        // payload, and the timing is already in value.elapsed_ms.
        If $IsObject(res) && (res.%GetTypeOf("value") = "object") {
            Return res.value
        }
        Return res
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

// ------------------------------------------------------------------ service

/// Create the MCP service class and its web application if they are missing.
/// Idempotent - called from iris.script and again on every publish.
ClassMethod EnsureService() As %String
{
    Try {
        If '##class(%Dictionary.CompiledClass).%ExistsId(..#SERVICECLASS) {
            Set nl = $Char(10)
            Set src = "/// MCP service for InterSystems IRIS Data Integration, served at " _ ..#ENDPOINT _ "." _ nl
            Set src = src _ "/// GENERATED by ETLWizard.MCP.Publisher. The tools it exposes live in" _ nl
            Set src = src _ "/// " _ ..#TOOLSETCLASS _ ", which is rewritten on every publish." _ nl
            Set src = src _ "Class " _ ..#SERVICECLASS _ " Extends %AI.MCP.Service" _ nl _ "{" _ nl _ nl
            Set src = src _ "Parameter SPECIFICATION As STRING = """ _ ..#TOOLSETCLASS _ """;" _ nl _ nl _ "}" _ nl
            Set stream = ##class(%Stream.TmpCharacter).%New()
            Do stream.Write(src)
            // The ToolSet may not exist yet on a clean install; the service
            // compiles regardless, and discovery is resolved at request time.
            Set sc = $System.OBJ.LoadStream(stream, "ck-d", .errLog, .loaded)
            If $$$ISERR(sc) {
                Return "could not create " _ ..#SERVICECLASS _ ": " _ $System.Status.GetErrorText(sc)
            }
        }
        Return ..EnsureWebApp()
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// The /mcp/irisaihub web application. Mirrors the properties of the working
/// portal-built MCP apps on this instance, AutheEnabled=64 included: the
/// sidecar reaches IRIS over the superserver, not over HTTP, so this app's
/// authentication setting is not what gates it.
ClassMethod EnsureWebApp() As %String [ Internal ]
{
    New $Namespace
    Set here = $Namespace
    Try {
        Set $Namespace = "%SYS"
        If ##class(Security.Applications).Exists(..#ENDPOINT) {
            Return ""
        }
        Set props("NameSpace") = here
        Set props("DispatchClass") = ..#SERVICECLASS
        Set props("Description") = "MCP Server: InterSystems IRIS Data Integration"
        Set props("Enabled") = 1
        Set props("Recurse") = 1
        Set props("AutheEnabled") = 64
        Set props("MatchRoles") = "%All:%All,:%All"
        Set props("CookiePath") = ..#ENDPOINT _ "/"
        Set props("CSPZENEnabled") = 1
        Set props("ServeFiles") = 1
        Set props("CorsAllowlist") = "*"
        Set props("CorsCredentialsAllowed") = 1
        Set props("CorsHeadersList") = "*"
        // Type 18, not the default 2. The iris-mcp-server sidecar probes
        // <app>/v1/services and REFUSES a catalog from an endpoint that does not
        // identify itself as an MCP service; an app created without this bit
        // answers 502 GATEWAY_REQUIRED to that probe and the sidecar logs
        // "failed identity checking", so the tools never reach a client even
        // though everything on the IRIS side is correct.
        Set props("Type") = 18
        // Creating an app without these leaves WSGI defaults (WSGIType=1,
        // WSGICallable="app") on a dispatch-class application, which the
        // working portal-built MCP apps do not carry.
        Set props("WSGIType") = ""
        Set props("WSGICallable") = ""
        Set props("WSGIDebug") = ""
        Set sc = ##class(Security.Applications).Create(..#ENDPOINT, .props)
        If $$$ISERR(sc) {
            Return "could not create the web application " _ ..#ENDPOINT _ ": " _ $System.Status.GetErrorText(sc)
        }
        Return ""
    } Catch ex {
        Return ex.DisplayString()
    }
}

/// Remove one tool from what is published and republish the rest.
ClassMethod Unpublish(name As %String) As %DynamicObject
{
    Try {
        Set spec = $Get(@..SpecNode()@("spec"), "")
        If spec = "" {
            Return {"error": "nothing is published yet"}
        }
        Set tools = ##class(%DynamicAbstractObject).%FromJSON(spec)
        Set kept = []
        Set iter = tools.%GetIterator()
        Set found = 0
        While iter.%GetNext(.k, .tool) {
            If tool.%Get("name") = name {
                Set found = 1
                Continue
            }
            Do kept.%Push(tool)
        }
        If 'found {
            Return {"error": ("no published tool named '" _ name _ "'")}
        }
        If kept.%Size() = 0 {
            Return ..Clear()
        }
        Return ..Publish(kept)
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// Publish nothing: drop the generated ToolSet so the endpoint stops offering
/// tools. The service class and web app stay, so the next publish is instant.
ClassMethod Clear() As %DynamicObject
{
    Try {
        If ##class(%Dictionary.CompiledClass).%ExistsId(..#TOOLSETCLASS) {
            Do $System.OBJ.Delete(..#TOOLSETCLASS, "-d")
            Do $System.SQL.Purge()
        }
        Kill @..SpecNode()
        Return {"endpoint": (..#ENDPOINT), "count": 0, "tools": [], "cleared": 1}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

}
