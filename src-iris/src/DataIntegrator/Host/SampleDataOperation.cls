/// Business Operation that feeds the Postgres sample schema with fresh random
/// rows — 1 employee, 2 customers and 10 orders per call by default — so the
/// wizard's incremental/watermark pipelines always have something new to pick up.
///
/// The row values come from InterSystems %PopulateUtils (the utility half of
/// %Library.Populate): LastName/FirstName/Name/Company/Date/Integer/ValueList,
/// the same generators %Populate.Populate() uses to fill a persistent class.
/// %Populate itself only writes to IRIS extents, and these tables live in
/// Postgres, so the generators are called directly and the rows are inserted
/// over psycopg2 from embedded Python.
///
/// Insert order is forced by the foreign keys: employee, then customers (which
/// reference an employee), then orders (which reference both).
Class ETLWizard.Host.SampleDataOperation Extends Ens.BusinessOperation
{

Parameter ADAPTER = "Ens.OutboundAdapter";

Parameter INVOCATION = "Queue";

/// Postgres connection — defaults match the compose service
Property PGHost As %String [ InitialExpression = "postgres" ];

Property PGPort As %Integer [ InitialExpression = 5432 ];

Property PGDatabase As %String [ InitialExpression = "crm" ];

Property PGUser As %String [ InitialExpression = "crm" ];

Property PGPassword As %String [ InitialExpression = "crm" ];

Property PGSchema As %String [ InitialExpression = "sample" ];

/// Rows generated per call
Property Employees As %Integer [ InitialExpression = 1 ];

Property Customers As %Integer [ InitialExpression = 2 ];

Property Orders As %Integer [ InitialExpression = 10 ];

Parameter SETTINGS = "PGHost:Postgres,PGPort:Postgres,PGDatabase:Postgres,PGUser:Postgres,PGPassword:Postgres,PGSchema:Postgres,Employees:Volume,Customers:Volume,Orders:Volume";

Method OnMessage(request As Ens.Request, Output response As Ens.StringResponse) As %Status
{
    Set response = ##class(Ens.StringResponse).%New()
    Set result = ..Generate(..PGHost, ..PGPort, ..PGDatabase, ..PGUser, ..PGPassword,
        ..PGSchema, ..Employees, ..Customers, ..Orders)
    If $Extract(result, 1, 5) = "ERROR" {
        Set response.StringValue = result
        $$$LOGERROR(result)
        Return $$$ERROR($$$GeneralError, result)
    }
    // Generate returns the rows it wrote; trace them one per line so the Visual
    // Trace / Event Log shows exactly what landed in Postgres. Traces appear
    // only while "Log Trace Events" is on for this config item.
    Set summary = result
    Try {
        Set detail = ##class(%DynamicObject).%FromJSON(result)
        Set summary = detail.summary
        Do ..TraceRows(detail)
    } Catch {
        // a non-JSON answer is still a usable summary
    }
    Set response.StringValue = summary
    $$$LOGINFO(summary)
    Return $$$OK
}

/// Every generated row in ONE trace: a single block of text listing the batch
/// in insert order, so the Visual Trace shows one entry per tick rather than a
/// dozen lines to scroll through.
Method TraceRows(detail As %DynamicObject) [ Internal ]
{
    Set nl = $Char(13, 10)
    Set text = detail.summary _ nl _
        "target: " _ ..PGDatabase _ "." _ ..PGSchema _ " on " _ ..PGHost _ ":" _ ..PGPort _ nl
    Set kinds = $ListBuild("employees", "customers", "orders")
    For k = 1:1:$ListLength(kinds) {
        Set kind = $List(kinds, k)
        Set list = detail.%Get(kind)
        If '$IsObject(list) {
            Continue
        }
        // pad on the right so the rows line up: $Justify only right-aligns
        Set label = $ZConvert($Extract(kind, 1, *-1), "U")
        Set label = label _ $Justify("", $Select($Length(label) < 9: 9 - $Length(label), 1: 1))
        Set it = list.%GetIterator()
        While it.%GetNext(.i, .row) {
            Set text = text _ nl _ label _ row
        }
    }
    $$$TRACE(text)
}

/// Generate and insert one batch. Returns a JSON object carrying the summary
/// and every row written ({"summary":...,"employees":[...],"customers":[...],
/// "orders":[...]}) so the caller can trace them, or "ERROR: ...".
/// Embedded Python: psycopg2 for the remote DML, %PopulateUtils for the values.
ClassMethod Generate(host As %String, port As %Integer, database As %String, user As %String, password As %String, schema As %String, employees As %Integer, customers As %Integer, orders As %Integer) As %String [ Language = python ]
{
    import iris
    import json
    import psycopg2
    from datetime import datetime

    # %PopulateUtils — the same generators %Populate uses to fill a class
    pop = iris.cls('%PopulateUtils')
    # %Date turns the $HOROLOG integer PopulateUtils returns into YYYY-MM-DD
    isodate = iris.cls('%Library.Date')
    ITEMS = ",Widget,Gadget,Sprocket,Flange,Bearing,Gasket,Valve,Piston,Coupling,Bracket"

    # A bounded random sample of the whole table, plus whatever this call just
    # inserted. LIMIT keeps it cheap as the history grows; the sample is random,
    # so old rows keep their chance of being referenced.
    POOL = 500

    def history(cur, id_column, table, fresh):
        cur.execute(f"SELECT {id_column} FROM {schema}.{table} ORDER BY random() LIMIT {POOL}")
        pool = [r[0] for r in cur.fetchall()]
        for i in fresh:
            if i not in pool:
                pool.append(i)
        return pool

    # index chosen with %PopulateUtils.Integer, like every other random value here
    def pick(pool):
        return pool[pop.Integer(1, len(pool)) - 1] if pool else None

    conn = None
    try:
        conn = psycopg2.connect(host=host, port=int(port), dbname=database,
                                user=user, password=password, connect_timeout=10)
        cur = conn.cursor()

        employee_ids, employee_rows = [], []
        for _ in range(int(employees)):
            last, first, start = pop.LastName(), pop.FirstName(), isodate.LogicalToOdbc(pop.Date())
            cur.execute(
                f"INSERT INTO {schema}.employee (name_last, name_first, start_date) "
                "VALUES (%s, %s, %s) RETURNING employee_id",
                (last, first, start))
            new_id = cur.fetchone()[0]
            employee_ids.append(new_id)
            employee_rows.append(f"employee_id={new_id} name_last={last} name_first={first} start_date={start}")

        # every reference is drawn from the accumulated history (this batch
        # included), not just the rows this call happens to have created
        employee_pool = history(cur, "employee_id", "employee", employee_ids)

        customer_ids, customer_rows = [], []
        for _ in range(int(customers)):
            # PopulateUtils.Name() is "Last,First M." — split it back out so the
            # email looks like something a person would actually have
            full = pop.Name()
            last, _, first = full.partition(',')
            handle = ''.join(c for c in (first.split(' ')[0] + '.' + last) if c.isalnum() or c == '.')
            email = handle.lower() + '@demo.invalid'
            updated = datetime.now()
            owner = pick(employee_pool)
            cur.execute(
                f"INSERT INTO {schema}.customer (name, email, updated_at, employee_id) "
                "VALUES (%s, %s, %s, %s) RETURNING customer_id",
                (full, email, updated, owner))
            new_id = cur.fetchone()[0]
            customer_ids.append(new_id)
            customer_rows.append(
                f"customer_id={new_id} name={full} email={email} "
                f"updated_at={updated:%Y-%m-%d %H:%M:%S} employee_id={owner}")

        # orders draw on the whole history too, so they spread across customers
        # and salespeople from earlier ticks instead of only this batch
        customer_pool = history(cur, "customer_id", "customer", customer_ids)

        order_count, order_rows = 0, []
        if customer_pool and employee_pool:
            for i in range(int(orders)):
                item, qty = pop.ValueList(ITEMS), pop.Integer(1, 25)
                cust = pick(customer_pool)
                sales = pick(employee_pool)
                placed = datetime.now()
                # unit_price and status are NOT optional here. The demo query
                # filters on status='completed' and the ML model predicts it, so
                # a fed row with either column NULL is invisible to both - it
                # would look like the feed silently produced nothing.
                price = pop.Integer(1800, 95800) / 100.0
                status = 'completed' if pop.Integer(1, 100) <= 80 else (
                    'pending' if pop.Integer(1, 100) <= 55 else 'cancelled')
                cur.execute(
                    f"INSERT INTO {schema}.orders (item, quantity, unit_price, status, customer_id, employee_id, ordered_at) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING order_id",
                    (item, qty, price, status, cust, sales, placed))
                new_id = cur.fetchone()[0]
                order_count += 1
                order_rows.append(
                    f"order_id={new_id} item={item} quantity={qty} unit_price={price} status={status} "
                    f"customer_id={cust} employee_id={sales} ordered_at={placed:%Y-%m-%d %H:%M:%S}")

        conn.commit()
        summary = (f"Sample feed: {len(employee_rows)} employee(s), "
                   f"{len(customer_rows)} customer(s), {order_count} order(s) "
                   f"inserted into {database}.{schema}")
        return json.dumps({"summary": summary, "employees": employee_rows,
                           "customers": customer_rows, "orders": order_rows})
    except Exception as e:
        if conn is not None:
            conn.rollback()
        return "ERROR: sample feed failed: " + str(e)
    finally:
        if conn is not None:
            conn.close()
}

}
