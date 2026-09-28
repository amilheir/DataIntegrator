/// Resolves %AI.Provider instances from the named LLM profiles (spec §4.1, §27.1).
/// This is the ONLY place provider wiring happens, so AI Hub EAP churn is
/// absorbed here. Profiles are named <configName> and hold e.g.:
///   {"model_provider":"nim","model":"dataintegrator-qwen","base_url":"http://host.docker.internal:11434/v1"}
///   {"model_provider":"anthropic","model":"claude-...","api_key":"secret://..."}
///
/// Where a profile lives: the Config Store entry AI.LLM.<configName> when IRIS
/// accepts it, otherwise ^DataIntegrator("llm", <configName>). This AI Hub build
/// refuses to CREATE any new AI.LLM.* name (ERROR #26414 "No descriptor found for
/// AI.LLM") - only entries that already existed in a volume keep working. A
/// fresh volume, or a renamed profile, therefore can never get a Config Store
/// entry, and every LLM feature would fail with ERROR #5809. The global is the
/// fallback; note that it cannot resolve secret:// references, so a cloud
/// profile stored there must carry a usable api_key itself.
Class DataIntegrator.Agent.ProviderFactory Extends %RegisteredObject
{

ClassMethod GetProviderForConfig(configName As %String, Output provider As %RegisteredObject, Output model As %String) As %Status
{
    Set sc = $$$OK
    Set provider = ""
    Set model = ""
    Try {
        Set sc = ..GetProfile(configName, .details)
        If $$$ISERR(sc) {
            Return sc
        }
        Set provider = ##class(%AI.Provider).Create(details."model_provider", details)
        Set model = details."model"
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Return sc
}

/// The profile's details (secrets resolved when it comes from the Config Store).
ClassMethod GetProfile(configName As %String, Output details As %DynamicObject) As %Status
{
    Set details = ""
    Set sc = $$$OK
    Try {
        Set sc = ##class(%ConfigStore.Configuration).GetDetails("AI.LLM." _ configName, .details, 0, 1)
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    If $$$ISOK(sc) && $IsObject(details) {
        Return sc
    }
    Set json = $Get(^DataIntegrator("llm", configName))
    If json = "" {
        Set msg = "LLM profile '" _ configName _ "' is not configured (neither Config Store AI.LLM." _
            configName _ " nor ^DataIntegrator(""llm"",""" _ configName _ """))"
        Return $$$ERROR($$$GeneralError, msg)
    }
    Try {
        Set details = ##class(%DynamicObject).%FromJSON(json)
    } Catch ex {
        Return ex.AsStatus()
    }
    Return $$$OK
}

/// Create or replace a profile. Tries the Config Store first and falls back to
/// the global when IRIS refuses the entry - see the class comment. Exactly one
/// of the two holds the profile afterwards, so GetProfile never reads a stale copy.
ClassMethod SaveProfile(configName As %String, config As %DynamicObject) As %Status
{
    Try {
        Do ##class(%ConfigStore.Configuration).Delete("AI.LLM." _ configName)
    } Catch {
        // no previous entry - fine
    }
    Set sc = $$$OK
    Try {
        Set sc = ##class(%ConfigStore.Configuration).Create("AI", "LLM", "", configName, config)
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    If $$$ISOK(sc) {
        Kill ^DataIntegrator("llm", configName)
        Return sc
    }
    Set ^DataIntegrator("llm", configName) = config.%ToJSON()
    Return $$$OK
}

}
