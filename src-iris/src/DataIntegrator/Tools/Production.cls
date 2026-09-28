/// Interoperability Production tools (spec v2.2 §10.2). All pipelines share
/// ONE production — ETLWizard.Prod.Main — and each deployed pipeline appends
/// its own item group: <base>_Extract (Business Service, poll schedule),
/// <base>_Orchestrate (Business Process), <base>_Load (Business Operation).
/// The user sees every ETL side by side in the Production Configuration page,
/// each with its own messages and Visual Trace.
/// Generation/lifecycle verbs are gated by requires_auth.
Class ETLWizard.Tools.Production Extends %AI.Tool [ DependsOn = (ETLWizard.Tools.Util, ETLWizard.Host.ExtractService, ETLWizard.Host.Orchestrator, ETLWizard.Host.LoadOperation) ]
{

Parameter PRODCLASS = "ETLWizard.Prod.Main";

/// Create the shared production class once, programmatically. It deliberately
/// has NO source file in the repo: the production items live in the class
/// XData, and recompiling a checked-in (empty) source would wipe every
/// pipeline's items (verified the hard way). DB-only + created on demand.
ClassMethod EnsureMainProduction() As %String [ Internal ]
{
    Try {
        If ##class(%Dictionary.CompiledClass).%ExistsId(..#PRODCLASS) {
            Return ""
        }
        Set nl = $Char(10)
        Set src = "/// The single shared ETL Wizard production. Every deployed pipeline appends" _ nl
        Set src = src _ "/// its own <base>_Extract / <base>_Orchestrate / <base>_Load items here." _ nl
        Set src = src _ "/// Created programmatically by ETLWizard.Tools.Production - do not add a" _ nl
        Set src = src _ "/// source file for it (recompiling an empty source wipes the items)." _ nl
        Set src = src _ "Class " _ ..#PRODCLASS _ " Extends Ens.Production" _ nl _ "{" _ nl _ nl
        Set src = src _ "XData ProductionDefinition" _ nl _ "{" _ nl
        Set src = src _ "<Production Name=""" _ ..#PRODCLASS _ """ LogGeneralTraceEvents=""false"">" _ nl
        Set src = src _ "  <Description>ETL Wizard shared production - one item group per pipeline</Description>" _ nl
        Set src = src _ "  <ActorPoolSize>2</ActorPoolSize>" _ nl
        Set src = src _ "</Production>" _ nl _ "}" _ nl _ nl _ "}" _ nl
        Set stream = ##class(%Stream.TmpCharacter).%New()
        Do stream.Write(src)
        Set sc = $System.OBJ.LoadStream(stream, "ck-d", .errLog, .loaded)
        If $$$ISERR(sc) {
            Return "ERROR creating shared production: " _ $System.Status.GetErrorText(sc)
        }
        Return ""
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Build an Ens Business Host Schedule spec from a day list + time list, so the
/// service fires once at each wall-clock time instead of polling. days is a
/// comma list of upper-case day names (SUNDAY..SATURDAY) or "" for every day.
/// times is a comma list of "HH:MM". Each time becomes a START (HH:MM:00) + a
/// STOP 30s later, so with a large CallInterval the service runs exactly once
/// per time. Times are the SERVER's local zone (this container is UTC).
/// Returns the spec, or "ERROR: ..." if it does not validate.
ClassMethod BuildSchedule(days As %String = "", times As %String = "") As %String
{
    Try {
        Set times = $ZStrip(times, "<>W")
        If times = "" {
            Return "ERROR: pick at least one time of day"
        }
        // day prefixes: "" -> one entry with no day (every day)
        Set dayList = ""
        If $ZStrip(days, "<>W") = "" {
            Set dayList = $ListBuild("")
        } Else {
            For i = 1:1:$Length(days, ",") {
                Set d = $ZConvert($ZStrip($Piece(days, ",", i), "<>W"), "U")
                If d '= "" { Set dayList = dayList _ $ListBuild(d) }
            }
        }
        Set spec = ""
        For i = 1:1:$Length(times, ",") {
            Set t = $ZStrip($Piece(times, ",", i), "<>W")
            Set hh = +$Piece(t, ":", 1), mm = +$Piece(t, ":", 2)
            If (t = "") || (hh < 0) || (hh > 23) || (mm < 0) || (mm > 59) {
                Return "ERROR: invalid time '" _ t _ "' (expected HH:MM)"
            }
            Set hh2 = $Extract("0" _ hh, *-1, *), mm2 = $Extract("0" _ mm, *-1, *)
            Set p = 0
            While $ListNext(dayList, p, dy) {
                Set pfx = $Select(dy = "": "", 1: dy _ ":")
                Set spec = spec _ $Select(spec = "": "", 1: ",") _
                    pfx _ "START:" _ hh2 _ ":" _ mm2 _ ":00," _
                    pfx _ "STOP:" _ hh2 _ ":" _ mm2 _ ":30"
            }
        }
        If '##class(Ens.Util.Schedule).ScheduleSpecIsValid(spec) {
            Return "ERROR: could not build a valid schedule from those days/times"
        }
        Return spec
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Add (or refresh) this pipeline's item group on the shared production
/// ETLWizard.Prod.Main. When scheduleSpec is set the Extract service runs on
/// that wall-clock schedule (large CallInterval, fire-once-per-window);
/// otherwise it polls every callIntervalSecs. Records the host nodes.
///
/// poolSize sets how many jobs the Orchestrate process and Load operation each
/// run with (default 1). The Extract service stays at PoolSize 1 on purpose: on
/// a polling inbound adapter the pool is the number of concurrent poll jobs, so
/// raising it would start the same extract several times over.
Method GenerateProduction(runId As %String, callIntervalSecs As %Integer = 300, scheduleSpec As %String = "", poolSize As %Integer = 1) As %String
{
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return "ERROR: run not found: " _ runId
        }
        Set pipeline = run.Pipeline
        Set err = ##class(ETLWizard.Runtime.Executor).ParsePlan(pipeline, .baseName, .foreignTable, .wmColumn, .mode)
        If err '= "" {
            Return err
        }
        If callIntervalSecs < 5 {
            Set callIntervalSecs = 5
        }
        Set poolSize = +poolSize
        If poolSize < 1 {
            Set poolSize = 1
        }
        Set err = ..EnsureMainProduction()
        If err '= "" {
            Return err
        }
        Set prodConfig = ##class(Ens.Config.Production).%OpenId(..#PRODCLASS)
        If '$IsObject(prodConfig) {
            Return "ERROR: shared production " _ ..#PRODCLASS _ " not found - is the namespace interoperability-enabled?"
        }

        Set svcName = baseName _ "_Extract"
        Set bpName = baseName _ "_Orchestrate"
        Set opName = baseName _ "_Load"

        // Idempotent redeploy: drop this pipeline's previous items
        For i = prodConfig.Items.Count():-1:1 {
            Set existing = prodConfig.Items.GetAt(i)
            If $ListFind($ListBuild(svcName, bpName, opName), existing.Name) > 0 {
                Do prodConfig.Items.RemoveAt(i)
            }
        }

        // <base>_Extract: Business Service polling on the schedule
        Set svc = ##class(Ens.Config.Item).%New()
        Set svc.Name = svcName
        Set svc.ClassName = "ETLWizard.Host.ExtractService"
        Set svc.PoolSize = 1
        Set svc.Enabled = 1
        Do ..AddSetting(svc, "Host", "PipelineId", pipeline.%Id())
        Do ..AddSetting(svc, "Host", "TargetProcess", bpName)
        // Schedule mode: fire once per wall-clock time (large CallInterval so the
        // single poll in the 30s START..STOP window runs the pipeline just once).
        If $ZStrip(scheduleSpec, "<>W") '= "" {
            Set svc.Schedule = scheduleSpec
            Do ..AddSetting(svc, "Adapter", "CallInterval", 3600)
        } Else {
            Do ..AddSetting(svc, "Adapter", "CallInterval", callIntervalSecs)
        }
        Do prodConfig.Items.Insert(svc)

        // <base>_Orchestrate: Business Process
        Set bp = ##class(Ens.Config.Item).%New()
        Set bp.Name = bpName
        Set bp.ClassName = "ETLWizard.Host.Orchestrator"
        Set bp.PoolSize = poolSize
        Set bp.Enabled = 1
        Do ..AddSetting(bp, "Host", "LoadTarget", opName)
        Do prodConfig.Items.Insert(bp)

        // <base>_Load: Business Operation
        Set op = ##class(Ens.Config.Item).%New()
        Set op.Name = opName
        Set op.ClassName = "ETLWizard.Host.LoadOperation"
        Set op.PoolSize = poolSize
        Set op.Enabled = 1
        Do prodConfig.Items.Insert(op)

        Set sc = prodConfig.%Save()
        If $$$ISERR(sc) {
            Return "ERROR saving production config: " _ $System.Status.GetErrorText(sc)
        }

        // Persist/refresh the Production model row
        Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(pipeline.%Id())
        If '$IsObject(prod) {
            Set prod = ##class(ETLWizard.Model.Production).%New()
            Set prod.Pipeline = pipeline
        }
        Set prod.ProductionClass = ..#PRODCLASS
        Set prod.ConfigJson = {"callIntervalSecs": (callIntervalSecs), "schedule": (scheduleSpec),
            "poolSize": (poolSize), "items": [(svcName), (bpName), (opName)]}.%ToJSON()
        Set sc = prod.%Save()
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }

        // Catalog host nodes (HostRole/HostItemName)
        Do ..CatalogHost(run, svcName, "business_service", "ETLWizard.Host.ExtractService", ..#PRODCLASS)
        Do ..CatalogHost(run, bpName, "business_process", "ETLWizard.Host.Orchestrator", ..#PRODCLASS)
        Do ..CatalogHost(run, opName, "business_operation", "ETLWizard.Host.LoadOperation", ..#PRODCLASS)
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.created", "",
            {"kind": "production", "name": (..#PRODCLASS), "items": [(svcName), (bpName), (opName)],
             "callIntervalSecs": (callIntervalSecs), "poolSize": (poolSize)})

        Return "Added items " _ svcName _ " (poll " _ callIntervalSecs _ "s) -> " _ bpName _ " -> " _ opName _
               " (pool size " _ poolSize _ ") to the shared production " _ ..#PRODCLASS _
               ". Apply with ApplyProduction."
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Remove a pipeline's three items from the shared production (used when the
/// pipeline is deleted). Returns the names removed, comma-separated.
ClassMethod RemovePipelineItems(pipelineId As %String) As %String
{
    Try {
        Set pipeline = ##class(ETLWizard.Model.Pipeline).%OpenId(pipelineId)
        If '$IsObject(pipeline) {
            Return ""
        }
        Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(pipelineId)
        Set names = ""
        If $IsObject(prod) {
            Try {
                Set cfg = ##class(%DynamicObject).%FromJSON(prod.ConfigJson)
                Set it = cfg.items.%GetIterator()
                While it.%GetNext(.i, .v) {
                    Set names = names _ $Select(names = "": "", 1: ",") _ v
                }
            } Catch {
            }
        }
        If names = "" {
            Return ""
        }
        Set prodConfig = ##class(Ens.Config.Production).%OpenId(..#PRODCLASS)
        If '$IsObject(prodConfig) {
            Return ""
        }
        Set gone = ""
        For i = prodConfig.Items.Count():-1:1 {
            Set item = prodConfig.Items.GetAt(i)
            For n = 1:1:$Length(names, ",") {
                If item.Name = $Piece(names, ",", n) {
                    Set gone = gone _ $Select(gone = "": "", 1: ",") _ item.Name
                    Do prodConfig.Items.RemoveAt(i)
                    Quit
                }
            }
        }
        If gone '= "" {
            Do prodConfig.%Save()
            // apply so the running production stops the removed hosts
            Try {
                Do ..QuietDirector("update", 10)
            } Catch {
            }
        }
        Return gone
    } Catch {
        Return ""
    }
}

/// Add (or refresh) the sample-data feed in the shared production: a tick
/// service on callIntervalSecs plus the operation that writes the rows into the
/// Postgres sample schema. Independent of any pipeline — it feeds the source,
/// it does not read it.
ClassMethod ConfigureSampleDataFeed(callIntervalSecs As %Integer = 60, employees As %Integer = 1, customers As %Integer = 2, orders As %Integer = 10) As %String
{
    Try {
        Set err = ..EnsureMainProduction()
        If err '= "" {
            Return err
        }
        Set prodConfig = ##class(Ens.Config.Production).%OpenId(..#PRODCLASS)
        If '$IsObject(prodConfig) {
            Return "ERROR: shared production " _ ..#PRODCLASS _ " not found"
        }
        Set svcName = "SampleData_Tick", opName = "SampleData_Generate"
        For i = prodConfig.Items.Count():-1:1 {
            Set existing = prodConfig.Items.GetAt(i)
            If $ListFind($ListBuild(svcName, opName), existing.Name) > 0 {
                Do prodConfig.Items.RemoveAt(i)
            }
        }
        Set op = ##class(Ens.Config.Item).%New()
        Set op.Name = opName
        Set op.ClassName = "ETLWizard.Host.SampleDataOperation"
        Set op.PoolSize = 1
        Set op.Enabled = 1
        Do ..AddSetting(op, "Host", "Employees", employees)
        Do ..AddSetting(op, "Host", "Customers", customers)
        Do ..AddSetting(op, "Host", "Orders", orders)
        // trace on by default: the point of the feed is watching the rows it
        // writes, and $$$TRACE output is discarded unless the item logs traces
        Set op.LogTraceEvents = 1
        Do prodConfig.Items.Insert(op)

        Set svc = ##class(Ens.Config.Item).%New()
        Set svc.Name = svcName
        Set svc.ClassName = "ETLWizard.Host.SampleDataTick"
        Set svc.PoolSize = 1
        Set svc.Enabled = 1
        Do ..AddSetting(svc, "Host", "TargetOperation", opName)
        Do ..AddSetting(svc, "Adapter", "CallInterval", callIntervalSecs)
        Do prodConfig.Items.Insert(svc)

        Set sc = prodConfig.%Save()
        If $$$ISERR(sc) {
            Return "ERROR saving production config: " _ $System.Status.GetErrorText(sc)
        }
        Return "Added " _ svcName _ " (every " _ callIntervalSecs _ "s) -> " _ opName _
               " (" _ employees _ " employee / " _ customers _ " customers / " _ orders _
               " orders per tick) to " _ ..#PRODCLASS
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Run one Ens.Director production call with $IO pointed at /dev/null.
///
/// WHY THIS EXISTS: UpdateProduction/StartProduction parallelise their work
/// through %SYSTEM.WorkMgr, and WorkMgr replays a worker job's console output
/// on the CALLING process's current device. Ens.Util.Log:Log echoes there
/// unconditionally for these - its guard is
/// `...||((pSourceClass="Ens.Director")&&$System.WorkMgr.IsWorkerJob())` - so
/// "Production 'X' updating..." / "updated." is written to $IO no matter what.
///
/// From Terminal that is the point. From the REST dispatcher $IO *is* the HTTP
/// response body (Dispatcher:WriteJSON is a plain `Write json.%ToJSON()`), so
/// those two lines land in front of the JSON and every client fails to parse
/// it: "The server answered with something that is not JSON (HTTP 200)".
/// There is no quiet flag on Ens.Director to turn this off - the only lever is
/// the device, so swallow the writes here rather than at each call site.
/// The sink is a FRESH TEMP FILE, not /dev/null, and the Open carries a real
/// timeout. Both details were paid for: `Open "/dev/null":"WNS":0` is a shared
/// device opened with "try once, do not wait", and it was observed failing
/// intermittently - the following Use raised <NOTOPEN>, the Catch swallowed it,
/// and the leak came back silently on that request. A per-call temp file has no
/// such contention, and $Test is checked so a device that did not open is never
/// Used.
ClassMethod QuietDirector(action As %String, arg As %String = "") As %Status [ Internal ]
{
    Set io = $IO, sink = "", redirected = 0
    Try {
        Set sink = ##class(%File).TempFilename()
        Open sink:("WNS"):5
        // Open with a timeout reports through $Test, it does not throw
        If $Test {
            Use sink
            Set redirected = 1
        }
    } Catch {
        // Could not build the sink. Run un-redirected rather than fail the
        // deploy: a cosmetic leak beats refusing to apply the production.
        Set redirected = 0
    }
    Try {
        If action = "start" {
            Set sc = ##class(Ens.Director).StartProduction(arg)
        } ElseIf arg '= "" {
            Set sc = ##class(Ens.Director).UpdateProduction(+arg)
        } Else {
            // no arg: keep Ens.Director's own pTimeout default (10), do not
            // pass +"" and silently turn it into 0
            Set sc = ##class(Ens.Director).UpdateProduction()
        }
    } Catch ex {
        Do ..CloseSink(io, sink, redirected)
        Throw ex
    }
    Do ..CloseSink(io, sink, redirected)
    Return sc
}

/// Restore the caller's device and drop the sink file. Never lets a cleanup
/// failure mask the result of the Director call it is unwinding.
ClassMethod CloseSink(io As %String, sink As %String, redirected As %Boolean) [ Internal, Private ]
{
    Try {
        If redirected {
            Use io
            Close sink
        }
        If sink '= "" {
            Do ##class(%File).Delete(sink)
        }
    } Catch {
        Try { Use io } Catch {}
    }
    Quit
}

/// Start the shared production if needed, otherwise apply the config changes
/// to the running production. The pipeline then runs on its poll schedule.
Method ApplyProduction(runId As %String) As %String
{
    Try {
        Set err = ..GetProduction(runId, .run, .prod)
        If err '= "" {
            Return err
        }
        If ##class(Ens.Director).IsProductionRunning(..#PRODCLASS) {
            Set sc = ..QuietDirector("update")
        } Else {
            Set sc = ..QuietDirector("start", ..#PRODCLASS)
        }
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set prod.Status = "running"
        Do prod.%Save()
        Set run.Pipeline.Status = "Deployed"
        Do run.Pipeline.%Save()
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "",
            {"name": (..#PRODCLASS), "status": "running", "hostRole": "production"})
        Return "Shared production " _ ..#PRODCLASS _ " is running with this pipeline's items enabled. " _
               "Runs fire on the poll schedule; use RunProductionNow for an immediate run."
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Pause THIS pipeline only: disables its item group on the shared production
/// (other pipelines keep running). Re-enable with ApplyProduction after
/// GenerateProduction, or via the Management Portal.
Method StopProduction(runId As %String) As %String
{
    Try {
        Set err = ..GetProduction(runId, .run, .prod)
        If err '= "" {
            Return err
        }
        Set names = ..ItemNames(prod)
        Set prodConfig = ##class(Ens.Config.Production).%OpenId(..#PRODCLASS)
        If '$IsObject(prodConfig) {
            Return "ERROR: shared production config not found"
        }
        Set changed = 0
        For i = 1:1:prodConfig.Items.Count() {
            Set item = prodConfig.Items.GetAt(i)
            If $ListFind(names, item.Name) > 0 {
                Set item.Enabled = 0
                Set changed = changed + 1
            }
        }
        If changed > 0 {
            Set sc = prodConfig.%Save()
            If $$$ISERR(sc) {
                Return "ERROR: " _ $System.Status.GetErrorText(sc)
            }
            If ##class(Ens.Director).IsProductionRunning(..#PRODCLASS) {
                Do ..QuietDirector("update")
            }
        }
        Set prod.Status = "stopped"
        Do prod.%Save()
        Do ##class(ETLWizard.Model.Event).Append(runId, "node.status", "",
            {"name": (..#PRODCLASS), "status": "pipeline items disabled", "items": (changed)})
        Return "Disabled " _ changed _ " item(s) of this pipeline on " _ ..#PRODCLASS _ " - other pipelines are unaffected."
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Trigger one immediate extraction run for THIS pipeline through the shared
/// production (fires its Business Service outside the poll schedule).
Method RunProductionNow(runId As %String) As %String
{
    Try {
        Set err = ..GetProduction(runId, .run, .prod)
        If err '= "" {
            Return err
        }
        If '##class(Ens.Director).IsProductionRunning(..#PRODCLASS) {
            Return "ERROR: shared production is not running - call ApplyProduction first"
        }
        Set names = ..ItemNames(prod)
        Set svcName = $ListGet(names, 1)
        If svcName = "" {
            Return "ERROR: no service item recorded for this pipeline"
        }
        Set sc = ##class(Ens.Director).CreateBusinessService(svcName, .svc)
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Set sc = svc.ProcessInput($$$NULLOREF, .out)
        If $$$ISERR(sc) {
            Return "ERROR: " _ $System.Status.GetErrorText(sc)
        }
        Return "Extraction triggered through " _ svcName _ ". Watch the run events and the Visual Trace."
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// $List of this pipeline's item names (service first) from ConfigJson.
ClassMethod ItemNames(prod As ETLWizard.Model.Production) As %List [ Internal, Private ]
{
    Set names = ""
    Try {
        Set cfg = ##class(%DynamicObject).%FromJSON(prod.ConfigJson)
        Set iter = cfg.items.%GetIterator()
        While iter.%GetNext(.i, .name) {
            Set names = names _ $ListBuild(name)
        }
    } Catch {
    }
    Return names
}

ClassMethod AddSetting(item As Ens.Config.Item, target As %String, name As %String, value As %String) [ Internal, Private ]
{
    Set setting = ##class(Ens.Config.Setting).%New()
    Set setting.Target = target
    Set setting.Name = name
    Set setting.Value = value
    Do item.Settings.Insert(setting)
}

/// Resolve the run -> pipeline -> Production row. Returns "" or error text.
ClassMethod GetProduction(runId As %String, Output run As ETLWizard.Model.Run, Output prod As ETLWizard.Model.Production) As %String [ Internal, Private ]
{
    Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
    If '$IsObject(run) {
        Return "ERROR: run not found: " _ runId
    }
    Set prod = ##class(ETLWizard.Model.Production).PipelineIdxOpen(run.Pipeline.%Id())
    If '$IsObject(prod) {
        Return "ERROR: no production items for this pipeline - call GenerateProduction first"
    }
    Return ""
}

ClassMethod CatalogHost(run As ETLWizard.Model.Run, itemName As %String, role As %String, className As %String, prodClass As %String) [ Internal, Private ]
{
    Try {
        Set node = ##class(ETLWizard.Model.Node).PipelineNameIdxOpen(run.Pipeline.%Id(), itemName)
        If '$IsObject(node) {
            Set node = ##class(ETLWizard.Model.Node).%New()
            Set node.Pipeline = run.Pipeline
            Set node.Name = itemName
        }
        Set node.Kind = "host"
        Set node.HostRole = role
        Set node.HostItemName = itemName
        Set node.CodeRef = className
        Set node.ConfigJson = {"production": (prodClass)}.%ToJSON()
        Set node.GraphStatus = "generated"
        Do node.%Save()
        Do ##class(ETLWizard.Model.Event).Append(run.%Id(), "node.created", node.%Id(),
            {"nodeId": (node.%Id()), "kind": "host", "name": (itemName)})
    } Catch {
    }
}

}
