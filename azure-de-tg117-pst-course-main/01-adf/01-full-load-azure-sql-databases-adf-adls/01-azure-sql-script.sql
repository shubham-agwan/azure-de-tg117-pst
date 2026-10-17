/* =========================================================
   DATABASE SETUP
   Run this section while connected to the master database
   ========================================================= */

IF DB_ID(N'inventory') IS NULL
BEGIN
    CREATE DATABASE inventory;
END;
GO

/* =========================================================
   TABLE: customers
   Purpose:
   - Source table for Spark incremental ingestion
   - Uses lastmodified for CDC
   - Uses isDeleted for soft deletes
   ========================================================= */

DROP TRIGGER IF EXISTS dbo.trg_customers_lastmodified;
GO

DROP TABLE IF EXISTS dbo.customers;
GO

CREATE TABLE dbo.customers (
    customer_id   VARCHAR(50)  NOT NULL,
    first_name    VARCHAR(100) NOT NULL,
    last_name     VARCHAR(100) NOT NULL,
    email         VARCHAR(150) NULL,
    address       VARCHAR(255) NULL,
    phone_number  VARCHAR(30)  NULL,

    -- Soft delete flag: 0 = active, 1 = deleted
    isDeleted     BIT NOT NULL
        CONSTRAINT DF_customers_isDeleted DEFAULT (0),

    -- CDC column: auto-populated on INSERT
    -- For Azure SQL / Spark pipelines, UTC time is recommended
    lastmodified  DATETIME2(3) NOT NULL
        CONSTRAINT DF_customers_lastmodified DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT PK_customers PRIMARY KEY (customer_id)
);
GO

/*
   Azure SQL unique constraint behavior differs from MySQL for NULLs.
   This filtered unique index allows multiple NULL emails,
   but enforces uniqueness when email is present.
*/
CREATE UNIQUE INDEX UX_customers_email
ON dbo.customers(email)
WHERE email IS NOT NULL;
GO


/* =========================================================
   TRIGGER: trg_customers_lastmodified
   Purpose:
   - Replaces MySQL:
     ON UPDATE CURRENT_TIMESTAMP
   - Automatically updates lastmodified on UPDATE
   ========================================================= */

CREATE TRIGGER dbo.trg_customers_lastmodified
ON dbo.customers
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Prevent recursive trigger execution
    IF TRIGGER_NESTLEVEL() > 1
        RETURN;

    UPDATE c
    SET lastmodified = SYSUTCDATETIME()
    FROM dbo.customers c
    INNER JOIN inserted i
        ON c.customer_id = i.customer_id;
END;
GO


/* =========================================================
   TABLE: cdc_tracking
   Purpose:
   - Stores last processed timestamp per table
   - Used as a bookmark for Spark incremental loads
   ========================================================= */

DROP TABLE IF EXISTS dbo.cdc_tracking;
GO

CREATE TABLE dbo.cdc_tracking (
    table_name    VARCHAR(100) NOT NULL,
    lastmodified  DATETIME2(3) NOT NULL,

    CONSTRAINT PK_cdc_tracking PRIMARY KEY (table_name)
);
GO


/* =========================================================
   SEED CDC BOOKMARK
   Purpose:
   - Initial load marker for customers table
   - Replaces MySQL ON DUPLICATE KEY UPDATE
   ========================================================= */

IF NOT EXISTS (
    SELECT 1
    FROM dbo.cdc_tracking
    WHERE table_name = 'customers'
)
BEGIN
    INSERT INTO dbo.cdc_tracking (table_name, lastmodified)
    VALUES ('customers', '1970-01-01T00:00:00.000');
END;
GO


/* =========================================================
   CDC DEMO OPERATIONS
   ========================================================= */


/* ---------------------------------------------------------
   INSERT: New customers
   - lastmodified auto-populated
   --------------------------------------------------------- */

INSERT INTO dbo.customers (
    customer_id,
    first_name,
    last_name,
    email,
    address,
    phone_number
)
VALUES
('C001', 'Amit',  'Sharma', 'amit@example.com',  'Pune',   '9999990001'),
('C002', 'Neha',  'Patil',  'neha@example.com',  'Mumbai', '9999990002'),
('C003', 'Rohit', 'Joshi',  'rohit@example.com', 'Nagpur', '9999990003');
GO


/* ---------------------------------------------------------
   UPDATE: Existing customer
   - Trigger updates lastmodified
   --------------------------------------------------------- */

UPDATE dbo.customers
SET address = 'Pune - Hinjewadi',
    phone_number = '8888881111'
WHERE customer_id = 'C001';
GO


/* ---------------------------------------------------------
   SOFT DELETE: Mark customer as deleted
   - No physical DELETE
   - Trigger updates lastmodified
   --------------------------------------------------------- */

UPDATE dbo.customers
SET isDeleted = 1
WHERE customer_id = 'C002';
GO


/* ---------------------------------------------------------
   OPTIONAL: Restore soft-deleted customer
   - Trigger updates lastmodified
   --------------------------------------------------------- */

UPDATE dbo.customers
SET isDeleted = 0
WHERE customer_id = 'C002';
GO


/* =========================================================
   VERIFICATION QUERIES
   ========================================================= */

SELECT *
FROM dbo.customers;
GO

SELECT *
FROM dbo.cdc_tracking;
GO