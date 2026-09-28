/// Typed request carrying run context between production hosts (spec §4.3).
/// What the Visual Trace displays for each pipeline run.
Class ETLWizard.Msg.ExtractBatch Extends Ens.Request
{

Property PipelineId As %String [ Required ];

Property RunId As %String [ Required ];

Property BaseName As %String [ Required ];

/// The single mounted foreign table for simple pipelines. Empty for custom
/// transform pipelines (which read from the TransformSql SELECT instead), so
/// this is intentionally NOT required.
Property ForeignTable As %String;

Property WatermarkColumn As %String;

/// full | incremental | snapshot | append | csv_arrival
Property Mode As %String [ InitialExpression = "incremental" ];

/// CSV foreign server (csv_arrival strategy only)
Property CsvServer As %String;

/// CSV column definition list (csv_arrival strategy only)
Property ColumnDefs As %String(MAXLEN = 2000);

/// Custom transform SELECT (joins/cleansing/derivation/aggregation/filtering)
Property TransformSql As %String(MAXLEN = "");

}
