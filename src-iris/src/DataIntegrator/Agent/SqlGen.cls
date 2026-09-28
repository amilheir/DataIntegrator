/// Natural-language -> transform SQL generator (spec §10.2 generate_transform_sql).
///
/// Deliberately does NOT use the full architect agent: a focused, TOOL-FREE
/// single-purpose LLM call is far faster and much more reliable on a small
/// local model than a 40-tool agent loop. It uses the SAME provider/model
/// resolved from the Config Store (AI.LLM.ETLWizard), so it follows whichever
/// profile is active (local Ollama or cloud).
///
/// The generated SQL is always validated by PREPARING it before it is handed
/// back, so the UI can tell the user whether it actually compiles and what
/// columns it produces — the user then refines with another prompt.
Class ETLWizard.Agent.SqlGen Extends %RegisteredObject
{

/// Max tables described to the model (small models degrade with long prompts,
/// and every extra token is decode time on a local GPU).
Parameter MAXTABLES = 6;

/// Max columns described per table.
Parameter MAXCOLS = 15;

/// How many times to auto-repair invalid SQL by feeding the prepare/execute
/// error back to the model. 0 disables the loop (single shot). Each retry is a
/// full LLM turn, so keep this small on a local model.
Parameter MAXREPAIR = 2;

/// Build a compact schema description of the foreign tables available to join.
/// The pipeline's own mounted tables come first, then any other ETLWIZARD
/// foreign tables (they are all joinable).
/// tables: optional comma-separated list the user explicitly chose for this
/// ETL (with or without the ETLWIZARD. prefix). When supplied, ONLY those are
/// described — the sharpest possible context, which materially improves the
/// generated SQL on small models.
ClassMethod SchemaContext(runId As %String = "", tables As %String = "") As %String
{
    Set ctx = ""
    Set count = 0
    Try {
        // explicit user selection wins
        If $ZStrip(tables, "<>W") '= "" {
            For i = 1:1:$Length(tables, ",") {
                Set t = $ZStrip($Piece(tables, ",", i), "<>W")
                Set t = $Piece(t, ".", *)          // accept ETLWIZARD.x or x
                If t = "" {
                    Continue
                }
                Set cols = ..ColumnsOf(t)
                If cols = "" {
                    Continue
                }
                Set ctx = ctx _ "ETLWIZARD." _ t _ "(" _ cols _ ")" _ $Char(10)
            }
            If ctx '= "" {
                Return ctx
            }
        }
        // pipeline's own mounted tables first
        Set own = ""
        If runId '= "" {
            Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
            If $IsObject(run) {
                Set stmt = ##class(%SQL.Statement).%New()
                If $$$ISOK(stmt.%Prepare("SELECT Name FROM ETLWizard_Model.Node WHERE Pipeline = ? AND Kind = 'foreign_table' ORDER BY ID")) {
                    Set rs = stmt.%Execute(run.Pipeline.%Id())
                    While rs.%Next() {
                        Set n = $Piece(rs.%GetData(1), ".", *)
                        If n '= "" {
                            Set own = own _ $ListBuild(n)
                        }
                    }
                }
            }
        }
        // every table in the ETLWIZARD schema is joinable
        Set all = ""
        Set stmt2 = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt2.%Prepare("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'ETLWIZARD' ORDER BY TABLE_NAME")) {
            Set rs2 = stmt2.%Execute()
            While rs2.%Next() {
                Set all = all _ $ListBuild(rs2.%GetData(1))
            }
        }
        // ordered, de-duplicated: own tables first
        Set ordered = own
        Set p = 0
        While $ListNext(all, p, t) {
            If $ListFind(ordered, t) = 0 {
                Set ordered = ordered _ $ListBuild(t)
            }
        }
        Set p2 = 0
        While $ListNext(ordered, p2, tbl) {
            If count >= ..#MAXTABLES {
                Quit
            }
            Set cols = ..ColumnsOf(tbl)
            If cols = "" {
                Continue
            }
            Set ctx = ctx _ "ETLWIZARD." _ tbl _ "(" _ cols _ ")" _ $Char(10)
            Set count = count + 1
        }
    } Catch {
    }
    Return ctx
}

/// Column names of one ETLWIZARD table as a $List.
ClassMethod ColumnNames(table As %String) As %List [ Internal ]
{
    Set out = ""
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        If '$$$ISOK(stmt.%Prepare("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ?")) {
            Return ""
        }
        Set rs = stmt.%Execute(table)
        While rs.%Next() {
            Set out = out _ $ListBuild(rs.%GetData(1))
        }
    } Catch {
    }
    Return out
}

/// Join hints for the {joins} placeholder: for every column shared by more than
/// one of the selected tables, emit an UNDIRECTED qualified equality, one per
/// line, so the model has the join key without having to guess it:
///   ETLWIZARD.ext_customer.customer_id = ETLWIZARD.ext_orders.customer_id
/// Foreign tables carry no PK/FK metadata, so no direction is implied. When a
/// column is shared by 3+ tables, consecutive tables are chained (t1=t2, t2=t3),
/// which is enough for the model to join transitively. Returns "" if the tables
/// share no columns.
ClassMethod JoinPairs(tables As %String) As %String [ Internal ]
{
    Set out = ""
    Try {
        // ordered, de-duplicated bare table names; record which columns each has
        Set n = 0
        Kill tbl, has
        For i = 1:1:$Length(tables, ",") {
            Set t = $Piece($ZStrip($Piece(tables, ",", i), "<>W"), ".", *)
            If t = "" {
                Continue
            }
            Set dup = 0
            For j = 1:1:n {
                If $ZConvert(tbl(j), "U") = $ZConvert(t, "U") {
                    Set dup = 1
                    Quit
                }
            }
            If dup {
                Continue
            }
            Set n = n + 1, tbl(n) = t
            Set names = ..ColumnNames(t)
            Set p = 0
            While $ListNext(names, p, c) {
                Set has(n, $ZConvert(c, "U")) = c
            }
        }
        If n < 2 {
            Return ""
        }
        // column keys in first-seen order (stable output)
        Set order = 0
        Kill colKey, seenCol
        For k = 1:1:n {
            Set key = ""
            For {
                Set key = $Order(has(k, key))
                Quit:key=""
                If '$Data(seenCol(key)) {
                    Set order = order + 1, colKey(order) = key, seenCol(key) = ""
                }
            }
        }
        // for each shared column, chain the tables that carry it. Only KEY-LIKE
        // columns (id / <name>_id) are treated as join keys — this drops
        // coincidental name matches such as unit_price appearing in two tables.
        For c = 1:1:order {
            Set key = colKey(c)
            If (key '= "ID") && ($Extract(key, *-2, *) '= "_ID") {
                Continue
            }
            Set prev = 0
            For k = 1:1:n {
                If $Data(has(k, key)) {
                    If prev '= 0 {
                        Set out = out _ $Select(out = "": "", 1: $Char(10)) _
                            "ETLWIZARD." _ tbl(prev) _ "." _ has(prev, key) _ " = " _
                            "ETLWIZARD." _ tbl(k) _ "." _ has(k, key)
                    }
                    Set prev = k
                }
            }
        }
    } Catch {
    }
    Return out
}

/// "col TYPE, col TYPE" for one ETLWIZARD table (bounded).
/// The distinct values of a low-cardinality text column, as " in (a|b|c)".
///
/// Without this the model is told a column is called `status` and nothing more,
/// so it guesses the literal - it wrote `WHERE o.status = 'complete'` against
/// data holding 'completed'. That SQL COMPILES and returns ZERO ROWS, and the
/// deploy then reports success having loaded nothing. Telling the model the
/// actual values costs one bounded query per text column and removes the whole
/// class of error.
///
/// Bounded deliberately: DISTINCT over the first 400 rows only. These are
/// FOREIGN tables, so an unbounded DISTINCT is a full remote scan per column,
/// and this runs inside the demo's most latency-sensitive step. A genuinely
/// low-cardinality column shows all its values in the first 400 rows; a
/// high-cardinality one exceeds the cap and is skipped, which is the intent.
ClassMethod EnumOf(table As %String, column As %String, type As %String) As %String [ Internal ]
{
    Try {
        If '$ListFind($ListBuild("varchar", "character varying", "char", "nvarchar"), $ZConvert(type, "L")) {
            Return ""
        }
        If '##class(ETLWizard.Tools.Util).ValidIdent(column) {
            Return ""
        }
        // No TOP, and no derived table: over a FOREIGN table both
        // "SELECT DISTINCT TOP n col FROM ft" and
        // "SELECT DISTINCT col FROM (SELECT TOP n col FROM ft) x"
        // return ZERO rows, while the plain DISTINCT returns the values.
        // Measured. The cap is applied while reading instead, which also stops
        // a high-cardinality column early rather than materialising it.
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT DISTINCT " _ column _ " FROM ETLWIZARD." _ table _
            " WHERE " _ column _ " IS NOT NULL")
        If '$IsObject(rs) {
            Return ""
        }
        Set vals = "", n = 0
        While rs.%Next() {
            Set v = rs.%GetData(1)
            // a value that is long or free-text is not an enumeration
            If $Length(v) > 24 {
                Return ""
            }
            Set n = n + 1
            // past the cap this is not an enumeration - stop reading rather
            // than walk the whole remote table
            If n > 6 {
                Return ""
            }
            Set vals = vals _ $Select(vals = "": "", 1: "|") _ v
        }
        If n = 0 {
            Return ""
        }
        Return " in (" _ vals _ ")"
    } Catch {
        Return ""
    }
}

ClassMethod ColumnsOf(table As %String) As %String [ Internal ]
{
    Set out = ""
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        If '$$$ISOK(stmt.%Prepare("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'ETLWIZARD' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")) {
            Return ""
        }
        Set rs = stmt.%Execute(table)
        Set n = 0
        While rs.%Next() {
            If n >= ..#MAXCOLS {
                Quit
            }
            Set col = rs.%GetData(1), type = rs.%GetData(2)
            Set out = out _ $Select(out = "": "", 1: ", ") _ col _ " " _ type _ ..EnumOf(table, col, type)
            Set n = n + 1
        }
    } Catch {
    }
    Return out
}

/// Generate (or refine) a transform SELECT from business logic in plain words.
/// currentSql, when supplied, is the statement to ADJUST — this is what makes
/// multi-prompt refinement work.
/// Returns JSON: {"sql":..., "valid":0|1, "error":..., "columnDefs":...}
ClassMethod Generate(runId As %String, instruction As %String, currentSql As %String = "", tables As %String = "") As %String
{
    Try {
        If $ZStrip(instruction, "<>W") = "" {
            Return "ERROR: describe what the transformation should do"
        }
        Set schema = ..SchemaContext(runId, tables)
        If schema = "" {
            Return "ERROR: no foreign tables are mounted yet - mount at least one source first"
        }

        // SQL generation gets its OWN profile when one exists
        // (AI.LLM.ETLWizardSqlGen), falling back to the architect's profile.
        // Reason: a big reasoning model is a poor fit here — it spends minutes
        // in a hidden <think> channel. A small code model answers in seconds.
        // Switching is a Config Store change, no code change:
        //   do ##class(ETLWizard.Setup).ConfigureSqlGenProfile("qwen2.5-coder:1.5b")
        Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizardSqlGen", .provider, .model)
        If $$$ISERR(sc) {
            Set sc = ##class(ETLWizard.Agent.ProviderFactory).GetProviderForConfig("ETLWizard", .provider, .model)
        }
        If $$$ISERR(sc) {
            Return "ERROR: LLM profile not configured (AI.LLM.ETLWizard): " _ $System.Status.GetErrorText(sc)
        }
        Set agent = ##class(%AI.Agent).%New(provider)
        If model '= "" {
            Set agent.Model = model
        }
        Set nl = $Char(10)
        // {joins} placeholder: the shared columns are the join keys. For a single
        // table there is nothing to join.
        Set joins = "(single table - no join needed)"
        If $Length(tables, ",") > 1 {
            Set pairs = ..JoinPairs(tables)
            Set joins = $Select(pairs '= "": pairs,
                                1: "Work out the join keys from the columns the tables share.")
        }
        // {tables} placeholder: the schema block, trailing newline trimmed so the
        // template controls the spacing.
        Set tablesBlock = $ZStrip(schema, ">W")
        Set agent.SystemPrompt =
            "You write ONE InterSystems IRIS SQL SELECT statement for an ETL transformation." _ nl _ nl _
            "Tables you may use:" _ nl _ tablesBlock _ nl _ nl _
            "Joins:" _ nl _ joins _ nl _ nl _
            "Rules:" _ nl _
            "- Allowed clauses: SELECT, FROM, JOIN, WHERE, GROUP BY, HAVING. One statement." _ nl _
            "- Table names include the schema: ETLWIZARD.<table_name> AS <alias>." _ nl _
            "- Alias every table. Qualify every column with its alias (c.customer_id," _ nl _
            "  never bare customer_id)." _ nl _
            "- Filters on raw column values go in WHERE." _ nl _
            "  Filters on aggregates (SUM, COUNT, AVG) go in HAVING." _ nl _
            "- Every aggregated or computed column gets an AS alias." _ nl _
            "- Use the fewest tables that answer the request. Join only when the request" _ nl _
            "  needs columns from both." _ nl _
            "- Cleansing: COALESCE, UPPER, TRIM, CASE. Aggregation: GROUP BY." _ nl _
            "- This is InterSystems IRIS SQL, not PostgreSQL or MySQL. Cast with" _ nl _
            "  CAST(expr AS type), never expr::type. Row limit is TOP n, never LIMIT." _ nl _
            "- A column may only be qualified by a table that actually lists it above." _ nl _
            "- No ORDER BY. Output is loaded into a table." _ nl _
            "- Output only the SQL. No prose, no markdown fences." _ nl _ nl _
            "When given an existing SQL and an adjustment request:" _ nl _
            "- Return the complete statement, not a diff." _ nl _
            "- Keep every existing column, join, and filter unless the request changes it." _ nl _
            "- ""also add"" means add to what is there." _ nl _ nl _
            "Example shape:" _ nl _
            "SELECT c.customer_id, c.name, SUM(o.amount) AS total_spent" _ nl _
            "FROM ETLWIZARD.ext_customer AS c" _ nl _
            "JOIN ETLWIZARD.ext_orders AS o ON c.customer_id = o.customer_id" _ nl _
            "WHERE o.status = 'paid'" _ nl _
            "GROUP BY c.customer_id, c.name" _ nl _
            "HAVING SUM(o.amount) > 100"

        // "/no_think" switches qwen3-family models out of reasoning mode: without
        // it the model spends most of its decode budget on a <think> block, which
        // is very slow on a local GPU. Harmless text for other models.
        Set prompt = "/no_think" _ nl _ "Business logic: " _ instruction
        If $ZStrip(currentSql, "<>W") '= "" {
            Set prompt = "/no_think" _ nl _ "Current SQL:" _ nl _ currentSql _ nl _ nl _
                "Adjust the SQL above to satisfy this request: " _ instruction _ nl _
                "Return the complete adjusted SELECT."
        }
        // Generate, validate (prepare + bounded execute), and AUTO-REPAIR: when
        // the SQL does not compile/run, feed the exact error back to the model in
        // the same session and ask for a fix, up to MAXREPAIR times. Small models
        // slip on identifiers and clause placement; a targeted retry with the real
        // error corrects most of it without bothering the user.
        Set session = agent.CreateSession()
        Set sql = "", lastErr = ""
        For attempt = 0:1:..#MAXREPAIR {
            If attempt = 0 {
                Set turn = prompt
            } Else {
                // Turn a bare "Field 'F.REGION_NAME' not found" into an actionable
                // fix by telling the model which table actually has the column.
                Set colHint = ..RepairHint(lastErr)
                Set turn = "/no_think" _ nl _
                    "This SQL failed:" _ nl _ sql _ nl _ nl _
                    "Error: " _ lastErr _
                    $Select(colHint '= "": nl _ "Hint: " _ colHint, 1: "") _ nl _
                    "Fix it and return the complete corrected SELECT. Output only the SQL."
            }
            Set response = agent.Chat(session, turn)
            Set raw = $Select($IsObject(response): response.Content, 1: "")
            Set candidate = ..CleanSql(raw)
            If candidate = "" {
                Set lastErr = "the model did not return a SELECT statement"
                Continue
            }
            // Deterministic pre-repair: fix the most common Postgres-ism the model
            // reaches for (expr::type) BEFORE validating, so it usually never even
            // costs a repair round.
            Set candidate = ..RewriteCasts(candidate)
            Set candidate = ##class(ETLWizard.Tools.Util).StripSqlComments(candidate)
            Set sql = candidate
            Set lastErr = ..Validate(sql, .ddlDefs, .colList)
            If lastErr = "" {
                Set out = {}
                Set out.sql = sql
                Set out.valid = 1
                Set out.columnDefs = ddlDefs
                Set out.attempts = attempt + 1
                Return out.%ToJSON()
            }
        }
        // Exhausted the repair budget — hand back the last attempt and its error
        // so the user can refine by hand (the UI keeps the manual-refine path).
        If sql = "" {
            Return "ERROR: the model did not return a SELECT statement. Try rephrasing."
        }
        Set out = {}
        Set out.sql = sql
        Set out.valid = 0
        Set out.error = lastErr
        Set out.attempts = ..#MAXREPAIR + 1
        Return out.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Validate a transform SELECT the way it will actually be used: PREPARE it to
/// derive the result columns (ddlDefs/colList by ref), then EXECUTE it bounded
/// (fetch one row) to catch errors that only surface at run time — a bad cast,
/// an ambiguous column, a function the source rejects. Returns "" if the SQL is
/// good, or the error message to feed back to the model for repair.
ClassMethod Validate(sql As %String, Output ddlDefs As %String, Output colList As %String) As %String [ Internal ]
{
    Set ddlDefs = "", colList = ""
    // 1) prepare + result-set metadata -> the columns the target table is built from
    Set err = ##class(ETLWizard.Tools.Util).GetSelectColumns(sql, .ddlDefs, .colList)
    If err '= "" {
        Return err
    }
    // 2) bounded execute — run it and pull a single row so runtime evaluation fires
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) {
            Return "ERROR executing: " _ $System.Status.GetErrorText(sc)
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Return "ERROR executing (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
        Do rs.%Next()
        If rs.%SQLCODE < 0 {
            Return "ERROR executing (SQLCODE " _ rs.%SQLCODE _ "): " _ rs.%Message
        }
    } Catch ex {
        Return "ERROR executing: " _ ex.DisplayString()
    }
    Return ""
}

/// Build a repair hint from a prepare/execute error. For every "Field 'X.COL'
/// not found" the SQL got wrong, look up which ETLWIZARD table actually lists
/// COL and say so — turning a dead-end error into a concrete fix the model can
/// apply (the wrong-alias mistake it cannot otherwise self-correct).
ClassMethod RepairHint(err As %String) As %String [ Internal ]
{
    Set hint = ""
    Try {
        Set rest = err
        Kill done
        For {
            Set pos = $Find(rest, "Field '")
            Quit:pos=0
            Set rest = $Extract(rest, pos, *)   // starts at "X.COL'..."
            Set fld = $Piece(rest, "'", 1)      // X.COL  (or just COL)
            Set rest = $Piece(rest, "'", 2, *)
            Set col = $Piece(fld, ".", *)       // strip the alias prefix
            If col = "" {
                Continue
            }
            Set colU = $ZConvert(col, "U")
            If $Data(done(colU)) {
                Continue
            }
            Set done(colU) = ""
            Set where = ..LocateColumn(col)
            If where '= "" {
                Set hint = hint _ $Select(hint = "": "", 1: " ") _
                    "Column " _ col _ " exists in " _ where _ " - qualify it with that table."
            }
        }
    } Catch {
    }
    Return hint
}

/// Which mounted ETLWIZARD tables list a column of this name (comma-separated,
/// schema-qualified), or "" if none.
ClassMethod LocateColumn(col As %String) As %String [ Internal ]
{
    Set out = ""
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        If $$$ISOK(stmt.%Prepare("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'ETLWIZARD' AND UPPER(COLUMN_NAME) = ? ORDER BY TABLE_NAME")) {
            Set rs = stmt.%Execute($ZConvert(col, "U"))
            While rs.%Next() {
                Set out = out _ $Select(out = "": "", 1: ", ") _ "ETLWIZARD." _ rs.%GetData(1)
            }
        }
    } Catch {
    }
    Return out
}

/// Suggest a primary key for the transform's result, so the strategy step can
/// prefill it alongside the load-strategy recommendation. Three tiers, cheapest
/// first — the goal is an instant answer for the common cases and the LLM only
/// as a last resort (so the strategy step never hangs on the local model):
///   1. GROUP BY present -> the grouping columns ARE the grain (one row per key).
///   2. Otherwise ask the agent to pick the minimal unique key from the result
///      columns (validated: the answer must be real result columns).
///   3. Otherwise a deterministic id-column heuristic.
/// Returns JSON {"primaryKey":..., "reason":..., "source":"groupby|agent|heuristic"}.
ClassMethod SuggestKey(runId As %String, sql As %String, tables As %String = "") As %String
{
    Set out = {}
    Set out.primaryKey = ""
    Set out.reason = ""
    Set out.source = ""
    Try {
        If $ZStrip(sql, "<>W") = "" {
            Return out.%ToJSON()
        }
        // Resolve the actual result columns (post-dedup names the load layer uses)
        Set err = ##class(ETLWizard.Tools.Util).GetSelectColumns(sql, .ddl, .colList)
        If err '= "" {
            Return out.%ToJSON()
        }
        // result column names, upper-cased, for validation
        Kill valid
        For i = 1:1:$Length(colList, ",") {
            Set c = $ZStrip($Piece(colList, ",", i), "<>W")
            If c '= "" {
                Set valid($ZConvert(c, "U")) = c
            }
        }

        // --- Tier 1: GROUP BY grain -----------------------------------------
        Set grp = ##class(ETLWizard.Tools.Util).GroupByColumns(sql)
        If grp '= "" {
            Set pk = ""
            For i = 1:1:$Length(grp, ",") {
                Set g = $ZStrip($Piece(grp, ",", i), "<>W")
                Set gu = $ZConvert(g, "U")
                If $Data(valid(gu)) {
                    Set pk = pk _ $Select(pk = "": "", 1: ", ") _ valid(gu)
                }
            }
            If pk '= "" {
                Set out.primaryKey = pk
                Set out.source = "groupby"
                Set out.reason = "aggregated result — one row per " _ pk
                Return out.%ToJSON()
            }
        }

        // --- Tier 2: ask the agent ------------------------------------------
        Set agentPk = ..AskKey(colList)
        If agentPk '= "" {
            // validate: every returned name must be a real result column
            Set ok = 1, pk = ""
            For i = 1:1:$Length(agentPk, ",") {
                Set a = $ZStrip($Piece(agentPk, ",", i), "<>W")
                Set au = $ZConvert($Piece(a, ".", *), "U")
                If $Data(valid(au)) {
                    Set pk = pk _ $Select(pk = "": "", 1: ", ") _ valid(au)
                } Else {
                    Set ok = 0
                }
            }
            If ok && (pk '= "") {
                Set out.primaryKey = pk
                Set out.source = "agent"
                Set out.reason = "the agent identified " _ pk _ " as the unique key"
                Return out.%ToJSON()
            }
        }

        // --- Tier 3: id-column heuristic ------------------------------------
        Set guess = ""
        For i = 1:1:$Length(colList, ",") {
            Set c = $ZStrip($Piece(colList, ",", i), "<>W")
            Set cl = $ZConvert(c, "L")
            If (cl = "id") || ($Extract(cl, *-2, *) = "_id") {
                Set guess = c
                Quit
            }
        }
        If guess '= "" {
            Set out.primaryKey = guess
            Set out.source = "heuristic"
            Set out.reason = guess _ " looks like the row identifier"
        }
        Return out.%ToJSON()
    } Catch ex {
        Return out.%ToJSON()
    }
}

/// Single-shot LLM call: given the result column names, return the minimal set
/// that uniquely identifies a row. Returns "" if unavailable or unanswered.
/// Kept tiny (one line of output) so even a small local model replies quickly.
ClassMethod AskKey(colList As %String) As %String [ Internal ]
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
            "You pick the PRIMARY KEY of a query result." _ nl _
            "Given a list of result column names, answer with the SMALLEST set of" _ nl _
            "columns that uniquely identifies one row." _ nl _
            "Rules:" _ nl _
            "- Answer with ONLY column names from the list, comma-separated." _ nl _
            "- No prose, no explanation, no markdown. Usually one column." _ nl _
            "- Prefer an id column when present."
        Set prompt = "/no_think" _ nl _ "Result columns: " _ colList _ nl _ "Primary key:"
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, prompt)
        Set raw = ""
        If $IsObject(response) {
            Set raw = response.Content
        }
        // strip any <think> preamble and fences, keep the last non-empty line
        If raw [ "</think>" {
            Set raw = $Piece(raw, "</think>", 2, *)
        }
        Set raw = $Replace($Replace(raw, "`", ""), """", "")
        Set ans = ""
        For i = 1:1:$Length(raw, nl) {
            Set line = $ZStrip($Piece(raw, nl, i), "<>W")
            If line '= "" {
                Set ans = line
            }
        }
        // drop a leading "Primary key:" label if the model echoed it
        If $ZConvert(ans, "L") [ "key:" {
            Set ans = $ZStrip($Piece(ans, ":", 2, *), "<>W")
        }
        Return ans
    } Catch {
        Return ""
    }
}

/// Background entry point (JOBbed by the REST layer). A local model can take
/// well over the web gateway's request timeout, so generation never blocks an
/// HTTP request: the result is published to the run's event log as
/// `sqlgen.result`, which the canvas already polls — the SQL lands in the
/// editor as soon as the model finishes.
ClassMethod GenerateAsync(runId As %String, instruction As %String, currentSql As %String = "", tables As %String = "") As %Status
{
    Try {
        Do ##class(ETLWizard.Model.Event).Append(runId, "sqlgen.started", "",
            {"instruction": (instruction)})
        Set res = ..Generate(runId, instruction, currentSql, tables)
        If $Extract(res, 1, 5) = "ERROR" {
            Do ##class(ETLWizard.Model.Event).Append(runId, "sqlgen.result", "",
                {"ok": 0, "error": (res), "instruction": (instruction)})
        } Else {
            Set obj = ##class(%DynamicObject).%FromJSON(res)
            Set obj.ok = 1
            Set obj.instruction = instruction
            Do ##class(ETLWizard.Model.Event).Append(runId, "sqlgen.result", "", obj)
        }
    } Catch ex {
        Do ##class(ETLWizard.Model.Event).Append(runId, "sqlgen.result", "",
            {"ok": 0, "error": ("ERROR: " _ ex.DisplayString())})
    }
    Return $$$OK
}

/// Strip markdown fences / prose and keep the SELECT statement.
ClassMethod CleanSql(raw As %String) As %String [ Internal ]
{
    Set s = raw
    // drop code fences
    Set s = $Replace(s, "```sql", "")
    Set s = $Replace(s, "```SQL", "")
    Set s = $Replace(s, "```", "")
    // some small models emit <think>...</think> preamble
    If s [ "</think>" {
        Set s = $Piece(s, "</think>", 2, *)
    }
    // keep from the first SELECT onwards
    Set up = $ZConvert(s, "U")
    Set pos = $Find(up, "SELECT")
    If pos = 0 {
        Return ""
    }
    Set s = $Extract(s, pos - 6, *)
    Set s = $ZStrip(s, "<>W")
    // one statement: cut at the first semicolon
    If s [ ";" {
        Set s = $Piece(s, ";", 1)
    }
    Return $ZStrip(s, "<>W")
}

/// Deterministically rewrite PostgreSQL casts  expr::type  ->  CAST(expr AS type),
/// the single most common non-IRIS token the model emits (e.g. ordered_at::date).
/// The left operand is either a balanced (...) group or an identifier/dotted/quoted
/// token; the right type is a word with an optional (precision[,scale]). Bounded
/// loop, and any "::" it cannot parse is neutralised so it can never spin.
ClassMethod RewriteCasts(sql As %String) As %String [ Internal ]
{
    Set out = sql
    For pass = 1:1:64 {
        Set pos = $Find(out, "::")       // position just AFTER the "::"
        Quit:pos=0
        Set colonAt = pos - 2            // index of the first ':'
        Set len = $Length(out)

        // --- type on the right ---
        Set i = pos
        While (i <= len) && ($Extract(out, i) = " ") { Set i = i + 1 }
        Set typeStart = i
        While (i <= len) && ($Extract(out, i)?1(1A,1N,1"_")) { Set i = i + 1 }
        Set type = $Extract(out, typeStart, i - 1)
        If type = "" {
            // not a cast we understand — drop the "::" so the loop makes progress
            Set out = $Extract(out, 1, colonAt - 1) _ " " _ $Extract(out, pos, *)
            Continue
        }
        // optional (precision[,scale])
        If $Extract(out, i) = "(" {
            Set depth = 0, j = i
            While j <= len {
                Set ch = $Extract(out, j)
                If ch = "(" { Set depth = depth + 1 }
                ElseIf ch = ")" { Set depth = depth - 1  If depth = 0 { Set j = j + 1  Quit } }
                Set j = j + 1
            }
            Set type = type _ $Extract(out, i, j - 1)
            Set i = j
        }
        Set typeEnd = i - 1

        // --- operand on the left ---
        Set k = colonAt - 1
        While (k >= 1) && ($Extract(out, k) = " ") { Set k = k - 1 }
        Set opEnd = k
        If $Extract(out, k) = ")" {
            Set depth = 0
            While k >= 1 {
                Set ch = $Extract(out, k)
                If ch = ")" { Set depth = depth + 1 }
                ElseIf ch = "(" { Set depth = depth - 1  If depth = 0 { Quit } }
                Set k = k - 1
            }
            Set opStart = k
        } ElseIf $Extract(out, k) = "'" {
            Set k = k - 1
            While (k >= 1) && ($Extract(out, k) '= "'") { Set k = k - 1 }
            Set opStart = k
        } Else {
            While (k >= 1) && ($Extract(out, k)?1(1A,1N,1"_",1".")) { Set k = k - 1 }
            Set opStart = k + 1
        }
        Set operand = $Extract(out, opStart, opEnd)
        If operand = "" {
            Set out = $Extract(out, 1, colonAt - 1) _ " " _ $Extract(out, pos, *)
            Continue
        }
        Set out = $Extract(out, 1, opStart - 1) _ "CAST(" _ operand _ " AS " _ type _ ")" _ $Extract(out, typeEnd + 1, *)
    }
    Return out
}

}
