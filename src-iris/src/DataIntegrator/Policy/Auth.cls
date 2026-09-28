Include %AI

/// Authorization policy (spec §10.3, §16.2): any tool carrying the
/// requires_auth requirement suspends execution, persists a PendingApproval,
/// pushes an approval.requested event to the canvas, and blocks until
/// POST /api/runs/:id/approvals/:aid resolves it (or the timeout expires).
/// Rejection returns to the agent as a tool error carrying the reviewer's
/// comment, so the agent re-plans instead of failing (spec §23.4).
///
/// Hook contract verified on build 162: %CanExecute(tool, call, metadata)
/// returns $$$OK to allow or $$$ERROR($$$AICoreToolAccessDenied, reason).
/// Stateless by design (no instance properties) so the ToolSet stays
/// non-stateful.
Class ETLWizard.Policy.Auth Extends %AI.Policy.Authorization
{

/// Approval wait timeout in seconds (override via ^ETLWizard("approvalTimeoutSecs"))
Parameter DEFAULTTIMEOUT = 300;

Method %CanExecute(tool As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    Try {
        If '..RequiresAuth(tool, call, metadata) {
            Return $$$OK
        }

        Set runId = ""
        Try {
            Set runId = call.arguments.%Get("runId", "")
        } Catch {
            Set runId = ""
        }
        If runId = "" {
            Set reason = "Tool '" _ call.name _ "' requires approval but no runId argument was provided"
            Return $$$ERROR($$$AICoreToolAccessDenied, reason)
        }

        Set argsJson = "{}"
        If $IsObject(call.arguments) {
            Set argsJson = call.arguments.%ToJSON()
        }
        Set sc = ..RequestApproval(runId, call.name, argsJson, .approvalId)
        If $$$ISERR(sc) {
            Return sc
        }

        // Block until a human resolves the approval (spec §10.3)
        Set timeout = +$Get(^ETLWizard("approvalTimeoutSecs"), ..#DEFAULTTIMEOUT)
        Set deadline = $ZHorolog + timeout
        While $ZHorolog < deadline {
            Set status = ""
            Set comment = ""
            Set resolvedBy = ""
            &sql(SELECT Status, "Comment", ResolvedBy INTO :status, :comment, :resolvedBy
                 FROM ETLWizard_Model.PendingApproval WHERE ID = :approvalId)
            If SQLCODE '= 0 {
                Set reason = "Approval record lost (SQLCODE " _ SQLCODE _ ")"
                Return $$$ERROR($$$AICoreToolAccessDenied, reason)
            }
            If status = "approved" {
                Return $$$OK
            }
            If status = "rejected" {
                Set reason = "Rejected by " _ resolvedBy _ $Select(comment '= "": ": " _ comment, 1: "") _ " - adjust the plan and try a different approach"
                Return $$$ERROR($$$AICoreToolAccessDenied, reason)
            }
            Hang 1
        }

        // Timeout: expire the approval and deny
        Do ..ExpireApproval(approvalId, runId)
        Set reason = "Approval request timed out after " _ timeout _ " seconds"
        Return $$$ERROR($$$AICoreToolAccessDenied, reason)
    } Catch ex {
        Return $$$ERROR($$$AICoreToolPolicyError, ex.DisplayString())
    }
}

/// A tool needs approval when the requires_auth requirement is set on its
/// ToolSet <Include>, or (belt and braces) when its name is in the known
/// destructive set — so a spec change can never silently un-gate DDL.
ClassMethod RequiresAuth(tool As %String, call As %DynamicObject, metadata As %DynamicObject) As %Boolean [ Internal ]
{
    Try {
        If $IsObject(metadata), +metadata.%Get("requires_auth", 0) {
            Return 1
        }
    } Catch {
    }
    Try {
        Set toolObj = {}.%FromJSON(tool)
        If +toolObj.%Get("requires_auth", 0) {
            Return 1
        }
    } Catch {
    }
    Set gated = $ListBuild("CreateForeignServer", "CreateForeignTableJdbc",
        "CreateForeignTableCsv", "DropForeignObject",
        "CreateLayerTables", "RunIncrementalLoad", "RunFullLoad",
        "RunSnapshotLoad", "RunAppendOnlyLoad", "RunCsvArrivalLoad",
        "CreateQuarantineTable", "RouteInvalidRows",
        "GenerateProduction", "ApplyProduction", "StopProduction",
        "GenerateRestClient", "RunRestCursorLoad",
        "DeployTransform", "RunTransformLoad", "CreateIndexes")
    Return $ListFind(gated, call.name) > 0
}

/// May the CURRENTLY NAMED USER resolve an approval? (IMPROVEMENTS_SPEC SG-1)
///
/// This deliberately inspects the user's OWN role assignments rather than
/// calling $SYSTEM.Security.Check(). The check is the obvious implementation
/// and it does not work here: both web applications are installed with
/// MatchRoles=":%All" (Installer.cls), so every request - including an
/// unauthenticated one - already holds every privilege, and
/// Check("ETLWizard.Approve","USE") returns true for anybody. Verified on this
/// instance: demo_analyst, holding only ETLWizard_User, successfully approved a
/// pending card while ^ETLWizard("devMode") was 0.
///
/// Asking "is this named human actually an approver?" is the question the
/// governance claim makes, and it is not defeated by the application's role
/// escalation.
///
/// Note: only DIRECTLY assigned roles are read. A role that merely includes
/// ETLWizard_Approver is not detected - assign the role itself.
ClassMethod CanApprove(Output why As %String) As %Boolean
{
    Set why = ""
    Set user = $Username
    If (user = "") || (user = "UnknownUser") {
        Set why = "the request is not authenticated, so no human can be named as the approver"
        Return 0
    }
    Try {
        New $NAMESPACE
        Set $NAMESPACE = "%SYS"
        If '##class(Security.Users).Exists(user) {
            Set why = "user " _ user _ " is not a known account on this instance"
            Return 0
        }
        $$$ThrowOnError(##class(Security.Users).Get(user, .props))
        Set roles = "," _ $Get(props("Roles")) _ ","
        If (roles [ ",ETLWizard_Approver,") || (roles [ ",ETLWizard_Admin,") || (roles [ ",%All,") {
            Return 1
        }
        Set why = "user " _ user _ " does not hold ETLWizard_Approver"
    } Catch ex {
        Set why = "could not read the roles of " _ user _ ": " _ ex.DisplayString()
        Return 0
    }
    Return 0
}

/// Persist the pending approval + emit approval.requested (also used by tests).
ClassMethod RequestApproval(runId As %String, toolName As %String, argsJson As %String, Output approvalId As %String) As %Status
{
    Set sc = $$$OK
    Set approvalId = ""
    Try {
        Set run = ##class(ETLWizard.Model.Run).%OpenId(runId)
        If '$IsObject(run) {
            Return $$$ERROR($$$GeneralError, "Run not found: " _ runId)
        }
        Set approval = ##class(ETLWizard.Model.PendingApproval).%New()
        Set approval.Run = run
        Set approval.Tool = toolName
        Set approval.ArgsJson = argsJson
        Set sc = approval.%Save()
        If $$$ISERR(sc) {
            Return sc
        }
        Set approvalId = approval.%Id()
        Set args = {}
        Try {
            Set args = ##class(%DynamicObject).%FromJSON(argsJson)
        } Catch {
        }
        Set sc = ##class(ETLWizard.Model.Event).Append(runId, "approval.requested", "",
            {"approvalId": (approvalId), "tool": (toolName), "args": (args)})
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

ClassMethod ExpireApproval(approvalId As %String, runId As %String) [ Internal ]
{
    Try {
        Set approval = ##class(ETLWizard.Model.PendingApproval).%OpenId(approvalId)
        If $IsObject(approval), approval.Status = "pending" {
            Set approval.Status = "expired"
            Set approval.ResolvedAt = $ZDateTime($ZTimeStamp, 3, , 3)
            Do approval.%Save()
            Do ##class(ETLWizard.Model.Event).Append(runId, "approval.resolved", "",
                {"approvalId": (approvalId), "status": "expired"})
        }
    } Catch {
    }
}

}
