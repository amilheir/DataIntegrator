/// Per-pipeline incremental-load watermark (spec §7, §12.1).
/// Updated only on successful runs; resumable/reprocessable by range (spec §15, §17).
Class ETLWizard.Model.Watermark Extends %Persistent
{

Property Pipeline As ETLWizard.Model.Pipeline [ Required ];

Property Type As %String(VALUELIST = ",timestamp,numeric") [ Required ];

/// Source column the watermark tracks (named ColumnName: COLUMN is an SQL reserved word)
Property ColumnName As %String(MAXLEN = 128) [ Required ];

Property LastValue As %String(MAXLEN = 256);

Property UpdatedByRun As ETLWizard.Model.Run;

Property UpdatedAt As %TimeStamp;

Index PipelineIdx On Pipeline [ Unique ];

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.pipelineId = ..Pipeline.%Id()
    Set json.type = ..Type
    Set json.column = ..ColumnName
    Set json.lastValue = ..LastValue
    Set json.updatedAt = ..UpdatedAt
    Return json
}

}
