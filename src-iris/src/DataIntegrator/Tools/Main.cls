/// Composed ToolSet for the architect agent (spec §10.2).
/// P1 scope: Catalog + SourceDiscovery + CsvProfiling (read-only) and
/// ForeignTable (DDL, gated by requires_auth -> ETLWizard.Policy.Auth).
/// Domain ToolSets for Strategy/Transformation/Load/DataQuality/Deployment
/// land in P2.
/// NOTE (build 161+): this class must be compiled AFTER its <Include> targets
/// — iris.script recompiles it last.
Class ETLWizard.Tools.Main Extends %AI.ToolSet [ DependsOn = (ETLWizard.Tools.Catalog, ETLWizard.Tools.SourceDiscovery, ETLWizard.Tools.CsvProfiling, ETLWizard.Tools.Strategy, ETLWizard.Tools.Transformation, ETLWizard.Tools.DataQuality, ETLWizard.Tools.ForeignTable, ETLWizard.Tools.Indexing, ETLWizard.Tools.Load, ETLWizard.Tools.Production, ETLWizard.Tools.RestIngestion) ]
{

XData Definition
{
<ToolSet>
    <Description>ETL/ELT wizard tools for InterSystems IRIS</Description>
    <Policies>
        <Audit Class="ETLWizard.Policy.Audit"/>
        <Authorization Class="ETLWizard.Policy.Auth"/>
    </Policies>
    <Include Class="ETLWizard.Tools.Catalog"></Include>
    <Include Class="ETLWizard.Tools.SourceDiscovery"></Include>
    <Include Class="ETLWizard.Tools.CsvProfiling"></Include>
    <Include Class="ETLWizard.Tools.Strategy"></Include>
    <Include Class="ETLWizard.Tools.Transformation"></Include>
    <Include Class="ETLWizard.Tools.DataQuality"></Include>
    <Include Class="ETLWizard.Tools.ForeignTable">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <!-- Indexing: only the DDL verb (CreateIndexes) is gated, via the
         Policy.Auth verb list, so profiling/recommending stays ungated -->
    <Include Class="ETLWizard.Tools.Indexing"></Include>
    <Include Class="ETLWizard.Tools.Load">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <Include Class="ETLWizard.Tools.Production">
        <Requirement Name="requires_auth" Value="1"/>
    </Include>
    <!-- Gated verbs (GenerateRestClient, RunRestCursorLoad) are enforced by
         the Policy.Auth verb list so the read-only tools stay ungated -->
    <Include Class="ETLWizard.Tools.RestIngestion"></Include>
</ToolSet>
}

}
