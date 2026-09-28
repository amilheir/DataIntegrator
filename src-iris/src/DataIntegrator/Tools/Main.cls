/// Composed ToolSet for the architect agent (spec §10.2).
/// P1 scope: Catalog + SourceDiscovery + CsvProfiling (read-only) and
/// ForeignTable (DDL, gated by requires_auth -> DataIntegrator.Policy.Auth).
/// Domain ToolSets for Strategy/Transformation/Load/DataQuality/Deployment
/// land in P2.
/// NOTE (build 161+): this class must be compiled AFTER its <Include> targets
/// — iris.script recompiles it last.
Class DataIntegrator.Tools.Main Extends %AI.ToolSet [ DependsOn = (DataIntegrator.Tools.Catalog, DataIntegrator.Tools.SourceDiscovery, DataIntegrator.Tools.CsvProfiling, DataIntegrator.Tools.Strategy, DataIntegrator.Tools.Transformation, DataIntegrator.Tools.DataQuality, DataIntegrator.Tools.ForeignTable, DataIntegrator.Tools.Indexing, DataIntegrator.Tools.Load, DataIntegrator.Tools.Production, DataIntegrator.Tools.RestIngestion) ]
{

XData Definition
{
<ToolSet>
    <Description>ETL/ELT wizard tools for InterSystems IRIS</Description>
    <Policies>
        <Audit Class="DataIntegrator.Policy.Audit"/>
        <Authorization Class="DataIntegrator.Policy.Auth"/>
    </Policies>
    <Include Class="DataIntegrator.Tools.Catalog"></Include>
    <Include Class="DataIntegrator.Tools.SourceDiscovery"></Include>
    <Include Class="DataIntegrator.Tools.CsvProfiling"></Include>
    <Include Class="DataIntegrator.Tools.Strategy"></Include>
    <Include Class="DataIntegrator.Tools.Transformation"></Include>
    <Include Class="DataIntegrator.Tools.DataQuality"></Include>
    <Include Class="DataIntegrator.Tools.ForeignTable">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <!-- Indexing: only the DDL verb (CreateIndexes) is gated, via the
         Policy.Auth verb list, so profiling/recommending stays ungated -->
    <Include Class="DataIntegrator.Tools.Indexing"></Include>
    <Include Class="DataIntegrator.Tools.Load">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <Include Class="DataIntegrator.Tools.Production">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <!-- Gated verbs (GenerateRestClient, RunRestCursorLoad) are enforced by
         the Policy.Auth verb list so the read-only tools stay ungated -->
    <Include Class="DataIntegrator.Tools.RestIngestion"></Include>
</ToolSet>
}

}
