/// Typed response from the load operation (spec §4.3).
Class ETLWizard.Msg.LoadResult Extends Ens.Response
{

Property Ok As %Boolean [ InitialExpression = 0 ];

/// Standard load stats envelope (rowsExtracted/rowsStaged/rowsUpserted/watermarks)
Property StatsJson As %String(MAXLEN = "");

Property Error As %String(MAXLEN = 2000);

}
