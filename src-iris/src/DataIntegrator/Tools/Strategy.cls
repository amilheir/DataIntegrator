/// Strategy recommendation engine (spec §9). Deterministic rules produce the
/// scores; the agent only narrates them (spec §27.4.5). Read-only, no gate.
Class ETLWizard.Tools.Strategy Extends %AI.Tool
{

/// Recommend load strategies from structured facts. factsJson keys (all
/// optional): rowCount (int), hasPK (0/1), hasReliableTimestamp (0/1),
/// hasIncreasingId (0/1), historyPolicy (latest_state|snapshot|append_audit),
/// deletesTracked (0/1), frequency (daily|hourly|weekly|once),
/// sourceType (jdbc|csv|rest), auditRequired (0/1).
/// Returns the spec §9 contract: scored options with reason, required
/// capabilities/artifacts and risks, best first.
Method RecommendStrategy(factsJson As %String) As %String
{
    Try {
        Set f = {}
        Try {
            Set f = ##class(%DynamicObject).%FromJSON(factsJson)
        } Catch {
            Return "ERROR: factsJson must be a JSON object"
        }
        Set rowCount = +f.%Get("rowCount", -1)
        Set hasPK = +f.%Get("hasPK", 0)
        Set hasTs = +f.%Get("hasReliableTimestamp", 0)
        Set hasSeq = +f.%Get("hasIncreasingId", 0)
        Set history = f.%Get("historyPolicy", "latest_state")
        Set audit = +f.%Get("auditRequired", 0)
        Set source = $ZConvert(f.%Get("sourceType", "jdbc"), "L")

        Set recs = []

        // Incremental Timestamp Load (+ Merge/Upsert when PK + latest_state)
        If hasTs {
            Set score = 70 + $Select(hasPK: 15, 1: 0) + $Select(history = "latest_state": 9, 1: 0)
            Set mode = $Select(hasPK && (history = "latest_state"): "Incremental Timestamp Load + Merge/Upsert", 1: "Incremental Timestamp Load")
            Do recs.%Push({
                "strategy": (mode), "score": (score),
                "reason": "Reliable last-updated timestamp column allows loading changed rows only.",
                "requiredSourceCapabilities": ["reliable updated-at column", "stable primary key"],
                "requiredArtifacts": ["Foreign Server", "Foreign Table", "Landing", "Staging", "Target", "Upsert SQL", "Watermark Metadata"],
                "risks": ["timestamp not set on bulk backfills - reconcile counts periodically"]})
        }

        // Incremental Numeric Watermark
        If hasSeq {
            Do recs.%Push({
                "strategy": "Incremental Numeric Watermark Load", "score": (60 + $Select(hasTs: 0, 1: 20)),
                "reason": "Increasing id/sequence column supports incremental extraction.",
                "requiredSourceCapabilities": ["strictly increasing numeric column"],
                "requiredArtifacts": ["Foreign Server", "Foreign Table", "Landing", "Staging", "Target", "Watermark Metadata"],
                "risks": ["updates to existing rows are invisible - inserts only"]})
        }

        // Merge/Upsert standalone
        If hasPK && (history = "latest_state") && ('hasTs) {
            Do recs.%Push({
                "strategy": "Merge/Upsert (full compare)", "score": 55,
                "reason": "Stable PK and latest-state target, but no change-tracking column: upsert everything.",
                "requiredSourceCapabilities": ["stable primary key"],
                "requiredArtifacts": ["Foreign Table", "Staging", "Target", "Upsert SQL"],
                "risks": ["reads the full source every run"]})
        }

        // Snapshot
        If history = "snapshot" {
            Do recs.%Push({
                "strategy": "Snapshot Load", "score": 80,
                "reason": "History policy is snapshot: periodic point-in-time copies into dated tables.",
                "requiredSourceCapabilities": [],
                "requiredArtifacts": ["Foreign Table", "Snapshot Target Tables"],
                "risks": ["storage grows with every run"]})
        }

        // Append-only audit
        If (history = "append_audit") || audit {
            Do recs.%Push({
                "strategy": "Append-Only Load + Audit Tables", "score": (75 + (audit * 10)),
                "reason": "Auditability required: never update or delete loaded rows.",
                "requiredSourceCapabilities": [],
                "requiredArtifacts": ["Foreign Table", "Landing", "Append Target", "Audit Tables"],
                "risks": ["duplicates unless an idempotency key is enforced"]})
        }

        // CSV file arrival
        If source = "csv" {
            Do recs.%Push({
                "strategy": "CSV Incremental by File Arrival", "score": 78,
                "reason": "File-drop source: process new files by name/arrival, then archive.",
                "requiredSourceCapabilities": ["dated file names or arrival tracking"],
                "requiredArtifacts": ["CSV Foreign Server", "CSV Foreign Table", "Landing", "Target", "File Registry"],
                "risks": ["reprocessing on file rename; late files"]})
        }

        // Full load - always possible, scores well only for small tables
        Set fullScore = $Select(rowCount < 0: 40, rowCount <= 10000: 65, rowCount <= 1000000: 35, 1: 15)
        If 'hasTs, 'hasSeq {
            Set fullScore = fullScore + 15
        }
        Do recs.%Push({
            "strategy": "Full Load", "score": (fullScore),
            "reason": ($Select(rowCount >= 0: "Row count " _ rowCount _ ". ", 1: "") _ "Truncate and reload everything each run - simple and always correct, inefficient for large sources."),
            "requiredSourceCapabilities": [],
            "requiredArtifacts": ["Foreign Table", "Target", "Truncate+Insert SQL"],
            "risks": ["load window grows with source size", "target briefly empty during reload"]})

        // Sort by score descending (simple insertion into a new array)
        Set sorted = []
        Set n = recs.%Size()
        For i = 1:1:n {
            Set best = -1
            Set bestIdx = -1
            For j = 0:1:(n - 1) {
                Set r = recs.%Get(j)
                If $IsObject(r), r.score > best {
                    Set best = r.score
                    Set bestIdx = j
                }
            }
            If bestIdx >= 0 {
                Do sorted.%Push(recs.%Get(bestIdx))
                Do recs.%Set(bestIdx, "")
            }
        }
        Return {"recommendations": (sorted)}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

}
