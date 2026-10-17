1. Run Section 1 to Section 6 before building/running ADF CDC pipeline.
2. Run ADF CDC pipeline once.
3. Then run Section 7 to simulate insert/update/soft delete.
4. Run ADF CDC pipeline again.
5. Use Section 8 to verify results.

/* =====================================================================
   Azure Data Factory CDC Prototype - Azure SQL Setup Script
   Table: dbo.customers
   CDC Type: Query-based CDC using lastmodified watermark
   ===================================================================== */


/* =====================================================================
   SECTION 1: Check Current Database
   ===================================================================== */

SELECT DB_NAME() AS current_database;


/* =====================================================================
   SECTION 2: Optional Cleanup for Fresh Demo
   ---------------------------------------------------------------------
   Use this only if you want to reset the demo completely.
   Comment this section if you already have useful data.
   ===================================================================== */

-- DROP PROCEDURE IF EXISTS dbo.usp_update_adf_watermark;
-- DROP TABLE IF EXISTS dbo.adf_cdc_watermark;
-- DROP TABLE IF EXISTS dbo.customers;


/* =====================================================================
   SECTION 3: Create Customers Table
   ---------------------------------------------------------------------
   This is the source table for ADF CDC.
   lastmodified is the watermark column.
   isDeleted is used for soft delete detection.
   ===================================================================== */

IF OBJECT_ID('dbo.customers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.customers (
        customer_id INT PRIMARY KEY,
        first_name VARCHAR(50),
        last_name VARCHAR(50),
        email VARCHAR(100),
        address VARCHAR(200),
        phone_number VARCHAR(20),
        isDeleted BIT DEFAULT 0,
        lastmodified DATETIME2(3) NOT NULL
    );
END;


/* =====================================================================
   SECTION 4: Insert Initial Customer Data
   ---------------------------------------------------------------------
   These are the records that should be copied in the first CDC run.
   Initial watermark will be 1900-01-01, so first CDC run will copy all.
   ===================================================================== */

IF NOT EXISTS (SELECT 1 FROM dbo.customers WHERE customer_id = 1)
BEGIN
    INSERT INTO dbo.customers
    (customer_id, first_name, last_name, email, address, phone_number, isDeleted, lastmodified)
    VALUES
    (1, 'Amit',  'Sharma', 'amit@example.com',  'Pune',      '9876543210', 0, SYSUTCDATETIME()),
    (2, 'Priya', 'Verma',  'priya@example.com', 'Mumbai',    '9876543211', 0, SYSUTCDATETIME()),
    (3, 'Rahul', 'Patil',  'rahul@example.com', 'Nagpur',    '9876543212', 0, SYSUTCDATETIME()),
    (4, 'Sneha', 'Joshi',  'sneha@example.com', 'Bengaluru', '9876543213', 0, SYSUTCDATETIME());
END;


/* =====================================================================
   SECTION 5: Create Watermark Table
   ---------------------------------------------------------------------
   ADF will read this table to know the last successful watermark.
   ===================================================================== */

IF OBJECT_ID('dbo.adf_cdc_watermark', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.adf_cdc_watermark (
        source_table VARCHAR(100) PRIMARY KEY,
        watermark_column VARCHAR(100),
        last_watermark DATETIME2(3),
        updated_at DATETIME2(3)
    );
END;


/* =====================================================================
   SECTION 6: Insert Initial Watermark
   ---------------------------------------------------------------------
   The old watermark is set to 1900-01-01 so that first run copies all rows.
   ===================================================================== */

IF NOT EXISTS (
    SELECT 1
    FROM dbo.adf_cdc_watermark
    WHERE source_table = 'customers'
)
BEGIN
    INSERT INTO dbo.adf_cdc_watermark
    (source_table, watermark_column, last_watermark, updated_at)
    VALUES
    ('customers', 'lastmodified', '1900-01-01T00:00:00.000', SYSUTCDATETIME());
END;


/* =====================================================================
   SECTION 7: Create Stored Procedure to Update Watermark
   ---------------------------------------------------------------------
   ADF Stored Procedure Activity will call this procedure after successful copy.
   This procedure updates last_watermark with the new max(lastmodified).
   ===================================================================== */

EXEC('
CREATE OR ALTER PROCEDURE dbo.usp_update_adf_watermark
    @source_table VARCHAR(100),
    @new_watermark VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.adf_cdc_watermark
    SET
        last_watermark = CAST(@new_watermark AS DATETIME2(3)),
        updated_at = SYSUTCDATETIME()
    WHERE source_table = @source_table
      AND @new_watermark IS NOT NULL;
END;
');


/* =====================================================================
   SECTION 8: Verify Setup Before ADF Run 1
   ---------------------------------------------------------------------
   Run these queries before the first ADF CDC pipeline run.
   ===================================================================== */

SELECT
    customer_id,
    first_name,
    last_name,
    email,
    address,
    phone_number,
    isDeleted,
    lastmodified
FROM dbo.customers
ORDER BY customer_id;


SELECT
    source_table,
    watermark_column,
    last_watermark,
    updated_at
FROM dbo.adf_cdc_watermark;


/* =====================================================================
   IMPORTANT:
   ---------------------------------------------------------------------
   Stop here before running ADF for the first time.

   Now run the ADF CDC pipeline once.

   Expected Run 1 Output:
   - All existing customers should be copied to ADLS.
   - Watermark should update to MAX(lastmodified) from dbo.customers.

   After ADF Run 1 succeeds, continue with SECTION 9.
   ===================================================================== */


/* =====================================================================
   SECTION 9: Simulate CDC Changes for ADF Run 2
   ---------------------------------------------------------------------
   Run this section only after ADF CDC pipeline Run 1 succeeds.

   This section creates:
   1. One UPDATE
   2. One INSERT
   3. One SOFT DELETE
   ===================================================================== */

-- 1. Update existing customer
UPDATE dbo.customers
SET
    phone_number = '9999999999',
    lastmodified = SYSUTCDATETIME()
WHERE customer_id = 2;


-- 2. Insert new customer
IF NOT EXISTS (SELECT 1 FROM dbo.customers WHERE customer_id = 5)
BEGIN
    INSERT INTO dbo.customers
    (customer_id, first_name, last_name, email, address, phone_number, isDeleted, lastmodified)
    VALUES
    (5, 'Kiran', 'Deshmukh', 'kiran@example.com', 'Nashik', '9876543214', 0, SYSUTCDATETIME());
END;


-- 3. Soft delete existing customer
UPDATE dbo.customers
SET
    isDeleted = 1,
    lastmodified = SYSUTCDATETIME()
WHERE customer_id = 4;


/* =====================================================================
   SECTION 10: Verify Changes Before ADF Run 2
   ---------------------------------------------------------------------
   These rows should be picked in the second ADF CDC run:
   customer_id = 2  → updated
   customer_id = 5  → inserted
   customer_id = 4  → soft deleted
   ===================================================================== */

SELECT
    customer_id,
    first_name,
    last_name,
    email,
    address,
    phone_number,
    isDeleted,
    lastmodified
FROM dbo.customers
ORDER BY lastmodified DESC;


SELECT
    source_table,
    watermark_column,
    last_watermark,
    updated_at
FROM dbo.adf_cdc_watermark;


/* =====================================================================
   IMPORTANT:
   ---------------------------------------------------------------------
   Now run the ADF CDC pipeline again.

   Expected Run 2 Output:
   Only these changed rows should be copied to ADLS:
   - customer_id = 2
   - customer_id = 5
   - customer_id = 4

   After ADF Run 2 succeeds, run SECTION 11.
   ===================================================================== */


/* =====================================================================
   SECTION 11: Final Verification After ADF Run 2
   ===================================================================== */

SELECT
    source_table,
    watermark_column,
    last_watermark,
    updated_at
FROM dbo.adf_cdc_watermark;


SELECT
    customer_id,
    first_name,
    last_name,
    email,
    address,
    phone_number,
    isDeleted,
    lastmodified
FROM dbo.customers
ORDER BY customer_id;


/* =====================================================================
   SECTION 12: Optional Query to Manually See Delta Rows
   ---------------------------------------------------------------------
   Use this only for understanding.
   Replace the timestamp manually with your old watermark if needed.
   ===================================================================== */

-- SELECT *
-- FROM dbo.customers
-- WHERE lastmodified > 'PASTE_OLD_WATERMARK_HERE'
-- ORDER BY lastmodified;


/* =====================================================================
   SECTION 13: Notes for Students
   ---------------------------------------------------------------------
   Query-based CDC detects:
   - Inserts
   - Updates
   - Soft deletes, if isDeleted changes and lastmodified updates

   Query-based CDC does not detect:
   - Hard deletes
   - Updates where lastmodified is not changed
   - Multiple intermediate updates between two runs
   ===================================================================== */