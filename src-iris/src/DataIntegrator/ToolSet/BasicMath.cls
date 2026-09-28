/// Basic Math ToolSet
/// Demonstrates composing math tools into a reusable toolset
/// General-purpose toolset usable in any tool-based integration
Class ETLWizard.ToolSet.BasicMath Extends %AI.ToolSet [ DependsOn = ETLWizard.ToolSet.Tools.Math ]
{
  XData Definition [ MimeType = application/xml ]
  {
    <ToolSet Name="BasicMath">
      <Description>Basic arithmetic operations</Description>

     <!-- No audit policy here on purpose: this toolset is exposed over MCP.
             %AI.Policy.ConsoleAudit writes to the current device, which is the
             HTTP response body during a web request, and corrupts the JSON-RPC
             reply. For persistent auditing, subclass %AI.Policy.Audit. See the
             DatabaseAudit example in the ObjectScript SDK guide. -->

      <!-- Include Math tools -->
      <Include Class="ETLWizard.ToolSet.Tools.Math" />

    </ToolSet>
  }
}