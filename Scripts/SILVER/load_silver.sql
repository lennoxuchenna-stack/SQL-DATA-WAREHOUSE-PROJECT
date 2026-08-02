
EXEC silver.load_silver
/*
=============================================================
Stored Procedure: silver.load_silver
=============================================================
Purpose:
    This stored procedure loads and transforms data from the
    Bronze layer into the Silver layer. It performs data 
    cleaning, standardization, and transformation for both 
    CRM and ERP source tables.

What it does:
    - Truncates existing Silver tables before reloading
    - Cleans and standardizes all data during transformation
    - Prints progress messages for each step
    - Tracks and prints duration of each step
    - Handles errors using TRY...CATCH block

Warning:
    Running this procedure will truncate and reload all 
    Silver tables. Ensure Bronze layer is loaded before 
    running this procedure.
=============================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    DECLARE @start_time  DATETIME2;
    DECLARE @end_time    DATETIME2;
    DECLARE @batch_start DATETIME2;
    DECLARE @batch_end   DATETIME2;

    BEGIN TRY
        SET @batch_start = GETDATE();
        PRINT '========================================';
        PRINT 'Loading Silver Layer';
        PRINT '========================================';

        -- ============================================
        -- SECTION 1: CRM TABLES
        -- Source: bronze.crm_* tables
        -- These tables come from the CRM source system
        -- ============================================
        PRINT '----------------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '----------------------------------------';

        -- ============================================
        -- Step 1: Load silver.crm_cust_info
        -- Transformations applied:
        --   - TRIM first and last name to remove unwanted spaces
        --   - Decode marital status codes: S = Single, M = Married
        --   - Decode gender codes: F = Female, M = Male
        --   - Remove duplicates using ROW_NUMBER() 
        --     keeping only the most recent record per customer
        --   - Filter out NULL customer IDs
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.crm_cust_info';
        TRUNCATE TABLE silver.crm_cust_info;
        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_first_name,
            cst_last_name,
            cst_matial_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_first_name) AS cst_first_name, -- Remove leading/trailing spaces
            TRIM(cst_last_name)  AS cst_last_name,  -- Remove leading/trailing spaces
            CASE WHEN UPPER(TRIM(cst_matial_status)) = 'S' THEN 'Single'
                 WHEN UPPER(TRIM(cst_matial_status)) = 'M' THEN 'Married'
                 ELSE 'n/a'
            END AS cst_matial_status, -- Decode marital status codes to readable values
            CASE WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                 WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                 ELSE 'n/a'
            END AS cst_gndr,          -- Decode gender codes to readable values
            cst_create_date
        FROM (
            -- Deduplicate: keep only the latest record per customer
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY cst_id 
                    ORDER BY cst_create_date DESC
                ) AS flag_last
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL  -- Exclude records with no customer ID
        ) t WHERE flag_last = 1;      -- Keep only the most recent record
        SET @end_time = GETDATE();
        PRINT '>> silver.crm_cust_info loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- Step 2: Load silver.crm_prd_info
        -- Transformations applied:
        --   - Extract category ID from product key
        --   - Extract clean product key from product key
        --   - Replace NULL cost with 0
        --   - Decode product line codes to readable values
        --   - Cast start date to DATE type
        --   - Derive end date using LEAD window function
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.crm_prd_info';
        TRUNCATE TABLE silver.crm_prd_info;
        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,
            REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,      -- Extract and clean category ID
            SUBSTRING(prd_key, 7, LEN(prd_key))          AS prd_key,     -- Extract clean product key
            prd_nm,
            ISNULL(prd_cost, 0)                           AS prd_cost,    -- Replace NULL cost with 0
            CASE WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                 WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                 WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                 WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                 ELSE 'n/a'
            END AS prd_line,                                               -- Decode product line codes
            CAST(prd_start_dt AS DATE) AS prd_start_dt,                   -- Cast to DATE type
            CAST(LEAD(prd_start_dt) OVER (
                PARTITION BY prd_key 
                ORDER BY prd_start_dt
            ) - 1 AS DATE) AS prd_end_dt  -- Derive end date from next record start date
        FROM bronze.crm_prd_info;
        SET @end_time = GETDATE();
        PRINT '>> silver.crm_prd_info loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- Step 3: Load silver.crm_sales_details
        -- Transformations applied:
        --   - Validate and cast order, ship, due dates to DATE
        --     replacing invalid or zero values with NULL
        --   - Recalculate sales if missing or incorrect
        --   - Derive price if original value is invalid
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.crm_sales_details';
        TRUNCATE TABLE silver.crm_sales_details;
        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            -- Replace invalid or zero order dates with NULL
            CASE WHEN sls_order_dt = 0
                      OR LEN(CAST(sls_order_dt AS VARCHAR)) != 8
                 THEN NULL
                 ELSE CAST(CAST(sls_order_dt AS VARCHAR) AS DATE)
            END AS sls_order_dt,
            -- Replace invalid or zero ship dates with NULL
            CASE WHEN sls_ship_dt = 0
                      OR LEN(CAST(sls_ship_dt AS VARCHAR)) != 8
                 THEN NULL
                 ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE)
            END AS sls_ship_dt,
            -- Replace invalid or zero due dates with NULL
            CASE WHEN sls_due_dt = 0
                      OR LEN(CAST(sls_due_dt AS VARCHAR)) != 8
                 THEN NULL
                 ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE)
            END AS sls_due_dt,
            -- Recalculate sales if original value is missing or incorrect
            CASE WHEN sls_sales IS NULL
                      OR sls_sales <= 0
                      OR sls_sales != sls_quantity * ABS(sls_price)
                 THEN sls_quantity * ABS(sls_price)
                 ELSE sls_sales
            END AS sls_sales,
            sls_quantity,
            -- Derive price if original value is missing or invalid
            CASE WHEN sls_price IS NULL
                      OR sls_price <= 0
                 THEN sls_sales / NULLIF(sls_quantity, 0)
                 ELSE sls_price
            END AS sls_price
        FROM bronze.crm_sales_details;
        SET @end_time = GETDATE();
        PRINT '>> silver.crm_sales_details loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- SECTION 2: ERP TABLES
        -- Source: bronze.erp_* tables
        -- These tables come from the ERP source system
        -- ============================================
        PRINT '----------------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '----------------------------------------';

        -- ============================================
        -- Step 4: Load silver.erp_cust_az12
        -- Transformations applied:
        --   - Remove NAS prefix from customer ID
        --   - Replace future birth dates with NULL
        --   - Standardize gender values to Male/Female
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.erp_cust_az12';
        TRUNCATE TABLE silver.erp_cust_az12;
        INSERT INTO silver.erp_cust_az12 (cid, bdate, gen)
        SELECT
            -- Remove NAS prefix from customer ID if present
            CASE WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid))
                 ELSE cid
            END AS cid,
            -- Replace future birth dates with NULL (invalid data)
            CASE WHEN bdate > GETDATE()
                 THEN NULL
                 ELSE bdate
            END AS bdate,
            -- Standardize gender codes to readable values
            CASE WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE') THEN 'Female'
                 WHEN UPPER(TRIM(gen)) IN ('M', 'MALE')   THEN 'Male'
                 ELSE 'n/a'
            END AS gen
        FROM bronze.erp_cust_az12;
        SET @end_time = GETDATE();
        PRINT '>> silver.erp_cust_az12 loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- Step 5: Load silver.erp_loc_a101
        -- Transformations applied:
        --   - Remove dots from customer ID
        --   - Normalize country codes to full country names
        --   - Replace empty or NULL country with n/a
        --   - Trim unwanted spaces from country values
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.erp_loc_a101';
        TRUNCATE TABLE silver.erp_loc_a101;
        INSERT INTO silver.erp_loc_a101 (cid, cntry)
        SELECT
            REPLACE(cid, '.', '') AS cid, -- Remove dots from customer ID
            CASE
                WHEN TRIM(cntry) = 'DE'                THEN 'Germany'       -- Normalize country code
                WHEN TRIM(cntry) IN ('US', 'USA')      THEN 'United States' -- Normalize country code
                WHEN TRIM(cntry) = '' OR cntry IS NULL THEN 'n/a'           -- Handle missing values
                ELSE TRIM(cntry)                                              -- Remove unwanted spaces
            END AS cntry
        FROM bronze.erp_loc_a101;
        SET @end_time = GETDATE();
        PRINT '>> silver.erp_loc_a101 loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- Step 6: Load silver.erp_px_cat_g1v2
        -- Transformations applied:
        --   - No transformations needed
        --   - Data is clean as loaded from Bronze
        -- ============================================
        SET @start_time = GETDATE();
        PRINT '>> Inserting Data Into: silver.erp_px_cat_g1v2';
        TRUNCATE TABLE silver.erp_px_cat_g1v2;
        INSERT INTO silver.erp_px_cat_g1v2 (id, cat, subcat, maintenance)
        SELECT
            id,
            cat,
            subcat,
            maintenance
        FROM bronze.erp_px_cat_g1v2;
        SET @end_time = GETDATE();
        PRINT '>> silver.erp_px_cat_g1v2 loaded. Duration: '
            + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';

        -- ============================================
        -- SILVER LOAD COMPLETE
        -- ============================================
        SET @batch_end = GETDATE();
        PRINT '========================================';
        PRINT 'Silver Layer Load Complete.';
        PRINT 'Total Duration: '
            + CAST(DATEDIFF(SECOND, @batch_start, @batch_end) AS NVARCHAR) + ' seconds';
        PRINT '========================================';

    END TRY
    BEGIN CATCH
        -- ============================================
        -- ERROR HANDLING
        -- Catches any error that occurs during loading
        -- and prints the error details for debugging
        -- ============================================
        PRINT '========================================';
        PRINT 'ERROR OCCURRED WHILE LOADING SILVER LAYER';
        PRINT 'Error Message : ' + ERROR_MESSAGE();
        PRINT 'Error Number  : ' + CAST(ERROR_NUMBER()  AS NVARCHAR);
        PRINT 'Error State   : ' + CAST(ERROR_STATE()   AS NVARCHAR);
        PRINT '========================================';
    END CATCH
END;
