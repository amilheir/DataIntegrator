/// Clock for the sample-data feed. A Business Operation only runs when a
/// message arrives, so the "every minute" part lives here: an adapterless poll
/// service whose CallInterval fires once a minute and sends one request to
/// ETLWizard.Host.SampleDataOperation.
Class ETLWizard.Host.SampleDataTick Extends Ens.BusinessService
{

Parameter ADAPTER = "Ens.InboundAdapter";

/// Config item name of the operation that generates the rows
Property TargetOperation As %String [ InitialExpression = "SampleData_Generate" ];

Parameter SETTINGS = "TargetOperation:Basic";

Method OnProcessInput(pInput As %RegisteredObject, Output pOutput As %RegisteredObject) As %Status
{
    Set req = ##class(Ens.Request).%New()
    Return ..SendRequestSync(..TargetOperation, req, .resp)
}

}
