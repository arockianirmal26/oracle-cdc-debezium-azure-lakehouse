-- Fills the SALES schema with a believable starting dataset:
--   25 customers, 40 orders, ~80 order items.
-- Deliberately tiny: every row can be checked by eye as it moves through the
-- pipeline. For load tests, raise c_customers / c_orders below.
-- DBMS_RANDOM.SEED makes every fresh database get the same data.

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = SALES;

-- The seed sets each order's total with an UPDATE after inserting its items.
-- With the trigger on, every order would get LAST_UPDATED = "now" instead of a
-- plausible historic value. So it's off during the seed and switched back on below.
ALTER TRIGGER orders_touch DISABLE;

DECLARE
    TYPE t_list IS TABLE OF VARCHAR2(60);

    first_names t_list := t_list('Lena', 'Jonas', 'Mia', 'Felix', 'Hannah', 'Lukas', 'Emma',
                                 'Paul', 'Sophie', 'Maximilian', 'Leonie', 'Elias', 'Ayşe',
                                 'Mehmet', 'Katarzyna', 'Tomasz', 'Giulia', 'Marco', 'Anja', 'Dirk');
    last_names  t_list := t_list('Müller', 'Schmidt', 'Schneider', 'Fischer', 'Weber', 'Meyer',
                                 'Wagner', 'Becker', 'Hoffmann', 'Schäfer', 'Koch', 'Yılmaz',
                                 'Kowalski', 'Rossi', 'Neumann', 'Schwarz', 'Zimmermann',
                                 'Braun', 'Krüger', 'Hartmann');
    cities      t_list := t_list('Berlin', 'Hamburg', 'München', 'Köln', 'Frankfurt am Main',
                                 'Stuttgart', 'Düsseldorf', 'Leipzig', 'Dortmund', 'Bremen',
                                 'Nürnberg', 'Wien', 'Zürich', 'Mönchengladbach');
    statuses    t_list := t_list('DELIVERED', 'DELIVERED', 'DELIVERED', 'SHIPPED', 'PAID',
                                 'NEW', 'CANCELLED');
    skus        t_list := t_list('KB-MX-BRN-DE', 'MS-ERGO-L', 'MON-27-4K', 'DOCK-USBC-12',
                                 'HS-ANC-700', 'CAB-HDMI-2M', 'SSD-NVME-2TB', 'LAP-STAND-AL',
                                 'WEBCAM-1080', 'CHAIR-MESH-V2');

    c_customers CONSTANT PLS_INTEGER := 25;
    c_orders    CONSTANT PLS_INTEGER := 40;

    v_first   VARCHAR2(60);
    v_last    VARCHAR2(60);
    v_email   VARCHAR2(120);
    v_city    VARCHAR2(60);
    v_country CHAR(2);
    v_status  VARCHAR2(12);
    v_sku     VARCHAR2(20);
    v_date    DATE;
    v_items   PLS_INTEGER;
    v_total   NUMBER;
    v_price   NUMBER;
    v_qty     PLS_INTEGER;

    -- picks a random element from a list.
    -- Local functions can't be called inside SQL statements, so every random
    -- value is computed into a variable first and the INSERTs only use variables.
    -- (PL/SQL also wants all variables declared before any local function.)
    FUNCTION pick(l t_list) RETURN VARCHAR2 IS
    BEGIN
        RETURN l(TRUNC(DBMS_RANDOM.VALUE(1, l.COUNT + 1)));
    END;
BEGIN
    DBMS_RANDOM.SEED(42);

    -- Customers. About 1 in 8 has no email, 1 in 20 no city (so no country beyond the DE default).
    FOR i IN 1 .. c_customers LOOP
        v_first := pick(first_names);
        v_last  := pick(last_names);

        v_email := NULL;
        IF DBMS_RANDOM.VALUE >= 0.125 THEN
            v_email := LOWER(TRANSLATE(v_first || '.' || v_last, 'äöüßşıçğ', 'aoussicg'))
                       || i || '@' || pick(t_list('web.de', 'gmx.de', 'gmail.com', 't-online.de'));
        END IF;

        v_city := CASE WHEN DBMS_RANDOM.VALUE < 0.05 THEN NULL ELSE pick(cities) END;
        v_country := CASE v_city WHEN 'Wien' THEN 'AT' WHEN 'Zürich' THEN 'CH' ELSE 'DE' END;

        INSERT INTO customers (customer_id, customer_no, first_name, last_name, email, city,
                               country_code, created_at, last_updated)
        VALUES (i, 'K-' || LPAD(100000 + i, 7, '0'), v_first, v_last, v_email, v_city, v_country,
                SYSTIMESTAMP - NUMTODSINTERVAL(DBMS_RANDOM.VALUE(400, 1500), 'DAY'),
                SYSTIMESTAMP - NUMTODSINTERVAL(DBMS_RANDOM.VALUE(1, 400), 'DAY'));
    END LOOP;

    -- Orders spread over the last two years, each with 1-3 items.
    -- The order total is the sum of its items, like a real shop would store it.
    FOR o IN 1 .. c_orders LOOP
        v_date   := TRUNC(SYSDATE) - TRUNC(DBMS_RANDOM.VALUE(0, 730));
        v_status := pick(statuses);
        v_items  := TRUNC(DBMS_RANDOM.VALUE(1, 4));
        v_total  := 0;

        INSERT INTO orders (order_id, customer_id, order_date, status, total_amount, last_updated)
        VALUES (o, TRUNC(DBMS_RANDOM.VALUE(1, c_customers + 1)), v_date, v_status, 0,
                CAST(v_date AS TIMESTAMP) + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0, 72), 'HOUR'));

        FOR it IN 1 .. v_items LOOP
            v_sku   := pick(skus);
            v_qty   := TRUNC(DBMS_RANDOM.VALUE(1, 4));
            v_price := ROUND(DBMS_RANDOM.VALUE(9.99, 649), 2);
            v_total := v_total + v_qty * v_price;
            INSERT INTO order_items (order_id, product_sku, quantity, unit_price, last_updated)
            VALUES (o, v_sku, v_qty, v_price, CAST(v_date AS TIMESTAMP));
        END LOOP;

        UPDATE orders SET total_amount = v_total WHERE order_id = o;

        IF MOD(o, 5000) = 0 THEN COMMIT; END IF;  -- only matters for larger seeds
    END LOOP;

    COMMIT;
END;
/

ALTER TRIGGER orders_touch ENABLE;

-- Identity columns were filled with explicit ids above, so move the sequences
-- past them; otherwise the next app insert would collide with existing keys.
ALTER TABLE customers MODIFY customer_id GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE orders    MODIFY order_id    GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);

EXEC DBMS_STATS.GATHER_SCHEMA_STATS('SALES');
