/// Creates the DATAINTEGRATOR namespace, databases, and web applications
/// for the IRIS AI ETL/ELT Wizard Builder (spec.md §5, §15).
Class App.Installer
{

XData setup
{
<Manifest>
  <Default Name="Namespace" Value="DATAINTEGRATOR"/>
  <Default Name="database" Value="dataintegrator"/>

  <!-- Ensemble="1": every deployed pipeline runs as an Interoperability Production (spec v2.2 §4.3) -->
  <Namespace Name="${Namespace}" Code="${Namespace}-CODE" Data="${Namespace}-DATA" Create="yes" Ensemble="1">
    <Configuration>
      <Database Name="${Namespace}-DATA" Dir="${mgrdir}${database}/data" Create="yes" Resource="%DB_${Namespace}-DATA"/>
      <Database Name="${Namespace}-CODE" Dir="${mgrdir}${database}/code" Create="yes" Resource="%DB_${Namespace}-CODE"/>
    </Configuration>

    <!-- Frontend static files + %CSP.WebSocket class dispatch (DataIntegrator.WS.Hub.cls).
         AuthenticationMethods 96 = Unauthenticated + Password: dev only, locked down in P5 (spec §16). -->
    <CSPApplication Url="/dataintegrator" Directory="/opt/irisbuild/frontend" ServeFiles="1" Recurse="1" AuthenticationMethods="96" MatchRoles=":%All" CookiePath="/dataintegrator"/>

    <!-- REST API (spec §15) -->
    <!-- Recurse=1 is required: without it only single-segment routes reach the dispatcher -->
    <CSPApplication Url="/dataintegrator/api" DispatchClass="DataIntegrator.API.Dispatcher" ServeFiles="0" Recurse="1" AuthenticationMethods="96" MatchRoles=":%All" CookiePath="/dataintegrator/api"/>
  </Namespace>
</Manifest>
}

ClassMethod setup(ByRef pVars, pLogLevel As %Integer = 3, pInstaller As %Installer.Installer, pLogger As %Installer.AbstractLogger) As %Status [ CodeMode = objectgenerator, Internal ]
{
  #; Let XGL document generate code for this method.
  Quit ##class(%Installer.Manifest).%Generate(%compiledclass, %code, "setup")
}

}
