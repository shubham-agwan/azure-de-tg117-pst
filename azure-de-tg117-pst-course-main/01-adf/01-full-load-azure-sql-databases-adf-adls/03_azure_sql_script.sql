/* =====================================================================
   Azure Data Factory - Multiple-Table Query-Based CDC Prototype
   Source: Azure SQL Database
   Target: ADLS Gen2
   Tables: dbo.customers, dbo.products, dbo.orders

   IMPORTANT EXECUTION ORDER
   -------------------------
   1. Run Sections 1 to 11 before ADF Run 1.
   2. Build and run the ADF multiple-table CDC pipeline.
   3. Run Sections 12 and 13 after ADF Run 1 succeeds.
   4. Run the ADF pipeline again.
   5. Run Sections 14 to 16 for final verification and discussion.
   ===================================================================== */

/* =====================================================================
   SECTION 1: Confirm the Current Database
   ===================================================================== */
SELECT DB_NAME() AS current_database;

/* =====================================================================
   SECTION 2: Optional Cleanup for a Fresh Demo
   ---------------------------------------------------------------------
   Keep this section commented unless you want to delete the complete demo.
   ===================================================================== */
-- DROP PROCEDURE IF EXISTS dbo.usp_update_adf_watermark;
-- DROP TABLE IF EXISTS dbo.adf_cdc_watermark;
-- DROP TABLE IF EXISTS dbo.adf_cdc_config;
-- DROP TABLE IF EXISTS dbo.orders;
-- DROP TABLE IF EXISTS dbo.products;
-- DROP TABLE IF EXISTS dbo.customers;

/* =====================================================================
   SECTION 3: Create Customers Source Table
   ===================================================================== */
IF OBJECT_ID('dbo.customers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.customers (
        customer_id INT PRIMARY KEY,
        first_name VARCHAR(50) NOT NULL,
        last_name VARCHAR(50) NOT NULL,
        email VARCHAR(100),
        city VARCHAR(100),
        phone_number VARCHAR(20),
        isDeleted BIT NOT NULL DEFAULT 0,
        lastmodified DATETIME2(3) NOT NULL
    );
END;

/* =====================================================================
   SECTION 4: Create Products Source Table
   ===================================================================== */
IF OBJECT_ID('dbo.products', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.products (
        product_id INT PRIMARY KEY,
        product_name VARCHAR(100) NOT NULL,
        category VARCHAR(100),
        unit_price DECIMAL(12,2),
        stock_quantity INT,
        isDeleted BIT NOT NULL DEFAULT 0,
        lastmodified DATETIME2(3) NOT NULL
    );
END;

/* =====================================================================
   SECTION 5: Create Orders Source Table
   ===================================================================== */
IF OBJECT_ID('dbo.orders', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.orders (
        order_id INT PRIMARY KEY,
        customer_id INT NOT NULL,
        product_id INT NOT NULL,
        order_date DATE NOT NULL,
        quantity INT NOT NULL,
        order_status VARCHAR(30),
        order_amount DECIMAL(12,2),
        isDeleted BIT NOT NULL DEFAULT 0,
        lastmodified DATETIME2(3) NOT NULL
    );
END;

/* =====================================================================
   SECTION 6: Insert Initial Source Data
   ---------------------------------------------------------------------
   These rows should be copied during ADF Run 1.
   ===================================================================== */
DECLARE @initial_time DATETIME2(3) = SYSUTCDATETIME();

INSERT INTO dbo.customers
(customer_id, first_name, last_name, email, city, phone_number, isDeleted, lastmodified)
SELECT v.customer_id, v.first_name, v.last_name, v.email, v.city,
       v.phone_number, v.isDeleted, @initial_time
FROM (
    VALUES
        (1, 'Amit',  'Sharma', 'amit@example.com',  'Pune',      '9876543210', CAST(0 AS BIT)),
        (2, 'Priya', 'Verma',  'priya@example.com', 'Mumbai',    '9876543211', CAST(0 AS BIT)),
        (3, 'Rahul', 'Patil',  'rahul@example.com', 'Nagpur',    '9876543212', CAST(0 AS BIT)),
        (4, 'Sneha', 'Joshi',  'sneha@example.com', 'Bengaluru', '9876543213', CAST(0 AS BIT))
) AS v(customer_id, first_name, last_name, email, city, phone_number, isDeleted)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.customers c WHERE c.customer_id = v.customer_id
);

INSERT INTO dbo.products
(product_id, product_name, category, unit_price, stock_quantity, isDeleted, lastmodified)
SELECT v.product_id, v.product_name, v.category, v.unit_price,
       v.stock_quantity, v.isDeleted, @initial_time
FROM (
    VALUES
        (101, 'Wireless Mouse',      'Accessories', CAST(799.00 AS DECIMAL(12,2)),  50, CAST(0 AS BIT)),
        (102, 'Mechanical Keyboard', 'Accessories', CAST(2499.00 AS DECIMAL(12,2)), 30, CAST(0 AS BIT)),
        (103, 'USB-C Hub',           'Accessories', CAST(1599.00 AS DECIMAL(12,2)), 25, CAST(0 AS BIT)),
        (104, 'Laptop Stand',        'Office',      CAST(1299.00 AS DECIMAL(12,2)), 20, CAST(0 AS BIT))
) AS v(product_id, product_name, category, unit_price, stock_quantity, isDeleted)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.products p WHERE p.product_id = v.product_id
);

INSERT INTO dbo.orders
(order_id, customer_id, product_id, order_date, quantity, order_status, order_amount, isDeleted, lastmodified)
SELECT v.order_id, v.customer_id, v.product_id, v.order_date,
       v.quantity, v.order_status, v.order_amount, v.isDeleted, @initial_time
FROM (
    VALUES
        (1001, 1, 101, CAST('2026-07-01' AS DATE), 2, 'PLACED',    CAST(1598.00 AS DECIMAL(12,2)), CAST(0 AS BIT)),
        (1002, 2, 102, CAST('2026-07-02' AS DATE), 1, 'SHIPPED',   CAST(2499.00 AS DECIMAL(12,2)), CAST(0 AS BIT)),
        (1003, 3, 103, CAST('2026-07-03' AS DATE), 1, 'DELIVERED', CAST(1599.00 AS DECIMAL(12,2)), CAST(0 AS BIT)),
        (1004, 4, 104, CAST('2026-07-04' AS DATE), 1, 'PLACED',    CAST(1299.00 AS DECIMAL(12,2)), CAST(0 AS BIT))
) AS v(order_id, customer_id, product_id, order_date, quantity, order_status, order_amount, isDeleted)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.orders o WHERE o.order_id = v.order_id
);

/* =====================================================================
   SECTION 7: Create CDC Configuration Table
   ===================================================================== */
IF OBJECT_ID('dbo.adf_cdc_config', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.adf_cdc_config (
        config_id INT IDENTITY(1,1) PRIMARY KEY,
        source_schema VARCHAR(128) NOT NULL,
        source_table VARCHAR(128) NOT NULL,
        watermark_column VARCHAR(128) NOT NULL,
        target_directory VARCHAR(300) NOT NULL,
        is_active BIT NOT NULL DEFAULT 1,
        load_order INT NOT NULL,
        CONSTRAINT UQ_adf_cdc_config UNIQUE (source_schema, source_table)
    );
END;

/* =====================================================================
   SECTION 8: Insert or Update CDC Configuration
   ===================================================================== */
MERGE dbo.adf_cdc_config AS target
USING (
    VALUES
        ('dbo', 'customers', 'lastmodified', 'raw/customers/cdc', 1, 1),
        ('dbo', 'products',  'lastmodified', 'raw/products/cdc',  1, 2),
        ('dbo', 'orders',    'lastmodified', 'raw/orders/cdc',    1, 3)
) AS source
(source_schema, source_table, watermark_column, target_directory, is_active, load_order)
ON  target.source_schema = source.source_schema
AND target.source_table = source.source_table
WHEN MATCHED THEN
    UPDATE SET
        target.watermark_column = source.watermark_column,
        target.target_directory = source.target_directory,
        target.is_active = source.is_active,
        target.load_order = source.load_order
WHEN NOT MATCHED THEN
    INSERT
    (source_schema, source_table, watermark_column, target_directory, is_active, load_order)
    VALUES
    (source.source_schema, source.source_table, source.watermark_column,
     source.target_directory, source.is_active, source.load_order);

/* =====================================================================
   SECTION 9: Create CDC Watermark Table
   ===================================================================== */
IF OBJECT_ID('dbo.adf_cdc_watermark', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.adf_cdc_watermark (
        source_schema VARCHAR(128) NOT NULL,
        source_table VARCHAR(128) NOT NULL,
        last_watermark DATETIME2(3) NOT NULL,
        updated_at DATETIME2(3) NOT NULL,
        CONSTRAINT PK_adf_cdc_watermark PRIMARY KEY (source_schema, source_table)
    );
END;

/* =====================================================================
   SECTION 10: Insert Initial Watermarks and Create Update Procedure
   ===================================================================== */
INSERT INTO dbo.adf_cdc_watermark
(source_schema, source_table, last_watermark, updated_at)
SELECT c.source_schema, c.source_table,
       CAST('1900-01-01T00:00:00.000' AS DATETIME2(3)),
       SYSUTCDATETIME()
FROM dbo.adf_cdc_config c
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.adf_cdc_watermark w
    WHERE w.source_schema = c.source_schema
      AND w.source_table = c.source_table
);

EXEC(N'
CREATE OR ALTER PROCEDURE dbo.usp_update_adf_watermark
    @source_schema VARCHAR(128),
    @source_table VARCHAR(128),
    @new_watermark VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @new_watermark IS NULL
        RETURN;

    DECLARE @watermark_value DATETIME2(3);
    SET @watermark_value = CONVERT(DATETIME2(3), @new_watermark, 126);

    MERGE dbo.adf_cdc_watermark AS target
    USING (
        SELECT
            @source_schema AS source_schema,
            @source_table AS source_table,
            @watermark_value AS new_watermark
    ) AS source
    ON  target.source_schema = source.source_schema
    AND target.source_table = source.source_table
    WHEN MATCHED THEN
        UPDATE SET
            target.last_watermark = source.new_watermark,
            target.updated_at = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (source_schema, source_table, last_watermark, updated_at)
        VALUES (source.source_schema, source.source_table,
                source.new_watermark, SYSUTCDATETIME());
END;
');

/* =====================================================================
   SECTION 11: Verify Setup Before ADF Run 1
   ---------------------------------------------------------------------
   Stop after this section and run the ADF pipeline.
   ===================================================================== */
SELECT * FROM dbo.adf_cdc_config ORDER BY load_order;
SELECT * FROM dbo.adf_cdc_watermark ORDER BY source_table;
SELECT * FROM dbo.customers ORDER BY customer_id;
SELECT * FROM dbo.products ORDER BY product_id;
SELECT * FROM dbo.orders ORDER BY order_id;

/* =====================================================================
   STOP POINT 1
   ---------------------------------------------------------------------
   Run the ADF multiple-table CDC pipeline now.
   Run 1 should copy all initial rows from all three source tables.
   ===================================================================== */

/* =====================================================================
   SECTION 12: Simulate CDC Changes for ADF Run 2
   ---------------------------------------------------------------------
   Run this section only after ADF Run 1 succeeds.
   ===================================================================== */
DECLARE @change_time DATETIME2(3) = SYSUTCDATETIME();

-- Customers: update an existing customer
UPDATE dbo.customers
SET phone_number = '9999999999',
    city = 'Navi Mumbai',
    lastmodified = @change_time
WHERE customer_id = 2;

-- Products: insert a new product
IF NOT EXISTS (SELECT 1 FROM dbo.products WHERE product_id = 105)
BEGIN
    INSERT INTO dbo.products
    (product_id, product_name, category, unit_price, stock_quantity, isDeleted, lastmodified)
    VALUES
    (105, 'Web Camera', 'Accessories', 2199.00, 18, 0, @change_time);
END;

-- Orders: soft delete an existing order
UPDATE dbo.orders
SET isDeleted = 1,
    order_status = 'CANCELLED',
    lastmodified = @change_time
WHERE order_id = 1003;

-- Orders: insert a new order
IF NOT EXISTS (SELECT 1 FROM dbo.orders WHERE order_id = 1005)
BEGIN
    INSERT INTO dbo.orders
    (order_id, customer_id, product_id, order_date, quantity,
     order_status, order_amount, isDeleted, lastmodified)
    VALUES
    (1005, 2, 105, CAST('2026-07-09' AS DATE), 1,
     'PLACED', 2199.00, 0, @change_time);
END;

/* =====================================================================
  SECTION 13: Verify Changes Before ADF Run 2
   ===================================================================== */
SELECT * FROM dbo.customers ORDER BY lastmodified DESC, customer_id;
SELECT * FROM dbo.products ORDER BY lastmodified DESC, product_id;
SELECT * FROM dbo.orders ORDER BY lastmodified DESC, order_id;
SELECT * FROM dbo.adf_cdc_watermark ORDER BY source_table;

/* =====================================================================
   STOP POINT 2
   ---------------------------------------------------------------------
   Run the ADF multiple-table CDC pipeline again.

   Expected Run 2:
   customers → customer_id 2
   products  → product_id 105
   orders    → order_id 1003 and 1005
   ===================================================================== */

/* =====================================================================
   SECTION 14: Final Verification After ADF Run 2
   ===================================================================== */
SELECT source_schema, source_table, last_watermark, updated_at
FROM dbo.adf_cdc_watermark
ORDER BY source_table;

SELECT * FROM dbo.customers ORDER BY customer_id;
SELECT * FROM dbo.products ORDER BY product_id;
SELECT * FROM dbo.orders ORDER BY order_id;

/* =====================================================================
   SECTION 15: Optional Manual Delta Queries
   ===================================================================== */
-- SELECT * FROM dbo.customers
-- WHERE lastmodified > 'PASTE_OLD_WATERMARK_HERE'
-- ORDER BY lastmodified;

-- SELECT * FROM dbo.products
-- WHERE lastmodified > 'PASTE_OLD_WATERMARK_HERE'
-- ORDER BY lastmodified;

-- SELECT * FROM dbo.orders
-- WHERE lastmodified > 'PASTE_OLD_WATERMARK_HERE'
-- ORDER BY lastmodified;

/* =====================================================================
   SECTION 16: Important CDC Notes
   ---------------------------------------------------------------------
   Detects: inserts, updates, and soft deletes when lastmodified changes.
   Does not reliably detect: hard deletes, updates without timestamp change,
   intermediate row versions, or late rows older than the stored watermark.
   ===================================================================== */
