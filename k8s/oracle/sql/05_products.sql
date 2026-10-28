-- Small product catalog: 10 rows, one per SKU used in SALES.ORDER_ITEMS.
--
-- Its size makes it the table for developing and testing the CDC pipeline:
-- the initial snapshot is 10 events, and every manual change is easy to follow
-- end to end. The other tables are captured by changing Debezium's table list.
--
-- Runs once as SYS when the database is first created (after 04_cdc_setup.sh,
-- which creates C##DBZUSER).

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = SALES;

CREATE TABLE products (
    product_sku   VARCHAR2(20)  PRIMARY KEY,
    product_name  VARCHAR2(80)  NOT NULL,
    category      VARCHAR2(30)  NOT NULL,
    list_price    NUMBER(10, 2) NOT NULL,
    in_stock      NUMBER(5)     DEFAULT 0 NOT NULL,
    last_updated  TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE OR REPLACE TRIGGER products_touch BEFORE UPDATE ON products
FOR EACH ROW BEGIN :new.last_updated := SYSTIMESTAMP; END;
/

INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('KB-MX-BRN-DE',  'Mechanical keyboard, brown switches, DE layout', 'Peripherals', 129.00,  42);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('MS-ERGO-L',     'Ergonomic mouse, large',                         'Peripherals',  79.90, 118);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('MON-27-4K',     '27" 4K monitor, USB-C',                          'Displays',    449.00,   7);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('DOCK-USBC-12',  'USB-C dock, 12 ports',                           'Accessories', 219.00,  23);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('HS-ANC-700',    'Noise-cancelling headset',                       'Audio',       249.00,   0);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('CAB-HDMI-2M',   'HDMI 2.1 cable, 2 m',                            'Accessories',  14.99, 560);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('SSD-NVME-2TB',  'NVMe SSD 2 TB',                                  'Storage',     139.00,  64);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('LAP-STAND-AL',  'Laptop stand, aluminium',                        'Accessories',  49.00,  95);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('WEBCAM-1080',   'Webcam 1080p',                                   'Peripherals',  59.00,  31);
INSERT INTO products (product_sku, product_name, category, list_price, in_stock) VALUES ('CHAIR-MESH-V2', 'Office chair, mesh back',                        'Furniture',   389.00,   4);
COMMIT;

-- Same CDC preparation as the other captured tables (see 04_cdc_setup.sh):
-- full before/after images in redo, and read access for the snapshot.
ALTER TABLE products ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
GRANT SELECT, FLASHBACK ON products TO c##dbzuser;
