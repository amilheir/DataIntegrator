Include %AI

/// Audit policy (spec §10.3): wraps every tool call and bridges it to the
/// event log -> WS hub -> canvas. This one class is the entire agent<->UI
/// bridge; the agent code knows nothing about the frontend.
/// Hook contract verified on build 162: %LogExecution(call, metadata, result,
/// duration, status) is called after every tool execution (success or error).
/// Stateless by design (no instance properties).
Class ETLWizard.Policy.Audit Extends %AI.Policy.Audit
{

Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    Try {
        // call.arguments arrives as an OBJECT in %CanExecute but as a JSON
        // STRING here (verified on build 162) — handle both shapes
        Set runId = ""
        Try {
            Set args = call.arguments
            If '$IsObject(args) {
                Set args = ##class(%DynamicObject).%FromJSON(args)
            }
            Set runId = args.%Get("runId", "")
        } Catch {
            Set runId = ""
        }
        If runId = "" {
            // Tool without run context (e.g. pure discovery) — nothing to bridge
            Return $$$OK
        }
        Set ok = $$$ISOK(status)
        Set payload = {}
        Set payload.tool = call.name
        Set payload.ok = ok
        Set payload.durationMs = duration
        If 'ok {
            Set payload.error = $System.Status.GetErrorText(status)
        } ElseIf $IsObject(result) {
            Set summary = result.%Get("result_json", "")
            If $Length(summary) > 300 {
                Set summary = $Extract(summary, 1, 300) _ "..."
            }
            Set payload.result = summary
        }
        Do ##class(ETLWizard.Model.Event).Append(runId, "tool.executed", "", payload)
    } Catch {
        // Auditing must never break tool execution
    }
    Return $$$OK
}

}
