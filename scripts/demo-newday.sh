#!/bin/sh
# "New day" — make the incremental story provable (IMPROVEMENTS_SPEC DA-3).
#
# Run this BETWEEN two pipeline runs. The second run must then load only what
# this script added, and the reported watermark must advance.
#
# It touches the SOURCE ONLY: postgres and the dropzone. It never talks to IRIS,
# never edits a pipeline, and never sets a watermark by hand — the whole point
# is that the pipeline discovers the change on its own.

set -e

PG_CONTAINER="${PG_CONTAINER:-dataintegrator-postgres-1}"
PG_USER="${PG_USER:-crm}"
PG_DB="${PG_DB:-crm}"
DROPZONE="${DROPZONE:-$(dirname "$0")/../src-iris/dropzone}"

# how many orders to add: 20-80, per the spec's range
NEW_ORDERS="${NEW_ORDERS:-45}"
# how many customer master rows to touch
NEW_CUSTOMERS="${NEW_CUSTOMERS:-8}"

psql() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -A -t -q "$@"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    echo "!! $PG_CONTAINER is not running - start the stack first"
    exit 1
fi

BEFORE_ORDERS=$(psql -c "SELECT count(*) FROM sample.orders")
BEFORE_WM=$(psql -c "SELECT coalesce(max(ordered_at)::text,'(none)') FROM sample.orders")

echo "== adding $NEW_ORDERS orders dated now()"
psql -v ON_ERROR_STOP=1 -c "
INSERT INTO sample.orders (item, quantity, unit_price, status, customer_id, employee_id, ordered_at)
SELECT (ARRAY['Pallet rack','Conveyor belt','Label printer','Barcode scanner',
              'Cold-chain container','Forklift battery','Shrink wrapper',
              'Weighing station','Dock leveller','Tote bin'])[1 + (s.n % 10)],
       1 + (s.n % 25),
       round((18 + (random() * 940))::numeric, 2),
       CASE WHEN random() < 0.9 THEN 'completed' ELSE 'pending' END,
       c.customer_id,
       c.employee_id,
       now() - ((s.n * 7) || ' seconds')::interval
FROM (SELECT n, 1 + floor(500 * power(random(), 3))::int AS cid
      FROM generate_series(1, $NEW_ORDERS) AS n) AS s
JOIN sample.customer c ON c.customer_id = s.cid;" > /dev/null

echo "== touching $NEW_CUSTOMERS customer master rows"
psql -v ON_ERROR_STOP=1 -c "
UPDATE sample.customer
SET updated_at = now()
WHERE customer_id IN (SELECT customer_id FROM sample.customer ORDER BY random() LIMIT $NEW_CUSTOMERS);" > /dev/null

# 3. one more clean CSV in the dropzone, stamped so the CSV-by-file-arrival
#    strategy sees a file it has not loaded before
STAMP=$(date -u +%Y%m%d_%H%M%S)
CSV="$DROPZONE/daily_sales_$STAMP.csv"
echo "== writing $CSV"
printf 'sale_ref,customer_id,customer_name,region,sale_date,item,quantity,unit_price,line_total,status,outcome\n' > "$CSV"
docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -A -t -q -c "
COPY (
  SELECT 'SO-' || lpad(o.order_id::text,6,'0'), o.customer_id, c.name, c.region,
         to_char(o.ordered_at,'YYYY-MM-DD'), o.item, o.quantity, o.unit_price,
         round(o.quantity * o.unit_price, 2), o.status,
         CASE WHEN o.status = 'completed' THEN 'completed' ELSE 'at_risk' END
  FROM sample.orders o JOIN sample.customer c ON c.customer_id = o.customer_id
  WHERE o.ordered_at >= now() - interval '1 hour'
  ORDER BY o.ordered_at
) TO STDOUT WITH (FORMAT csv)" >> "$CSV"
CSV_ROWS=$(( $(wc -l < "$CSV") - 1 ))

AFTER_ORDERS=$(psql -c "SELECT count(*) FROM sample.orders")
AFTER_WM=$(psql -c "SELECT max(ordered_at)::text FROM sample.orders")

echo
echo "-------------------------------------------------------------"
echo " New day applied to the SOURCE only. IRIS was not touched."
echo
echo "   orders   : $BEFORE_ORDERS -> $AFTER_ORDERS  (+$NEW_ORDERS)"
echo "   customers: $NEW_CUSTOMERS rows re-stamped updated_at = now()"
echo "   dropzone : $(basename "$CSV")  ($CSV_ROWS rows)"
echo
echo "   watermark before: $BEFORE_WM"
echo "   watermark after : $AFTER_WM"
echo
echo " Expected on the next pipeline run:"
echo "   incremental_timestamp on ordered_at  -> ~$NEW_ORDERS rows"
echo "   incremental_timestamp on updated_at  -> ~$NEW_CUSTOMERS rows"
echo "   csv_arrival                          -> $CSV_ROWS rows from the new file"
echo "-------------------------------------------------------------"
