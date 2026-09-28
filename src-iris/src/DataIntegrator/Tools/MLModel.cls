/// IntegratedML wrapper for the ML Models tab (see ml-models-tab-plan.md).
///
/// Deliberately stores NOTHING of its own: every read comes straight from
/// INFORMATION_SCHEMA.ML_* , which IRIS maintains as models are created,
/// trained and validated. That keeps the tab from ever disagreeing with the
/// engine, and means the derived flowchart (Graph()) is rebuilt from live
/// state rather than a snapshot that could go stale.
///
/// AutoML is the only provider usable on this image; see ml-models-tab-plan.md
/// §2 for the install and its two traps (root/chown, durable %SYS).
Class DataIntegrator.Tools.MLModel Extends %RegisteredObject
{

/// Models with their trained/validated state, for the picker.
ClassMethod ListModels() As %DynamicArray
{
    Set out = []
    Try {
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT MODEL_NAME, PREDICTING_COLUMN_NAME, PREDICTING_COLUMN_TYPE, "_
            "WITH_COLUMNS, DEFAULT_TRAINED_MODEL_NAME, DEFAULT_TRAINING_QUERY "_
            "FROM INFORMATION_SCHEMA.ML_MODELS ORDER BY MODEL_NAME")
        While rs.%Next() {
            Set name = rs.%GetData(1)
            Set trained = rs.%GetData(5)
            Do out.%Push({
                "name": (name),
                "target": (rs.%GetData(2)),
                "targetType": (rs.%GetData(3)),
                "withColumns": (rs.%GetData(4)),
                "trainedModel": (trained),
                "trainingQuery": (rs.%GetData(6)),
                "trained": (''(trained '= "")),
                "validated": (..HasValidation(name)),
                "timeSeries": (..IsTimeSeries(name))
            })
        }
    } Catch ex {
    }
    Return out
}

/// A model is time series if its trained model reports that type. Before the
/// first training there is nothing to read it from, so fall back to 0.
ClassMethod IsTimeSeries(name As %String) As %Boolean
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP 1 MODEL_TYPE FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS WHERE MODEL_NAME = ?")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Return ($ZConvert(rs.%GetData(1), "L") = "timeseries")
            }
        }
    } Catch ex {
    }
    Return 0
}

ClassMethod HasValidation(name As %String) As %Boolean
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT COUNT(*) FROM INFORMATION_SCHEMA.ML_VALIDATION_RUNS WHERE MODEL_NAME = ?")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Return (+rs.%GetData(1) > 0)
            }
        }
    } Catch ex {
    }
    Return 0
}

/// Columns of an DATAINTEGRATOR table, with the date/time ones flagged so the
/// frontend can restrict the time-column picker (plan §9).
ClassMethod TableColumns(table As %String) As %DynamicArray
{
    Set out = []
    Try {
        // Honour the schema the caller actually named. This was pinned to
        // 'DATAINTEGRATOR', so a model could only ever be built over a mounted
        // foreign table - asking for ETLW_TARGET.<result> returned an empty
        // column list and the ML step silently offered nothing to predict.
        // The wizard's own target IS the table worth training on.
        Set bare = $Piece(table, ".", *)
        Set schema = $Select(table [ ".": $Piece(table, ".", 1), 1: "DATAINTEGRATOR")
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS "_
                                 "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(schema, bare)
            While rs.%Next() {
                Set type = $ZConvert(rs.%GetData(2), "L")
                Set isTime = ((type [ "date") || (type [ "time"))
                Do out.%Push({"name": (rs.%GetData(1)), "type": (type), "temporal": (''isTime)})
            }
        }
    } Catch ex {
    }
    Return out
}

/// Guard for the time-series BY column (plan §8/§9). AutoML infers the sampling
/// frequency from the median gap between consecutive values; when that comes
/// out 0 it builds a zero-length interval and training dies with a bare
/// "ZeroDivisionError: integer division or modulo by zero" that names neither
/// the column nor the reason. Catch the three data shapes that cause it here,
/// where we can say something useful.
ClassMethod CheckTimeColumn(table As %String, column As %String, Output problem As %String) As %Boolean
{
    Set problem = ""
    Try {
        // 1. must be a date/time type - an integer id yields freq 0
        Set cols = ..TableColumns(table)
        Set found = 0
        Set iter = cols.%GetIterator()
        While iter.%GetNext(, .col) {
            If col.name = column {
                Set found = 1
                If 'col.temporal {
                    Set problem = "'" _ column _ "' is " _ col.type _ ", not a date/time column. "_
                                  "AutoML infers the interval from this column; a non-temporal one gives an interval of zero."
                    Return 0
                }
                Quit
            }
        }
        If 'found {
            Set problem = "column '" _ column _ "' not found on " _ table
            Return 0
        }
        // 2. duplicates collapse the median gap to zero
        Set rs = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COUNT(*), COUNT(DISTINCT " _ column _ ") FROM " _ table)
        If rs.%Next() {
            Set total = +rs.%GetData(1)
            Set distinct = +rs.%GetData(2)
            If distinct < 3 {
                Set problem = "only " _ distinct _ " distinct value(s) in '" _ column _ "' - "_
                              "not enough to infer a sampling interval."
                Return 0
            }
            If total > distinct {
                Set problem = table _ " has " _ total _ " rows but only " _ distinct _ " distinct '"_
                              column _ "' values. Several rows share a timestamp, which makes the "_
                              "inferred interval zero - aggregate to one row per period first."
                Return 0
            }
        }
    } Catch ex {
        Set problem = ex.DisplayString()
        Return 0
    }
    Return 1
}

/// Merge caller settings into a USING clause. Returns "" when there is nothing
/// to say, so the DDL stays clean for the simple case.
///
/// IntegratedML takes USING as a JSON object on both CREATE and TRAIN. The two
/// are not the same thing: CREATE stores a *default* USING on the model
/// definition, and a USING on TRAIN overrides those same keys for that one run.
/// Model selection belongs on CREATE (it defines what the model IS); run knobs
/// like seed belong on TRAIN.
ClassMethod UsingClause(settings As %DynamicObject) As %String
{
    If '$IsObject(settings) {
        Return ""
    }
    // Every value that reaches here is a string: the frontend's form inputs are
    // strings, and DefinitionSettings() parses DEFAULT_SETTINGS out of a text
    // column. %ToJSON() then quotes them, so AutoML received {"forward": "24"}
    // and its Python compared a str to an int:
    //   TypeError: '>' not supported between instances of 'str' and 'int'
    // Re-emit anything that is canonically a number as a JSON number. The test
    // is on the value, not the key, so "1H" for frequency and "time" for
    // trainmode still go out quoted, and a value like "007" stays a string
    // rather than being silently renumbered to 7.
    Set out = {}, any = 0
    Set it = settings.%GetIterator()
    While it.%GetNext(.k, .v) {
        Set any = 1
        If (v '= ""), $IsValidNum(v), (v = +v) {
            Do out.%Set(k, +v, "number")
        } Else {
            Do out.%Set(k, v)
        }
    }
    If 'any {
        Return ""
    }
    Return " USING " _ out.%ToJSON()
}

/// CREATE MODEL / CREATE TIME SERIES MODEL.
/// timeColumn non-empty selects the time-series form; using carries the model
/// definition's default USING settings (custom model selection, IsRegression,
/// the time-series forward/backward/frequency knobs).
ClassMethod Create(name As %String, table As %String, target As %String, withColumns As %String = "", timeColumn As %String = "", using As %DynamicObject = "", Output error As %String) As %Boolean
{
    Set error = ""
    Try {
        If timeColumn '= "" {
            If '..CheckTimeColumn(table, timeColumn, .problem) {
                Set error = problem
                Return 0
            }
            Set ddl = "CREATE TIME SERIES MODEL " _ name _ " PREDICTING (" _ target _ ") BY (" _ timeColumn _ ")"
        } Else {
            Set ddl = "CREATE MODEL " _ name _ " PREDICTING (" _ target _ ")"
        }
        If withColumns '= "" {
            Set ddl = ddl _ " WITH (" _ withColumns _ ")"
        }
        Set ddl = ddl _ " FROM " _ table _ ..UsingClause(using)
        Set rs = ##class(%SQL.Statement).%ExecDirect(, ddl)
        If rs.%SQLCODE < 0 {
            Set error = ..Explain(rs.%SQLCODE, rs.%Message)
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

/// Create one model per target column.
///
/// PREDICTING takes exactly ONE column - "PREDICTING (a, b)" is a parse error
/// on this build, and AutoML's train() signature is singular (label_column), so
/// a multi-label model is not something the engine can express. Predicting
/// several columns therefore means several models, named <base>_<column>, and
/// this is where that fans out. Returns one result row per column so the caller
/// can report the failures alongside the successes instead of stopping at the
/// first one.
ClassMethod CreateBatch(baseName As %String, table As %String, targets As %DynamicArray, withColumns As %String = "", timeColumn As %String = "", using As %DynamicObject = "") As %DynamicArray
{
    Set out = []
    Try {
        Set single = (targets.%Size() = 1)
        Set it = targets.%GetIterator()
        While it.%GetNext(.i, .target) {
            // one target keeps the name the user typed; several get suffixed so
            // each model is still identifiable in the picker
            Set name = $Select(single: baseName, 1: baseName _ "_" _ target)
            Set ok = ..Create(name, table, target, withColumns, timeColumn, using, .error)
            Do out.%Push({"name": (name), "target": (target), "ok": (''ok), "error": (error)})
        }
    } Catch ex {
        Do out.%Push({"name": (baseName), "target": "", "ok": 0, "error": (ex.DisplayString())})
    }
    Return out
}

/// The USING settings stored on a model definition, read back from
/// INFORMATION_SCHEMA.ML_MODELS.DEFAULT_SETTINGS.
///
/// DEFAULT_SETTINGS is rendered as "key:value, key:value" (keys lower-cased by
/// the provider), which is why this parses rather than reads JSON. Only the
/// first colon separates - values are paths and contain none, but splitting on
/// $Piece(...,":",2,*) keeps a value with one intact.
ClassMethod DefinitionSettings(name As %String) As %DynamicObject
{
    Set out = {}
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT DEFAULT_SETTINGS FROM INFORMATION_SCHEMA.ML_MODELS WHERE MODEL_NAME = ?")
        If $$$ISERR(sc) {
            Return out
        }
        Set rs = stmt.%Execute(name)
        If 'rs.%Next() {
            Return out
        }
        Set raw = rs.%GetData(1)
        If raw = "" {
            Return out
        }
        For i = 1:1:$Length(raw, ",") {
            Set pair = $ZStrip($Piece(raw, ",", i), "<>W")
            If pair = "" {
                Continue
            }
            Set key = $ZStrip($Piece(pair, ":", 1), "<>W")
            Set value = $ZStrip($Piece(pair, ":", 2, *), "<>W")
            If key '= "" {
                Do out.%Set(key, value)
            }
        }
    } Catch ex {
    }
    Return out
}

/// %ML builds its pandas dataframe by formatting values through $FNUMBER, which
/// honours the process's NLS DecimalSeparator. This instance runs a Portuguese
/// locale, where that separator is a comma, so 18.8 is handed to Python as
/// "18,8000" and the dataframe build dies with
///   ValueError: could not convert string to float: '18,8000'
/// (wrapped as "ERROR #2802: %ML cannot create dataframe").
///
/// Python's float() only ever accepts a dot, so a comma separator can never be
/// right on this path. Force a dot around any call that builds a dataframe and
/// put the process's own separator back afterwards - the setting is
/// process-scoped, and a web process serves other requests after this one.
/// Returns the previous separator so the caller can restore it.
ClassMethod DecimalPoint(sep As %String = ".") As %String [ Internal ]
{
    Set old = ""
    Try {
        Set fmt = ##class(%SYS.NLS.Format).%New("current")
        Set old = fmt.DecimalSeparator
        If (sep '= ""), (sep '= old) {
            Set fmt.DecimalSeparator = sep
        }
    } Catch ex {
    }
    Return old
}

/// Kick off training in a background job and return at once.
///
/// Training routinely outlives the Web Gateway's response timeout, and a
/// gateway cut arrives at the browser as an EMPTY body - the same failure that
/// produced "JSON.parse: unexpected end of data" in the index advisor. Since
/// ML_TRAINING_RUNS.RUN_STATUS is queryable WHILE the run is in flight, the
/// frontend polls Status() instead of holding a request open.
///
/// The definition's USING is merged in here, with the caller's training
/// parameters winning on any key they share. That is the behaviour the
/// documentation describes ("parameters in the USING clause of your ML
/// configuration overwrite those same parameters in the USING clause of your
/// model definition"), applied on our side so it holds however the provider
/// chooses to treat a TRAIN-time clause.
ClassMethod TrainAsync(name As %String, table As %String = "", using As %DynamicObject = "", Output error As %String) As %Boolean
{
    Set error = ""
    Try {
        Set merged = ..DefinitionSettings(name)
        If $IsObject(using) {
            Set it = using.%GetIterator()
            While it.%GetNext(.k, .v) {
                Do merged.%Set(k, v)
            }
        }
        // the JOB takes the clause already rendered: a %DynamicObject cannot be
        // passed across the job boundary, only strings can
        Set clause = ..UsingClause(merged)
        // JOB only sets $TEST when a timeout is supplied; without one the
        // check below always fails even though the job started fine.
        Job ##class(DataIntegrator.Tools.MLModel).TrainJob(name, table, clause)::5
        If '$Test {
            Set error = "could not start the training job"
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

/// Body of the background training job. Errors are not thrown anywhere useful
/// from a JOB, so they are left for Status() to read out of ML_TRAINING_RUNS.
ClassMethod TrainJob(name As %String, table As %String = "", usingClause As %String = "")
{
    Set prev = ..DecimalPoint()
    Try {
        Set sql = "TRAIN MODEL " _ name
        If table '= "" {
            Set sql = sql _ " FROM " _ table
        }
        Do ##class(%SQL.Statement).%ExecDirect(, sql _ usingClause)
    } Catch ex {
    }
    Do ..DecimalPoint(prev)
    Quit
}

/// Latest training run for a model: status, duration, and the failure text.
/// Turn ML_TRAINING_RUNS.STATUS_CODE into something a person can read.
///
/// On a failure that column does not hold a code - it holds a serialised
/// %Status, complete with the exception class, the message, a stack trace and
/// embedded NUL bytes. Handing that to the browser verbatim put NULs in the
/// JSON body, which is not parseable: the frontend then reported "unexpected
/// non-JSON response" and, because that path alerts, blocked the whole page
/// mid-batch. So decode it, and strip anything non-printable that survives.
ClassMethod CleanStatus(code As %String) As %String
{
    Set text = code
    Try {
        // a serialised %Status decodes to "ERROR #nnnn: ..."; anything else
        // (a plain integer code, say) is left as it is
        If $System.Status.IsError(code) {
            Set text = $System.Status.GetErrorText(code)
        }
    } Catch ex {
    }
    // whatever came back, only printable characters may reach the JSON body
    Set out = ""
    For i = 1:1:$Length(text) {
        Set ch = $Extract(text, i)
        Set out = out _ $Select($Ascii(ch) < 32: " ", 1: ch)
    }
    Set out = $ZStrip(out, "<>W")
    // the stack trace behind the message is noise for a wizard user
    Return $Extract(out, 1, 300)
}

ClassMethod Status(name As %String) As %DynamicObject
{
    Set out = {"status": "none", "duration": "", "provider": "", "error": ""}
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP 1 RUN_STATUS, TRAINING_DURATION, PROVIDER, STATUS_CODE "_
                                 "FROM INFORMATION_SCHEMA.ML_TRAINING_RUNS WHERE MODEL_NAME = ? "_
                                 "ORDER BY START_TIMESTAMP DESC")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Set out.status = $ZConvert(rs.%GetData(1), "L")
                Set out.duration = rs.%GetData(2)
                Set out.provider = rs.%GetData(3)
                Set code = rs.%GetData(4)
                If (out.status = "failed"), code '= "" {
                    Set out.error = ..Explain(code, ..CleanStatus(code))
                }
                // "canceled/terminated" is not a failure IRIS can describe: the
                // training process was killed, so it never wrote a STATUS_CODE
                // and never wrote a TRAINING_DURATION. Before this arm the tab
                // showed the bare status with an empty error and there was
                // nothing on screen to act on. The cause is practically always
                // the AutoTS ensemble exhausting the host's memory on a long
                // series - it peaks near 9.5 GB at ~88k hourly rows, and grows
                // faster than linearly from there - so say that.
                If out.status [ "terminated", out.error = "" {
                    Set out.error = ..TerminatedHint(name)
                }
            }
        }
        Set out.trainedModel = ..TrainedName(name)
        Set out.modelInfo = ..ModelInfo(name)
    } Catch ex {
        Set out.error = ex.DisplayString()
    }
    Return out
}

/// What to tell a user whose training process was killed. Names the row count
/// when the definition's training table can be read, because the row count is
/// the knob that matters: the fix is a shorter or coarser series, not a
/// different setting.
ClassMethod TerminatedHint(name As %String) As %String [ Internal ]
{
    Set rows = ""
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT DEFAULT_TRAINING_QUERY FROM INFORMATION_SCHEMA.ML_MODELS WHERE MODEL_NAME = ?")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                // "SELECT * FROM  DATAINTEGRATOR . ext_x" - IRIS pads the dots
                Set query = rs.%GetData(1)
                Set table = $ZStrip($Piece(query, " FROM ", 2), "<>W")
                If table '= "" {
                    Set table = $Replace($Replace(table, " . ", "."), " ", "")
                    Set cnt = ##class(%SQL.Statement).%ExecDirect(, "SELECT COUNT(*) FROM " _ table)
                    If cnt.%Next() {
                        Set rows = cnt.%GetData(1)
                    }
                }
            }
        }
    } Catch ex {
    }
    Set hint = "the training process was killed before it could report anything"
    If rows '= "" {
        Set hint = hint _ " - " _ rows _ " rows"
    }
    Return hint _ ". This is almost always the AutoTS ensemble running the host "_
           "out of memory: it needs roughly 9.5 GB at 88,000 hourly rows and more "_
           "than linearly beyond that. Train on a shorter window, or aggregate to "_
           "one row per day instead of per hour."
}

ClassMethod TrainedName(name As %String) As %String
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT DEFAULT_TRAINED_MODEL_NAME FROM INFORMATION_SCHEMA.ML_MODELS WHERE MODEL_NAME = ?")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Return rs.%GetData(1)
            }
        }
    } Catch ex {
    }
    Return ""
}

/// e.g. "ModelType:Logistic Regression, Package:sklearn, ProblemType:classification"
ClassMethod ModelInfo(name As %String) As %String
{
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT TOP 1 MODEL_INFO FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS "_
                                 "WHERE MODEL_NAME = ? ORDER BY TRAINED_TIMESTAMP DESC")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name)
            If rs.%Next() {
                Return rs.%GetData(1)
            }
        }
    } Catch ex {
    }
    Return ""
}

ClassMethod Validate(name As %String, table As %String, Output error As %String, Output excluded As %Integer) As %Boolean
{
    Set error = "", excluded = 0
    Set prev = ..DecimalPoint()
    Try {
        Set source = ..ScorableSource(name, table, .excluded)
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "VALIDATE MODEL " _ name _ " FROM " _ source)
        If rs.%SQLCODE < 0 {
            Set error = ..Explain(rs.%SQLCODE, rs.%Message)
            Do ..DecimalPoint(prev)
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Do ..DecimalPoint(prev)
        Return 0
    }
    Do ..DecimalPoint(prev)
    Return 1
}

/// The validation set with unlabelled rows removed, plus how many that was.
///
/// %ML.TrainedModel:%ValidateRegression() takes the target mean with AVG(),
/// which skips NULL, but then reads each row with %Get(), where a NULL comes
/// back as "" and arithmetic treats it as 0. Every unlabelled row therefore
/// contributes (0 - mean)^2 to BOTH the error sum and the variance sum. On
/// ext_t_2INMETSAOPAULO2024_clean, 984 of 8,784 rows (11%) have no temperature
/// reading, and the reported metrics came out
///     MSE 46.07  RMSE 6.79  Variance 66.92  R2 0.31
/// against a true
///     MSE  0.15  RMSE 0.39  Variance 22.96  R2 0.99
/// - the model looked barely predictive when it was near-exact. The giveaway is
/// Variance: 66.92 against a column whose actual variance is 22.96.
///
/// A row with no label cannot be scored, so dropping it is right for any model
/// type, not just a workaround for this arithmetic. %ML lives in IRISLIB, which
/// is mounted read-only, so the filter has to go here.
///
/// Falls back to the bare table when the predicting column cannot be read, so a
/// lookup failure costs the filter rather than the validation.
ClassMethod ScorableSource(name As %String, table As %String, Output excluded As %Integer) As %String
{
    Set excluded = 0
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare("SELECT PREDICTING_COLUMN_NAME FROM INFORMATION_SCHEMA.ML_MODELS WHERE MODEL_NAME = ?")
        If $$$ISERR(sc) {
            Return table
        }
        Set rs = stmt.%Execute(name)
        If 'rs.%Next() {
            Return table
        }
        // IRIS stores this qualified on some models; %ValidateRegression strips
        // it the same way before use
        Set target = rs.%GetData(1)
        Set:(target [ ".") target = $Piece(target, ".", 2)
        If '##class(DataIntegrator.Tools.Util).ValidIdent(target) {
            Return table
        }
        Set cnt = ##class(%SQL.Statement).%ExecDirect(,
            "SELECT COUNT(*) FROM " _ table _ " WHERE " _ target _ " IS NULL")
        If cnt.%Next() {
            Set excluded = +cnt.%GetData(1)
        }
        If excluded = 0 {
            Return table
        }
        Return "(SELECT * FROM " _ table _ " WHERE " _ target _ " IS NOT NULL)"
    } Catch ex {
        Set excluded = 0
    }
    Return table
}

/// Validation metrics of the most recent run. TARGET_VALUE is the class a
/// metric belongs to (blank for the overall figures).
ClassMethod Metrics(name As %String) As %DynamicArray
{
    Set out = []
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        // Scope to the LATEST validation run. ML_VALIDATION_METRICS keeps every
        // run's rows for the life of the model, so selecting on MODEL_NAME alone
        // returned one MSE per run ever made - validate a model twice and the
        // tab showed MSE, R2, RMSE and Variance two and three times over, with
        // no way to tell which figure was current.
        Set sc = stmt.%Prepare("SELECT METRIC_NAME, METRIC_VALUE, TARGET_VALUE "_
                                 "FROM INFORMATION_SCHEMA.ML_VALIDATION_METRICS "_
                                 "WHERE MODEL_NAME = ? AND VALIDATION_RUN_NAME = "_
                                 "(SELECT TOP 1 VALIDATION_RUN_NAME FROM INFORMATION_SCHEMA.ML_VALIDATION_RUNS "_
                                 "WHERE MODEL_NAME = ? ORDER BY START_TIMESTAMP DESC) "_
                                 "ORDER BY TARGET_VALUE, METRIC_NAME")
        If $$$ISOK(sc) {
            Set rs = stmt.%Execute(name, name)
            While rs.%Next() {
                Do out.%Push({"metric": (rs.%GetData(1)), "value": (rs.%GetData(2)), "class": (rs.%GetData(3))})
            }
        }
    } Catch ex {
    }
    Return out
}

/// PREDICT / PROBABILITY preview. forClass empty omits the probability column,
/// which is what regression and time-series models need.
ClassMethod Predict(name As %String, table As %String, forClass As %String = "", maxRows As %Integer = 10, Output error As %String) As %DynamicObject
{
    Set error = ""
    Set out = {"columns": [], "rows": [], "sql": "", "columnDefs": "", "sample": {"rows": []}}
    Set prev = ..DecimalPoint()
    Try {
        Set sel = "SELECT TOP " _ (+maxRows) _ " *, PREDICT(" _ name _ ") AS ml_prediction"
        If forClass '= "" {
            Set sel = sel _ ", PROBABILITY(" _ name _ " FOR '" _ forClass _ "') AS ml_probability"
        }
        Set sel = sel _ " FROM " _ table
        // hand the statement back so the step can show exactly what produced
        // the rows - and so a failure is debuggable from the UI
        Set out.sql = sel
        // %SelectMode 1 (ODBC), not the default 0 (logical) - the same reason
        // Util.RunSelect() sets it. In logical mode a %TimeStamp column reaches
        // the screen as 1154594035806846976, so the one column that says WHEN a
        // prediction applies was unreadable in this grid.
        Set stmt = ##class(%SQL.Statement).%New()
        Set stmt.%SelectMode = 1
        Set sc = stmt.%Prepare(sel)
        If $$$ISERR(sc) {
            Set error = $System.Status.GetErrorText(sc)
            Do ..DecimalPoint(prev)
            Return out
        }
        Set rs = stmt.%Execute()
        If rs.%SQLCODE < 0 {
            Set error = ..Explain(rs.%SQLCODE, rs.%Message)
            Do ..DecimalPoint(prev)
            Return out
        }
        Set meta = rs.%GetMetadata()
        // Two shapes of the same grid. columns/rows (names + positional arrays)
        // is what this has always returned. columnDefs/sample is the shape the
        // transform preview uses, which lets the predictions render through
        // renderPreviewTable() - the same styled, number-formatted table the
        // rest of the wizard shows - instead of a bare text grid.
        Set defs = ""
        Set names = ""
        For i = 1:1:meta.columnCount {
            Set col = meta.columns.GetAt(i)
            // SELECT *, PREDICT(...) can repeat a name when the table already
            // has an ml_prediction column. Object-keyed rows would lose one, so
            // make the duplicate distinct before it is used as a key.
            Set nm = col.colName
            If $ListFind($ListFromString(names, ","), nm) > 0 {
                Set nm = nm _ "_" _ i
            }
            Set names = names _ $Select(names = "": "", 1: ",") _ nm
            Do out.columns.%Push(nm)
            Set defs = defs _ $Select(defs = "": "", 1: ", ") _ nm _ " " _
                ##class(DataIntegrator.Tools.Util).ODBCToDDL(col.ODBCType, col.precision, col.scale)
        }
        Set out.columnDefs = defs
        Set objRows = []
        While rs.%Next() {
            Set row = []
            Set obj = {}
            For i = 1:1:meta.columnCount {
                Set v = rs.%GetData(i)
                Do row.%Push(v)
                Do obj.%Set($Piece(names, ",", i), v)
            }
            Do out.rows.%Push(row)
            Do objRows.%Push(obj)
        }
        Set out.sample = {"rows": (objRows)}
    } Catch ex {
        Set error = ex.DisplayString()
    }
    Do ..DecimalPoint(prev)
    Return out
}

/// The flowchart, composed live from the ML_* tables — nothing is stored.
/// Node kinds match the ml_* entries added to the frontend's KIND_LABEL.
ClassMethod Graph(name As %String) As %DynamicObject
{
    Set nodes = []
    Set edges = []
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Do stmt.%Prepare("SELECT PREDICTING_COLUMN_NAME, DEFAULT_TRAINING_QUERY, DEFAULT_TRAINED_MODEL_NAME "_
                         "FROM INFORMATION_SCHEMA.ML_MODELS WHERE MODEL_NAME = ?")
        Set rs = stmt.%Execute(name)
        If 'rs.%Next() {
            Return {"nodes": (nodes), "edges": (edges)}
        }
        Set target = rs.%GetData(1)
        Set query = rs.%GetData(2)
        Set trained = rs.%GetData(3)

        // Source table from the recorded training query. IRIS stores it with
        // spaces around the qualifier - "SELECT * FROM  DATAINTEGRATOR . ml_smoke" -
        // so cut at the first trailing clause, then squeeze the spaces out.
        Set source = ""
        If $ZConvert(query, "U") [ " FROM " {
            Set source = $Piece(query, " FROM ", 2)
            Set source = $Piece(source, " WHERE ", 1)
            Set source = $Piece(source, " GROUP ", 1)
            Set source = $Piece(source, " ORDER ", 1)
            Set source = $Translate($ZStrip(source, "<>W"), " ", "")
        }
        If source '= "" {
            Do nodes.%Push({"id": "src", "name": (source), "kind": "ml_source", "status": "ready", "order": 10})
            Do edges.%Push({"from": "src", "to": "model", "label": "trains"})
        }
        Do nodes.%Push({"id": "model", "name": (name), "kind": "ml_model", "status": "defined",
                        "detail": ("predicting " _ target), "order": 20})

        Set status = ..Status(name)
        If trained '= "" {
            Do nodes.%Push({"id": "trained", "name": (trained), "kind": "ml_trained",
                            "status": (status.status), "detail": (..ModelInfo(name)), "order": 30})
            Do edges.%Push({"from": "model", "to": "trained", "label": (status.duration _ "s")})
        } ElseIf status.status '= "none" {
            // in flight or failed: still draw it so the chart shows why
            Do nodes.%Push({"id": "trained", "name": "(training)", "kind": "ml_trained",
                            "status": (status.status), "order": 30})
            Do edges.%Push({"from": "model", "to": "trained", "label": (status.status)})
        }

        Set vstmt = ##class(%SQL.Statement).%New()
        Set vsc = vstmt.%Prepare("SELECT TOP 1 VALIDATION_RUN_NAME, RUN_STATUS, VALIDATION_DURATION "_
                                  "FROM INFORMATION_SCHEMA.ML_VALIDATION_RUNS WHERE MODEL_NAME = ? "_
                                  "ORDER BY START_TIMESTAMP DESC")
        If $$$ISOK(vsc) {
            Set vrs = vstmt.%Execute(name)
            If vrs.%Next() {
                Do nodes.%Push({"id": "valid", "name": (vrs.%GetData(1)), "kind": "ml_validation",
                                "status": ($ZConvert(vrs.%GetData(2), "L")), "order": 40})
                Do edges.%Push({"from": "trained", "to": "valid", "label": "validate"})
                Set metrics = ..Metrics(name)
                If metrics.%Size() > 0 {
                    Do nodes.%Push({"id": "metrics", "name": (metrics.%Size() _ " metrics"),
                                    "kind": "ml_metrics", "status": "ready",
                                    "detail": (..Headline(metrics)), "order": 50})
                    Do edges.%Push({"from": "valid", "to": "metrics", "label": ""})
                }
            }
        }
    } Catch ex {
    }
    Return {"nodes": (nodes), "edges": (edges)}
}

/// One-line summary for the metrics node — accuracy if present, else the first
/// overall (class-less) metric.
ClassMethod Headline(metrics As %DynamicArray) As %String
{
    Set fallback = ""
    Try {
        Set iter = metrics.%GetIterator()
        While iter.%GetNext(, .m) {
            If m.class '= "" {
                Continue
            }
            If $ZConvert(m.metric, "L") = "accuracy" {
                Return "Accuracy " _ m.value
            }
            If fallback = "" {
                Set fallback = m.metric _ " " _ m.value
            }
        }
    } Catch ex {
    }
    Return fallback
}

/// Where the wizard keeps user-supplied AutoML models: ONE DIRECTORY PER MODEL.
///
/// That layout is not cosmetic, it is what makes a custom model selectable.
/// AutoML's load_models() (automl_model.py) takes a *directory* and imports
/// every .py in it as a competing candidate; there is no per-file switch. So
/// dropping a model into the shared iris_automl/Classifiers only adds it to the
/// contest - measured on this instance, a custom Decision Tree added that way
/// lost to the shipped Logistic Regression and never ran. Giving each model its
/// own directory and pointing path_to_classifiers at it leaves exactly one
/// candidate, which is what "use THIS model" has to mean.
///
/// This is the durable mgr (/opt/irisbuild/data/mgr/python), not the image
/// tree - with durable %SYS that is what the running instance reads.
ClassMethod CustomRoot() As %String
{
    Return "/opt/irisbuild/data/mgr/python/dataintegrator_models"
}

/// Directory holding one custom model's file.
ClassMethod CustomDir(kind As %String, slug As %String) As %String
{
    Return ..CustomRoot() _ "/" _ ..NormalKind(kind) _ "/" _ slug
}

/// The model's Python file, named after the model rather than something
/// generic.
///
/// This name is load-bearing. load_models() does importlib.import_module() on
/// the file's base name, and Python caches imported modules by that name for
/// the life of the process. Calling every file "model.py" therefore means the
/// FIRST custom model imported wins and every later directory silently returns
/// that same cached module - the requested model_name then matches nothing and
/// AutoML quietly falls back to a shipped model. One module name per model
/// keeps them distinct.
ClassMethod ModelFile(kind As %String, slug As %String) As %String
{
    Return ..CustomDir(kind, slug) _ "/" _ slug _ ".py"
}

/// "regression" or "classification" - anything else is treated as classification.
ClassMethod NormalKind(kind As %String) As %String
{
    Return $Select($ZConvert(kind, "L") = "regression": "regression", 1: "classification")
}

/// The USING key that points AutoML at a model directory depends on the problem
/// type: classifiers and regressors are loaded from separate paths.
///
/// The key is "pathtoregressors", NOT "path_to_regressors". %ML.AutoML.Provider
/// reads trainingrun.Settings.pathtoregressors and only then passes it on to
/// automl.py as path_to_regressors - the underscored spelling is the Python
/// argument, not the SQL setting. An unknown USING key is accepted silently, so
/// with the underscored one every custom model was simply ignored and AutoML
/// ran the shipped candidates instead; measured here, a model pinned this way
/// still trained as "Linear Regression".
ClassMethod PathKey(kind As %String) As %String
{
    Return $Select(..NormalKind(kind) = "regression": "pathtoregressors", 1: "pathtoclassifiers")
}

/// The USING settings that select one custom model, ready to merge into a
/// CREATE MODEL clause: the model's registered name plus the directory that
/// holds only that model.
ClassMethod CustomUsing(kind As %String, slug As %String, modelName As %String) As %DynamicObject
{
    Set out = {}
    Do out.%Set("model_name", modelName)
    Do out.%Set(..PathKey(kind), ..CustomDir(kind, slug))
    Return out
}

/// A custom model registers itself through `self.name` inside class IRISModel -
/// that string, not the file name, is what model_name has to match. Pull it out
/// of the source so the user never has to keep the two in sync by hand.
ClassMethod ModelNameOf(source As %String) As %String
{
    Try {
        Set pos = $Find(source, "self.name")
        If pos = 0 {
            Return ""
        }
        // what follows is [spaces] = [spaces] <quote> name <quote>
        Set rest = $ZStrip($Piece($Extract(source, pos, *), "=", 2, *), "<W")
        Set quote = $Extract(rest, 1)
        If (quote '= """") && (quote '= "'") {
            Return ""
        }
        Return $Piece($Extract(rest, 2, *), quote, 1)
    } Catch ex {
    }
    Return ""
}

/// Custom models the wizard manages, each with the USING settings that select it.
ClassMethod ListCustomModels() As %DynamicArray
{
    Set out = []
    Try {
        For kind = "classification", "regression" {
            Set base = ..CustomRoot() _ "/" _ kind
            If '##class(%File).DirectoryExists(base) {
                Continue
            }
            Set dirs = ##class(%ResultSet).%New("%File:FileSet")
            If '$$$ISOK(dirs.Execute(base, "*", , 1)) {
                Continue
            }
            While dirs.Next() {
                If dirs.Get("Type") '= "D" {
                    Continue
                }
                Set slug = $Piece($ZStrip(dirs.Get("Name"), ">", "/"), "/", *)
                Set file = ..ModelFile(kind, slug)
                If '##class(%File).Exists(file) {
                    Continue
                }
                Do out.%Push({
                    "slug": (slug),
                    "kind": (kind),
                    "modelName": (..ReadModelName(file)),
                    "dir": (..CustomDir(kind, slug)),
                    "pathKey": (..PathKey(kind))
                })
            }
        }
    } Catch ex {
    }
    Return out
}

/// The registered model_name of an installed custom model, read back from disk.
ClassMethod ReadModelName(file As %String) As %String
{
    Try {
        Set stream = ##class(%Stream.FileCharacter).%New()
        If $$$ISERR(stream.LinkToFile(file)) {
            Return ""
        }
        Set source = ""
        While 'stream.AtEnd {
            Set source = source _ stream.Read(4096)
        }
        Return ..ModelNameOf(source)
    } Catch ex {
    }
    Return ""
}

/// The source of an installed custom model, so the UI can show and edit it.
ClassMethod ReadCustomModel(slug As %String, kind As %String) As %String
{
    Try {
        Set file = ..ModelFile(kind, slug)
        If '##class(%File).Exists(file) {
            Return ""
        }
        Set stream = ##class(%Stream.FileCharacter).%New()
        If $$$ISERR(stream.LinkToFile(file)) {
            Return ""
        }
        Set source = ""
        While 'stream.AtEnd {
            Set source = source _ stream.Read(4096)
        }
        Return source
    } Catch ex {
    }
    Return ""
}

/// Where AutoML actually looks for candidates when nothing overrides it.
///
/// This matters because of a gap between the documented feature and the
/// installed provider. CREATE MODEL ... USING {"model_name": ...,
/// "path_to_classifiers": ...} is the documented way to name one model, and it
/// is what this wizard emits. On intersystems-iris-automl 1.0.3 - the newest
/// on registry.intersystems.com, and what is installed here - those two keys
/// have no effect: automl_train.py has no model_name handling at all, and
/// pointing path_to_classifiers at an EMPTY directory still trains a shipped
/// model. Verified on this instance, not inferred. model_name selection is an
/// Early Access capability that needs an EAP AutoML build.
///
/// So a custom model is installed in BOTH places: its own directory (which is
/// what the USING clause names, and what will select it once the provider
/// honours it) and the shipped Classifiers/Regressors directory, which is the
/// only thing 1.0.3 reads. In the shipped directory AutoML *competes* the model
/// against its own rather than being told to use it - the UI says so plainly.
ClassMethod ShippedDir(kind As %String) As %String
{
    Set sub = $Select(..NormalKind(kind) = "regression": "Regressors", 1: "Classifiers")
    Return "/opt/irisbuild/data/mgr/python/iris_automl/" _ sub
}

/// The shipped-directory copy of a custom model. Prefixed so the wizard's own
/// files are identifiable, and never "isc_" - that prefix means InterSystems'.
ClassMethod ShippedFile(kind As %String, slug As %String) As %String
{
    Return ..ShippedDir(kind) _ "/etlwiz_" _ slug _ ".py"
}

/// Install a custom model into its own directory. The source must define class
/// IRISModel with a `self.name` - that name is what CREATE MODEL's model_name
/// refers to, so a file without one could never be selected and is rejected
/// here rather than at training time.
ClassMethod SaveCustomModel(slug As %String, kind As %String, source As %String, Output error As %String, Output modelName As %String) As %Boolean
{
    Set error = "", modelName = ""
    Try {
        Set slug = $ZStrip(slug, "<>W")
        If slug = "" {
            Set error = "give the model a name"
            Return 0
        }
        // the slug becomes a directory name and a Python module path, so keep it
        // to something both are happy with
        If '$Match(slug, "^[A-Za-z][A-Za-z0-9_]*$") {
            Set error = "the name must start with a letter and contain only letters, digits and underscores"
            Return 0
        }
        If '(source [ "IRISModel") {
            Set error = "the file must define a class named IRISModel - that is what AutoML instantiates"
            Return 0
        }
        Set modelName = ..ModelNameOf(source)
        If modelName = "" {
            Set error = "IRISModel must set self.name - that string is what CREATE MODEL selects with model_name"
            Return 0
        }
        Set dir = ..CustomDir(kind, slug)
        If '##class(%File).DirectoryExists(dir) {
            If '##class(%File).CreateDirectoryChain(dir) {
                Set error = "could not create " _ dir
                Return 0
            }
        }
        // named after the model, not "model.py" - see ModelFile() for why a
        // shared module name makes every custom model after the first unusable
        Set stream = ##class(%Stream.FileCharacter).%New()
        Set sc = stream.LinkToFile(..ModelFile(kind, slug))
        If $$$ISERR(sc) {
            Set error = $System.Status.GetErrorText(sc)
            Return 0
        }
        Do stream.Clear()
        Do stream.Write(source)
        Set sc = stream.%Save()
        If $$$ISERR(sc) {
            Set error = $System.Status.GetErrorText(sc)
            Return 0
        }
        // second copy where the installed provider actually looks - see
        // ShippedDir() for why one copy is not enough
        Set shipped = ##class(%Stream.FileCharacter).%New()
        Set sc = shipped.LinkToFile(..ShippedFile(kind, slug))
        If $$$ISOK(sc) {
            Do shipped.Clear()
            Do shipped.Write(source)
            Do shipped.%Save()
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

ClassMethod DeleteCustomModel(slug As %String, kind As %String, Output error As %String) As %Boolean
{
    Set error = ""
    Try {
        If (slug [ "/") || (slug [ "\\") || (slug [ "..") || (slug = "") {
            Set error = "invalid model name"
            Return 0
        }
        Set dir = ..CustomDir(kind, slug)
        If '##class(%File).DirectoryExists(dir) {
            Set error = "no such model: " _ slug
            Return 0
        }
        Do ##class(%File).Delete(..ModelFile(kind, slug))
        Do ##class(%File).Delete(..ShippedFile(kind, slug))
        // __pycache__ is created by the import in load_models; leaving it behind
        // would keep the directory alive and the model listed
        Set cache = dir _ "/__pycache__"
        If ##class(%File).DirectoryExists(cache) {
            Do ##class(%File).RemoveDirectoryTree(cache)
        }
        If '##class(%File).RemoveDirectory(dir) {
            Set error = "could not remove " _ dir
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

ClassMethod Drop(name As %String, Output error As %String) As %Boolean
{
    Set error = ""
    Try {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "DROP MODEL " _ name)
        If rs.%SQLCODE < 0 {
            Set error = ..Explain(rs.%SQLCODE, rs.%Message)
            Return 0
        }
    } Catch ex {
        Set error = ex.DisplayString()
        Return 0
    }
    Return 1
}

/// Turn the SQLCODEs and Python exceptions this path actually produces into
/// something a user can act on. Everything else passes through unchanged.
ClassMethod Explain(code As %String, message As %String) As %String
{
    If message [ "ZeroDivisionError" {
        Return "the time column has no usable interval - it must be a date/time column with "_
               "one row per period. Several rows sharing a timestamp, or an integer column, "_
               "both make the inferred interval zero."
    }
    // Both of these come out of %ML.Model.1, the GENERATED routine behind
    // PREDICT and SELECT WITH PREDICTIONS, and both are specific to time-series
    // models - a regression or classification model predicts normally on this
    // same build. %ValidateTimeseries drives SELECT WITH PREDICTIONS, so it
    // inherits the failure and then misreports it as a row-count problem
    // ("likely not enough rows ... with a Forward value of N") whatever the row
    // count actually is. %ML.Model.1 lives in IRISLIB, which is mounted
    // read-only, so this cannot be patched from here.
    If (message [ "%ValidateTimeseries") || (message [ "mtorder") ||
       (message [ "%PredictAll^%ML.Model") {
        Return "time-series predictions are broken in this IRIS build "_
               "(2026.3.0AI Build 136U): PREDICT() on a time-series model dies with "_
               "<UNDEFINED> *mtorder and SELECT WITH PREDICTIONS with <PARAMETER>, "_
               "both inside the read-only %ML.Model.1. VALIDATE MODEL is built on the "_
               "second one, so it cannot succeed here - its own 'not enough rows' "_
               "wording is a red herring. Non-time-series models are unaffected."
    }
    If message [ "is not unique" {
        Return "a model with that name already exists - pick another name, or drop it first."
    }
    If message [ "has no default trained model" {
        Return "the model has not been trained yet."
    }
    If message [ "not available on this instance" {
        Return "the AutoML provider is not installed - run scripts/install-automl.sh."
    }
    If $Extract(message, 1, 1) = "" {
        Return "SQLCODE " _ code
    }
    Return message
}

}
