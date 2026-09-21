-- postgres-init/04_olist.sql
-- varchar everywhere — AI Hub 162 JDBC silently skips Postgres `text` columns.
-- product_name_lenght: intentional typo from source data, do not fix.

CREATE TABLE public.olist_orders (
    order_id                      VARCHAR(40) PRIMARY KEY,
    customer_id                   VARCHAR(40) NOT NULL,
    order_status                  VARCHAR(20),
    order_purchase_timestamp      TIMESTAMP,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

CREATE TABLE public.olist_order_items (
    order_id            VARCHAR(40) NOT NULL,
    order_item_id       INTEGER     NOT NULL,
    product_id          VARCHAR(40),
    seller_id           VARCHAR(40),
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(12,2),
    freight_value       NUMERIC(12,2),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE public.olist_customers (
    customer_id              VARCHAR(40) PRIMARY KEY,
    customer_unique_id       VARCHAR(40),
    customer_zip_code_prefix INTEGER,
    customer_city            VARCHAR(60),
    customer_state           VARCHAR(4)
);

CREATE TABLE public.olist_sellers (
    seller_id              VARCHAR(40) PRIMARY KEY,
    seller_zip_code_prefix INTEGER,
    seller_city            VARCHAR(60),
    seller_state           VARCHAR(4)
);

CREATE TABLE public.olist_products (
    product_id                 VARCHAR(40) PRIMARY KEY,
    product_category_name      VARCHAR(80),
    product_name_lenght        INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           NUMERIC(12,2),
    product_length_cm          NUMERIC(12,2),
    product_height_cm          NUMERIC(12,2),
    product_width_cm           NUMERIC(12,2)
);

CREATE INDEX ix_items_order  ON public.olist_order_items (order_id);
CREATE INDEX ix_orders_purch ON public.olist_orders (order_purchase_timestamp);
