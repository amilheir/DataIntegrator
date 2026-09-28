/// Resolves %AI.Provider instances from the IRIS Config Store (spec §4.1, §27.1).
/// This is the ONLY place provider wiring happens, so AI Hub EAP churn is
/// absorbed here. Profiles are Config Store entries named AI.LLM.<configName>:
///   {"model_provider":"nim","model":"etlwizard-qwen","base_url":"http://host.docker.internal:11434/v1"}
///   {"model_provider":"anthropic","model":"claude-...","api_key":"secret://..."}
Class ETLWizard.Agent.ProviderFactory Extends %RegisteredObject
{

ClassMethod GetProviderForConfig(configName As %String, Output provider As %RegisteredObject, Output model As %String) As %Status
{
    Set sc = $$$OK
    Set provider = ""
    Set model = ""
    Try {
        Set sc = ##class(%ConfigStore.Configuration).GetDetails("AI.LLM." _ configName, .details, 0, 1)
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

}
