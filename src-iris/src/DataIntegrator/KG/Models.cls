Include %occStatus

/// The model picker's data (mds/knowledge-graph-tab-plan.md §6.3).
///
/// Reads Ollama directly rather than a hardcoded list, so a newly pulled model
/// appears without a code change, and annotates each with what it will actually
/// do on this GPU.
///
/// That annotation is the point. A model too large for the GPU produces no
/// error and no warning - Ollama loads it, offloads part of it to CPU, and
/// answers an order of magnitude slower. Measured here: gemma4:e4b sits fully
/// on the GPU and still took 204 s on an extraction the coder did in 40 s, so
/// even "fits" is not a promise of speed. Fit is necessary, not sufficient.
Class ETLWizard.KG.Models Extends %RegisteredObject
{

/// Usable VRAM on this machine, in bytes. Measured: an 8,188 MiB card with the
/// display holding ~375 MiB.
Parameter USABLEVRAM = 8375000000;

/// Everything Ollama has, plus the two current selections.
ClassMethod List() As %DynamicObject
{
    Try {
        Set err = ##class(ETLWizard.KG.Setup).EmbedEndpoint(.baseUrl, .embedModel)
        If err '= "" {
            Return {"error": (err)}
        }
        Set tags = ..Get(baseUrl, "/api/tags", .tagErr)
        If tagErr '= "" {
            Return {"error": ("could not reach Ollama at " _ baseUrl _ ": " _ tagErr)}
        }
        // What is loaded right now, and how much of it is on the GPU
        Set ps = ..Get(baseUrl, "/api/ps", .psErr)
        Kill resident
        Set usedVram = 0
        If (psErr = "") && $IsObject(ps) && $IsObject(ps.%Get("models")) {
            Set iter = ps.models.%GetIterator()
            While iter.%GetNext(, .m) {
                Set resident($ZConvert(m.name, "L")) = +m.%Get("size_vram", 0)
                Set usedVram = usedVram + +m.%Get("size_vram", 0)
            }
        }
        Set free = ..#USABLEVRAM - usedVram

        Set out = []
        If $IsObject(tags) && $IsObject(tags.%Get("models")) {
            Set iter = tags.models.%GetIterator()
            While iter.%GetNext(, .m) {
                Set name = m.name
                Set diskSize = +m.%Get("size", 0)
                Set key = $ZConvert(name, "L")
                Set isResident = $Data(resident(key))
                Set vram = $Get(resident(key), 0)
                Do out.%Push({
                    "id": (name),
                    "sizeGB": (##class(ETLWizard.KG.Setup).Round(diskSize / 1000000000, 2)),
                    "residentGB": ($Select(isResident: ##class(ETLWizard.KG.Setup).Round(vram / 1000000000, 2), 1: "")),
                    "loaded": (''isResident),
                    "note": (..Note(name, diskSize, isResident, vram, free))})
            }
        }
        Return {"models": (out),
                "chatModel": (##class(ETLWizard.KG.Setup).GetChatModel()),
                "extractModel": (##class(ETLWizard.KG.Setup).GetExtractModel()),
                "embedModel": (embedModel),
                "usedVramGB": (##class(ETLWizard.KG.Setup).Round(usedVram / 1000000000, 2)),
                "usableVramGB": (##class(ETLWizard.KG.Setup).Round(..#USABLEVRAM / 1000000000, 2))}
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
}

/// The one line the user reads before choosing.
///
/// Deliberately never predicts VRAM from file size: measured on this instance,
/// a dense qwen2 model needed 1.07x its file size while gemma4:e4b needed
/// 0.34x, because its per-layer embeddings stay out of the working set. A
/// prediction from file size would have called the best instruct model here
/// "too large". So an unloaded model is reported as unknown, honestly.
ClassMethod Note(name As %String, diskSize As %Integer, isResident As %Boolean, vram As %Integer, free As %Integer) As %String [ Internal ]
{
    If isResident {
        If vram = 0 {
            Return "loaded, running on CPU - slow"
        }
        Return "loaded, " _ ##class(ETLWizard.KG.Setup).Round(vram / 1000000000, 2) _ " GB on GPU"
    }
    If diskSize < free {
        Return "not loaded - should fit in the " _ ##class(ETLWizard.KG.Setup).Round(free / 1000000000, 1) _ " GB free"
    }
    // File size over free VRAM is a WARNING, not a verdict: gemma4:e4b is
    // 9.61 GB on disk and runs in 3.23 GB.
    Return "not loaded - " _ ##class(ETLWizard.KG.Setup).Round(diskSize / 1000000000, 1) _
        " GB on disk against " _ ##class(ETLWizard.KG.Setup).Round(free / 1000000000, 1) _ " GB free; load it to see the real cost"
}

/// GET a JSON endpoint on the Ollama host.
ClassMethod Get(baseUrl As %String, path As %String, Output err As %String) As %DynamicObject [ Internal ]
{
    Set err = ""
    Try {
        Set req = ##class(%Net.HttpRequest).%New()
        Set req.Server = $Piece($Piece(baseUrl, "://", 2), ":", 1)
        Set req.Port = +$Piece($Piece(baseUrl, "://", 2), ":", 2)
        Set req.Https = ($Piece(baseUrl, "://", 1) = "https")
        Set req.Timeout = 20
        Set sc = req.Get(path)
        If $$$ISERR(sc) {
            Set err = $System.Status.GetErrorText(sc)
            Return {}
        }
        If req.HttpResponse.StatusCode '= 200 {
            Set err = "HTTP " _ req.HttpResponse.StatusCode
            Return {}
        }
        Return ##class(%DynamicAbstractObject).%FromJSON(req.HttpResponse.Data)
    } Catch ex {
        Set err = ex.DisplayString()
        Return {}
    }
}

}
