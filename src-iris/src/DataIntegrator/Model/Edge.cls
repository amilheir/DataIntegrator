/// A directed edge of the pipeline DAG — lineage between nodes (spec §12.1).
Class ETLWizard.Model.Edge Extends %Persistent
{

Property Pipeline As ETLWizard.Model.Pipeline [ Required ];

Property FromNode As ETLWizard.Model.Node [ Required ];

Property ToNode As ETLWizard.Model.Node [ Required ];

/// Data-movement type / load strategy label shown on the canvas
Property Label As %String(MAXLEN = 128);

Index PipelineIdx On Pipeline;

Method ToJSON() As %DynamicObject
{
    Set json = {}
    Set json.id = ..%Id()
    Set json."from" = ..FromNode.%Id()
    Set json."to" = ..ToNode.%Id()
    Set json.label = ..Label
    Return json
}

}
