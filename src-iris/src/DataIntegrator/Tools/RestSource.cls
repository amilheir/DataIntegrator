/// REST (JSON) source: several endpoints of one API, each landed raw and then
/// exposed as an ordinary table, so the wizard's existing transform step can
/// join them into a single target exactly as it does for JDBC/ODBC tables.
///
///   GET /customers ──► ETLW_LANDING.<base>_<ep>_raw (payload + run/ts)
///                 └──► ETLWIZARD.<base>_<ep>  (VIEW via JSON_TABLE)
///
/// Two layers on purpose: the landing table keeps the untouched payload (so a
/// reload replays without re-fetching, and a field appearing upstream can never
/// break ingestion), while the view carries the column map the user approved.
/// JSON_TABLE reads the payload column laterally — verified on 2026.3 build 125.
///
/// HTTP runs in embedded Python: it gives TLS without an IRIS SSL configuration
/// (%Net.HttpRequest cannot reach https:// on this instance) plus gzip, which
/// IBGE returns whether or not you ask for it.
Class ETLWizard.Tools.RestSource Extends %AI.Tool [ DependsOn = ETLWizard.Tools.Util ]
{

/// Rows fetched per endpoint in one load, across all pages.
Parameter MAXROWS = 5000;

Parameter MAXPAGES = 50;

/// SQL reserved words that cannot be used bare as a generated column name.
/// ("when" is the one a real payload hit first.)
Parameter RESERVED = "WHEN,WHERE,SELECT,FROM,ORDER,GROUP,BY,AS,IS,IN,ON,AND,OR,NOT,NULL,TABLE,VIEW,INDEX,KEY,VALUE,VALUES,CASE,END,THEN,ELSE,LEFT,RIGHT,FULL,JOIN,UNION,DISTINCT,TOP,INTO,SET,USER,DATE,TIME,TIMESTAMP,YEAR,MONTH,DAY,COUNT,SUM,MIN,MAX,AVG,DATA,LEVEL,SIZE,LANGUAGE,PUBLIC,ROLE,ADD,ALL,ANY,BETWEEN,CHECK,CURRENT,DEFAULT,DELETE,DROP,EXISTS,FOR,GRANT,HAVING,INNER,INSERT,LIKE,OUTER,PRIMARY,REFERENCES,UNIQUE,UPDATE,USING";

/// Fetch one page and report what came back: a sample of items plus the column
/// map inferred from them. Read-only — nothing is stored. This is what the
/// wizard's per-endpoint "Test" button calls.
ClassMethod ProbeEndpoint(url As %String, dataPath As %String = "", headers As %String = "", maxSample As %Integer = 5) As %String [ Language = python ]
{
    import iris, json
    from urllib.parse import urlsplit

    fetch = iris.cls('ETLWizard.Tools.RestSource')
    raw = fetch.HttpGet(url, headers)
    if raw.startswith("ERROR"):
        return raw
    try:
        doc = json.loads(raw)
    except Exception as e:
        return "ERROR: the response is not JSON: " + str(e)[:120]

    items, used_path = fetch.ExtractItems(doc, dataPath)
    if isinstance(items, str):
        return items
    columns = json.loads(fetch.InferColumns(json.dumps(items[:50])))
    return json.dumps({
        "url": url,
        "dataPath": used_path,
        "itemsOnPage": len(items),
        "columns": columns,
        "sample": items[:maxSample],
    })
}

/// GET a URL and return the body, decompressing gzip and following redirects.
/// headers is "Name: value" per line (an Authorization line goes here).
ClassMethod HttpGet(url As %String, headers As %String = "", timeout As %Integer = 30) As %String [ Language = python ]
{
    import gzip, urllib.request, urllib.error
    hdrs = {"Accept": "application/json", "User-Agent": "InterSystems-ETLWizard/1.0"}
    for line in (headers or "").splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            if k.strip():
                hdrs[k.strip()] = v.strip()
    try:
        req = urllib.request.Request(url, headers=hdrs)
        with urllib.request.urlopen(req, timeout=int(timeout)) as r:
            body = r.read()
            # 204/empty is a legitimate "no rows" answer (INMET does this)
            if not body:
                return "[]"
            if body[:2] == b"\x1f\x8b":
                body = gzip.decompress(body)
            return body.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return "ERROR: HTTP %s from %s" % (e.code, url)
    except Exception as e:
        return "ERROR: %s: %s" % (type(e).__name__, str(e)[:140])
}

/// Pull the array of items out of a decoded document. With no dataPath, walk
/// the document for the first array of objects, so a bare array (IBGE) and a
/// wrapped one ({"data":[...]}, {"products":[...]}) both just work.
/// Returns (items, path) or an "ERROR: ..." string.
ClassMethod ExtractItems(doc As %SYS.Python, dataPath As %String = "") As %SYS.Python [ Language = python ]
{
    def is_rows(v):
        return isinstance(v, list) and (not v or isinstance(v[0], dict))

    def as_columns(v):
        """Pivot a COLUMN-oriented block into rows.

        Time-series and metrics APIs commonly answer with parallel arrays
        rather than one object per row - open-meteo returns
        {"hourly": {"time": [...168], "temperature_2m": [...168]}}, the same
        table transposed. Without this the wizard reports "no array of objects
        found" and no dataPath rescues it: "hourly" is an object, and
        "hourly.time" is a bare list that drops every other measure.

        Only a dict whose values are ALL equal-length arrays of scalars
        qualifies. That excludes "hourly_units" (scalars, not arrays) and
        anything holding nested objects or arrays, which are a different grain
        and belong in their own view.
        """
        if not isinstance(v, dict) or not v:
            return None
        lengths = set()
        for val in v.values():
            if not isinstance(val, list):
                return None
            if val and isinstance(val[0], (dict, list)):
                return None
            lengths.add(len(val))
        if len(lengths) != 1:
            return None
        n = lengths.pop()
        if n == 0:
            return None
        keys = list(v.keys())
        return [dict((k, v[k][i]) for k in keys) for i in range(n)]

    if dataPath:
        # "$.data[*]" / "data" / "$.a.b[*]" -> walk the dotted key path
        path = dataPath.replace("$", "").replace("[*]", "").strip(". ")
        node = doc
        for part in [p for p in path.split(".") if p]:
            if isinstance(node, dict) and part in node:
                node = node[part]
            else:
                return ("ERROR: dataPath '%s' does not exist in the response" % dataPath, dataPath)
        if not isinstance(node, list):
            rows = as_columns(node)
            if rows is not None:
                return (rows, dataPath)
            return ("ERROR: dataPath '%s' is not an array, and not a block of "
                    "equal-length columns either" % dataPath, dataPath)
        return (node, dataPath)

    if is_rows(doc):
        return (doc, "$[*]")
    if isinstance(doc, dict):
        for k, v in doc.items():
            if is_rows(v):
                return (v, "$.%s[*]" % k)
        for k, v in doc.items():                      # one level deeper
            if isinstance(v, dict):
                for k2, v2 in v.items():
                    if is_rows(v2):
                        return (v2, "$.%s.%s[*]" % (k, k2))
    # nothing row-shaped: look for a column-oriented block instead
    rows = as_columns(doc)
    if rows is not None:
        return (rows, "$")
    if isinstance(doc, dict):
        for k, v in doc.items():
            rows = as_columns(v)
            if rows is not None:
                return (rows, "$.%s" % k)
    return ("ERROR: no array of objects, and no block of equal-length columns, "
            "found in the response - set the data path by hand", "")
}

/// Infer a column map from sample items: SQL name, JSON path, SQL type.
/// Scalars at the top level become columns; a nested object contributes its
/// scalars as parent_child. Nested ARRAYS are skipped - they are a different
/// grain and belong in their own view.
ClassMethod InferColumns(itemsJson As %String) As %String [ Language = python ]
{
    import iris, json, re
    from datetime import datetime

    items = json.loads(itemsJson)
    helper = iris.cls('ETLWizard.Tools.RestSource')
    cols, seen = [], set()

    def sql_type(values):
        vals = [v for v in values if v is not None and v != ""]
        if not vals:
            return "VARCHAR(200)"
        if all(isinstance(v, bool) for v in vals):
            return "BIT"
        if all(isinstance(v, int) and not isinstance(v, bool) for v in vals):
            return "BIGINT"
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in vals):
            return "NUMERIC(19,6)"
        strs = [str(v) for v in vals]
        # Both forms are TIMESTAMP: the generated VIEW normalises the string
        # ("2026-09-01T00:00" -> "2026-09-01 00:00:00") before casting, so a
        # value IRIS could not convert on its own still lands as a real
        # timestamp - usable by MIN/MAX and as an AutoML time-series column.
        if all(re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", s) for s in strs):
            return "TIMESTAMP"
        if all(re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", s) for s in strs):
            return "TIMESTAMP"
        if all(re.match(r"^\d{4}-\d{2}-\d{2}$", s) for s in strs):
            return "DATE"
        width = max(len(s) for s in strs)
        return "VARCHAR(%d)" % max(50, min(4000, width * 3))

    # a key that is not a plain identifier must be quoted in the JSON path:
    # IBGE ships "regiao-imediata", and a bare hyphen is a path syntax error
    def seg(key):
        return key if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) else '"%s"' % key.replace('"', '')

    def walk(prefix_name, prefix_path, sample_objs, depth):
        keys = []
        for o in sample_objs:
            for k in (o or {}):
                if k not in keys:
                    keys.append(k)
        for k in keys:
            values = [o.get(k) for o in sample_objs if isinstance(o, dict)]
            nested = [v for v in values if isinstance(v, dict)]
            if nested and depth < 2:
                walk((prefix_name + "_" if prefix_name else "") + k,
                     prefix_path + "." + seg(k), nested, depth + 1)
                continue
            if any(isinstance(v, list) for v in values):
                continue                                   # different grain
            name = helper.SqlName((prefix_name + "_" if prefix_name else "") + k)
            if name in seen:
                continue
            seen.add(name)
            cols.append({"name": name, "path": prefix_path + "." + seg(k), "type": sql_type(values)})

    walk("", "$", [i for i in items if isinstance(i, dict)], 0)
    return json.dumps(cols)
}

/// Fetch an endpoint (all pages, within the row/page caps), land the raw pages,
/// and (re)create the view that shreds them into columns.
/// cfg: {"url","dataPath","headers","pagination":{"style":"none|offset|cursor",
///       "pageSize":n,"limitParam","offsetParam","cursorParam","cursorField"},
///       "columns":[{"name","path","type"}]}
/// Returns {"table","landing","rows","pages","columns"} or "ERROR: ...".
ClassMethod MountEndpoint(runId As %String, baseName As %String, endpoint As %String, cfgJson As %String) As %String
{
    Try {
        If '##class(ETLWizard.Tools.Util).ValidIdent(baseName) {
            Return "ERROR: invalid baseName"
        }
        Set ep = ..SqlName(endpoint)
        Set local = baseName _ "_" _ ep
        If $Length(local) > 60 {
            Set local = $Extract(baseName, 1, 25) _ "_" _ $Extract(ep, 1, 30)
        }
        Set landing = "ETLW_LANDING." _ local _ "_raw"
        Set view = "ETLWIZARD." _ local

        Set cfg = ##class(%DynamicObject).%FromJSON(cfgJson)
        If '$IsObject(cfg.columns) || (cfg.columns.%Size() = 0) {
            Return "ERROR: no column map - probe the endpoint first"
        }
        // pull the pages before touching anything: a dead endpoint must not
        // leave a half-built landing table behind
        Set pagesJson = ..FetchPages(cfgJson)
        If $Extract(pagesJson, 1, 5) = "ERROR" {
            Return pagesJson
        }
        Set pages = ##class(%DynamicArray).%FromJSON(pagesJson)

        Set util = "ETLWizard.Tools.Util"
        Do $ClassMethod(util, "RunDDL", "DROP VIEW " _ view)
        Do $ClassMethod(util, "RunDDL", "DROP TABLE " _ landing)
        Set err = $ClassMethod(util, "RunDDL",
            "CREATE TABLE " _ landing _ " (etl_run_id VARCHAR(50), etl_load_ts TIMESTAMP, " _
            "etl_source VARCHAR(500), payload VARCHAR(3000000))")
        If err '= "" {
            Return err
        }
        Set rows = 0
        Set it = pages.%GetIterator()
        While it.%GetNext(.i, .page) {
            Set res = $ClassMethod(util, "RunDML",
                "INSERT INTO " _ landing _ " (etl_run_id, etl_load_ts, etl_source, payload) VALUES (?, ?, ?, ?)",
                runId, $ZDateTime($ZTimeStamp, 3, , 3), cfg.url, page.items.%ToJSON())
            If $Extract(res, 1, 5) = "ERROR" {
                Return res
            }
            Set rows = rows + page.items.%Size()
        }
        // the view is where the column map lives: one JSON_TABLE column per
        // mapped field, read laterally out of the payload of every landed page
        Set cols = "", jt = ""
        Set ci = cfg.columns.%GetIterator()
        While ci.%GetNext(.i, .c) {
            Set name = ..SqlName(c.name)
            If $ZConvert(c.type, "U") = "TIMESTAMP" {
                // JSON carries a STRING, and IRIS only converts the exact form
                // "YYYY-MM-DD HH:MM:SS". Declaring the JSON_TABLE column as
                // TIMESTAMP stores whatever arrived verbatim: "2026-09-01T00:00"
                // then SELECTs fine while MIN/MAX and %EXTERNAL return EMPTY,
                // and AutoML cannot use it as a time-series BY column.
                //
                // So read it as text and normalise in the projection: swap the
                // ISO "T" for a space and add seconds when they are missing.
                // The payload itself stays untouched, which is the whole point
                // of the landing table. A full-form value passes through.
                Set expr = "CAST(CASE WHEN LENGTH(jt." _ name _ ") = 16 " _
                           "THEN REPLACE(jt." _ name _ ", 'T', ' ') || ':00' " _
                           "ELSE REPLACE(jt." _ name _ ", 'T', ' ') END AS TIMESTAMP)"
                Set cols = cols _ $Select(cols = "": "", 1: ", ") _ expr _ " AS " _ name
                Set jt = jt _ $Select(jt = "": "", 1: ", ") _ name _ " VARCHAR(32) PATH '" _ c.path _ "'"
            } Else {
                Set cols = cols _ $Select(cols = "": "", 1: ", ") _ "jt." _ name _ " AS " _ name
                Set jt = jt _ $Select(jt = "": "", 1: ", ") _ name _ " " _ c.type _ " PATH '" _ c.path _ "'"
            }
        }
        Set ddl = "CREATE VIEW " _ view _ " AS SELECT " _ cols _
                  " FROM " _ landing _ " r, JSON_TABLE(r.payload, '$[*]' COLUMNS (" _ jt _ ")) jt"
        Set err = $ClassMethod(util, "RunDDL", ddl)
        If err '= "" {
            Return err
        }
        Do $ClassMethod(util, "CatalogNode", runId, "rest_client", view, ddl,
            {"endpoint": (endpoint), "url": (cfg.url), "dataPath": (cfg.dataPath),
             "landing": (landing), "rows": (rows), "pages": (pages.%Size())}.%ToJSON())
        Return {"table": (view), "landing": (landing), "rows": (rows),
                "pages": (pages.%Size()), "columns": (cfg.columns.%Size())}.%ToJSON()
    } Catch ex {
        Return "ERROR: " _ ex.DisplayString()
    }
}

/// Walk an endpoint's pages and return [{items:[...]}] — one entry per page.
/// Styles: none (one GET), offset (limit/skip or _limit/_page), cursor
/// (the next-cursor field the previous page returned).
ClassMethod FetchPages(cfgJson As %String) As %String [ Language = python ]
{
    import iris, json

    helper = iris.cls('ETLWizard.Tools.RestSource')
    cfg = json.loads(cfgJson)
    url, dataPath, headers = cfg["url"], cfg.get("dataPath", ""), cfg.get("headers", "")
    pg = cfg.get("pagination") or {}
    style = (pg.get("style") or "none").lower()
    size = int(pg.get("pageSize") or 100)
    maxrows = int(helper.MaxRows())
    maxpages = int(helper.MaxPages())

    def with_params(u, extra):
        if not extra:
            return u
        sep = "&" if "?" in u else "?"
        return u + sep + "&".join("%s=%s" % (k, v) for k, v in extra.items())

    pages, total, cursor, offset = [], 0, "", 0
    for page_no in range(maxpages):
        if style == "offset":
            extra = {pg.get("limitParam") or "limit": size, pg.get("offsetParam") or "offset": offset}
        elif style == "cursor":
            extra = {pg.get("sizeParam") or "size": size}
            if cursor not in ("", None):
                extra[pg.get("cursorParam") or "after"] = cursor
        else:
            extra = {}
        raw = helper.HttpGet(with_params(url, extra), headers)
        if raw.startswith("ERROR"):
            return raw if not pages else json.dumps(pages)   # keep what we have
        try:
            doc = json.loads(raw)
        except Exception as e:
            return "ERROR: page %d is not JSON: %s" % (page_no + 1, str(e)[:100])

        items, _ = helper.ExtractItems(doc, dataPath)
        if isinstance(items, str):
            return items
        if not items:
            break
        pages.append({"items": items})
        total += len(items)
        if style == "none" or total >= maxrows or len(items) < size:
            break
        if style == "offset":
            offset += size
        else:
            nxt = doc.get(pg.get("cursorField") or "nextCursor") if isinstance(doc, dict) else None
            if not nxt:
                break
            cursor = nxt
    return json.dumps(pages)
}

ClassMethod MaxRows() As %Integer [ Internal ]
{
    Return ..#MAXROWS
}

ClassMethod MaxPages() As %Integer [ Internal ]
{
    Return ..#MAXPAGES
}

/// A JSON key turned into a safe SQL column name: letters/digits/underscore,
/// never starting with a digit, never a reserved word.
ClassMethod SqlName(key As %String) As %String
{
    Set out = ""
    For i = 1:1:$Length(key) {
        Set ch = $Extract(key, i)
        Set out = out _ $Select($Match(ch, "[A-Za-z0-9_]"): ch, 1: "_")
    }
    Set out = $ZStrip(out, "<>", "_")
    If out = "" {
        Set out = "col"
    }
    If $Match($Extract(out), "[0-9]") {
        Set out = "c_" _ out
    }
    If $ListFind($ListFromString(..#RESERVED, ","), $ZConvert(out, "U")) > 0 {
        Set out = out _ "_"
    }
    Return $Extract(out, 1, 60)
}

}
