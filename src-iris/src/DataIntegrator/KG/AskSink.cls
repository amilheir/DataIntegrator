/// The Knowledge Base chat's half of the streaming story.
///
/// The ETL agent streams over the WebSocket hub, which has a sequence and a
/// replay cursor, so it can emit deltas. This chat has no such thing: a question
/// is a row in ETLW_KG.Ask and the UI polls it, because the model takes tens of
/// seconds and the Web Gateway does not wait that long.
///
/// A poll is not an ordered stream. It can miss a beat, coalesce two, or land
/// twice - so this sink writes the answer CUMULATIVELY into `Ask.answerSoFar`.
/// Whatever a poll happens to catch is the whole answer so far, and a missed
/// poll costs nothing. One UPDATE of one row, not a row per token.
Class ETLWizard.KG.AskSink Extends ETLWizard.Agent.StreamSink
{

Property AskId As %String;

Method StartAsk(askId As %String, minChars As %Integer = 24, minMs As %Integer = 250)
{
    Do ..Start("", 0, minChars, minMs)
    Set ..AskId = askId
}

/// `text` is this batch; ..Text is everything so far, and that is what a
/// polling client needs.
Method Emit(text As %String)
{
    Do ##class(ETLWizard.Tools.Util).RunDML(
        "UPDATE ETLW_KG.Ask SET answerSoFar = ?, updatedAt = ? WHERE %ID = ?",
        $Extract(..Text, 1, 30000), $ZDateTime($Horolog, 3), ..AskId)
}

}
