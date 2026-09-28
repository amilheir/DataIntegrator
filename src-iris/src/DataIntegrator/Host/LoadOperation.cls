/// Load Business Operation (spec §4.3): executes the strategy through the
/// SAME Load/DataQuality tool methods the agent and the manual executor use,
/// so counts, watermarks, quarantine and events are produced identically —
/// but here each execution is a traceable, retryable production message.
Class ETLWizard.Host.LoadOperation Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

XData MessageMap
{
<MapItems>
  <MapItem MessageType="ETLWizard.Msg.ExtractBatch">
    <Method>OnLoad</Method>
  </MapItem>
</MapItems>
}

Method OnLoad(pRequest As ETLWizard.Msg.ExtractBatch, Output pResponse As ETLWizard.Msg.LoadResult) As %Status
{
    Set sc = $$$OK
    Set pResponse = ##class(ETLWizard.Msg.LoadResult).%New()
    Try {
        // One dispatch shared with the manual executor (all strategies)
        Set ld = ##class(ETLWizard.Tools.Load).%New()
        Set statsJson = ld.RunPlan(pRequest.RunId, pRequest.BaseName, pRequest.ForeignTable,
            pRequest.Mode, pRequest.WatermarkColumn, pRequest.CsvServer, pRequest.ColumnDefs, pRequest.TransformSql)
        If $Extract(statsJson, 1, 5) = "ERROR" {
            Set pResponse.Ok = 0
            Set pResponse.Error = statsJson
            Return $$$OK
        }
        Set pResponse.Ok = 1
        Set pResponse.StatsJson = statsJson
    } Catch ex {
        Set sc = ex.AsStatus()
        Set pResponse.Ok = 0
        Set pResponse.Error = $System.Status.GetErrorText(sc)
    }
    Return sc
}

}
