-- =====================================================================
-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q7_Water_Meter_Readings_and_Billing.sql
-- Tariff: first 10 units K5 each; units above 10 cost K8 each.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

CREATE TABLE customers (
    customer_id  SERIAL       PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL        PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers (customer_id),
    reading_month     DATE          NOT NULL,
    previous_reading  NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_first_day CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      SERIAL        PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings (reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE          PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES
    ('Kondwani Phiri'), ('Mercy Daka'), ('Francis Mwamba');

-- ---------------------------------------------------------------------
-- (b) Function fn_water_charge
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative, got %', p_units;
    END IF;

    -- units up to 10 at K5, units above 10 at K8; zero units => zero
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger on readings (created BEFORE loading readings)
--     BEFORE trigger raising an exception => the row is never stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_reading ON readings;
CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- ---------------------------------------------------------------------
-- (c) Procedure pr_generate_bill
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12,2);
    v_curr   NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);      -- consumption = current - previous

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ---------------------------------------------------------------------
-- (e) View: v_overdue_bills
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name   AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- ---------------------------------------------------------------------
-- (f) Index for date-based searches of overdue (unpaid) bills
--     Partial index: contains only bills that are not fully paid, ordered by due_on,
--     so a "due before date X and unpaid" search reads a small, sorted index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_receivables (replaces today's row on rerun)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 00:30
SELECT cron.schedule(
    'water_refresh_receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables()$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six readings: 0 units, exactly 10, and above 10
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100,  100),   --  0 units  -> K0
    (1, DATE '2026-10-01', 100,  110),   -- 10 units  -> K50
    (2, DATE '2026-09-01',  50,   65),   -- 15 units  -> K50 + 5*8  = K90
    (2, DATE '2026-10-01',  65,   90),   -- 25 units  -> K50 + 15*8 = K170
    (3, DATE '2026-09-01',   0,    8),   --  8 units  -> K40
    (3, DATE '2026-10-01',   8,   30);   -- 22 units  -> K50 + 12*8 = K146

-- (d) Rejected reading is not stored (uncomment to test)
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--   VALUES (1, DATE '2026-11-01', 110, 100);     -- ERROR: current below previous
-- UPDATE readings SET current_reading = 1 WHERE reading_id = 2;   -- ERROR (direct SQL)

-- (b)
SELECT fn_water_charge(0)  AS zero_units,     -- 0.00
       fn_water_charge(10) AS ten_units,      -- 50.00
       fn_water_charge(15) AS fifteen_units;  -- 90.00
-- SELECT fn_water_charge(NULL);   -- ERROR
-- SELECT fn_water_charge(-1);     -- ERROR

-- (c) Generate bills: September readings are overdue, October ones not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);
-- CALL pr_generate_bill(1, CURRENT_DATE);    -- ERROR: already has a bill
-- CALL pr_generate_bill(99, CURRENT_DATE);   -- ERROR: unknown reading

-- Some payments: customer 2's September bill part-paid; customer 3's fully paid
UPDATE bills SET amount_paid = 40 WHERE reading_id = 3;
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;

SELECT * FROM bills ORDER BY bill_id;

-- (e)
SELECT * FROM v_overdue_bills ORDER BY due_on, customer_name;   -- only Mercy (K50 outstanding)

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Rerun-safe snapshot
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;      -- one row for today

SELECT jobid, jobname, schedule, command, active FROM cron.job;
