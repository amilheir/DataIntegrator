-- ONS hourly load curve (Curva de Carga Horaria), dataset curva-carga-ho.
-- Source: https://ons-aws-prod-opendata.s3.amazonaws.com/dataset/curva-carga-ho/
-- Feeds the grid demand forecast demo (mds/demo-grid-demand-forecast.md).
--
-- NOT to be confused with dataset carga_energia_di / CARGA_ENERGIA_YYYY.csv,
-- which is the DAILY series and whose value column is val_cargaenergiamwmed
-- (no "ho"). The daily file loads cleanly and then silently produces one
-- matching row per day when joined to hourly weather.
--
-- Column order matches the CSV exactly -- \copy maps by position, not by name,
-- so reordering these columns breaks the load with a type error on din_instante.
--
-- varchar, not text: the AI Hub 162 JDBC foreign-table auto-import silently
-- skips postgres text columns (see README EAP caveats). numeric is fine.
-- Unquoted snake_case throughout, matching 02_sample_schema.sql -- the local
-- model writing the demo's SQL "corrects" anything else into SQL that does not
-- compile.

CREATE TABLE IF NOT EXISTS public.ons_carga (
    id_subsistema           VARCHAR(4)  NOT NULL,
    nom_subsistema          VARCHAR(40),
    din_instante            TIMESTAMP   NOT NULL,
    val_cargaenergiahomwmed NUMERIC(12,3)
);

-- The demo's pipeline 2 self-joins the IRIS target three times at -24h, -48h
-- and -168h; the watermark reads this column on every incremental run.
CREATE INDEX IF NOT EXISTS ix_ons_carga_inst ON public.ons_carga (din_instante);
CREATE INDEX IF NOT EXISTS ix_ons_carga_sub  ON public.ons_carga (id_subsistema);
