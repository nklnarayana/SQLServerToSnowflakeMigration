USE DATABASE <%financial_planning%>;

/*
    usp_ProcessBudgetConsolidation - Complex budget consolidation with hierarchy rollup

    SnowConvert input: Effective definition after SQL Server patches 01-04 (see docs/conversion_input_manifest.md)
    Patches applied here: PCB-01 (#ConsolidatedAmounts), PCB-03 (FinalAmount init), PCB-05 (transaction ownership)

    Excluded vs deployed patch-04 procedure: ForceInsertFailure XML test hook (TC10/TC11 harness only).

    Dependencies: 
        - Tables: BudgetHeader, BudgetLineItem, GLAccount, CostCenter, FiscalPeriod, ConsolidationJournal
        - Views: vw_BudgetConsolidationSummary
        - Functions: fn_GetHierarchyPath, tvf_ExplodeCostCenterHierarchy
        - Types: BudgetLineItemTableType, AllocationResultTableType

    ============================================================================
    MANUAL RESOLUTION OF SNOWCONVERT EWI MARKERS - review these decisions
    ============================================================================
    1. SET XACT_ABORT OFF (SSC-EWI-TS0089) - removed. Snowflake has no equivalent
       setting; the procedure already handles errors explicitly in its EXCEPTION
       block, which is what XACT_ABORT OFF was selected for.

    2. @@TRANCOUNT (SSC-EWI-TS0115) - replaced with
       IFF(CURRENT_TRANSACTION() IS NULL, 0, 1). The source only ever tests this
       for zero/non-zero (does the caller already own a transaction), so a
       boolean-style probe is behaviourally equivalent for this usage. Nested
       transaction depth greater than 1 is not representable and not needed here.

    3. SAVE TRANSACTION / ROLLBACK TO savepoint (SSC-EWI-TS0106, SSC-EWI-TS0083)
       - BEHAVIOURAL DIFFERENCE. Snowflake has no savepoints and no partial
       rollback. The three savepoints (SavePoint_ProcEntry, SavePoint_AfterHeader,
       SavePoint_BeforeEliminations) are removed.
         * Procedure owns the transaction -> full ROLLBACK on error, as before.
         * Caller owns the transaction -> the procedure can no longer undo only
           its own work. It re-raises and leaves the rollback decision to the
           caller, who must roll back to keep the consolidation atomic.
       Callers that relied on partial rollback must be reviewed.

    4. OUTPUT clause (SSC-EWI-0021, two sites) - not supported. Replaced by
       reading back the inserted rows:
         * Target header: the generated BudgetCode is built into a variable
           first and the new BudgetHeaderID is selected back by that code.
         * Inserted lines: re-selected from BudgetLineItem by SourceReference,
           which carries this run's unique CONSOLIDATIONRUNID.

    5. Scrollable / KEYSET / FOR UPDATE cursor (SSC-EWI-TS0037, SSC-EWI-0058,
       SSC-EWI-0073) - EliminationCursor is declared forward-only and read-only.
       Inspection of the source shows every fetch is in fact a FETCH NEXT (the
       "move back if no offset found" comment notwithstanding), so the fetch
       sequence is preserved exactly. The cursor performed no write-back through
       FOR UPDATE OF bli.AdjustedAmount in the body, so nothing is lost.

    6. @@FETCH_STATUS (SSC-EWI-TS0121, three sites) - Snowflake Scripting has no
       fetch-status global. Each fetch target is set to NULL immediately before
       the FETCH; an unchanged NULL afterwards means the cursor was exhausted.

    7. Dynamic SQL (SSC-EWI-0125, SSC-FDM-0131) - the generated statement was
       still T-SQL (UPDATE..FROM, SET @RowCountOUT = @@ROWCOUNT) and could not
       execute on Snowflake. Rewritten as a Snowflake UPDATE, executed with
       EXECUTE IMMEDIATE, with the affected-row count taken from SQLROWCOUNT.
       The two REPLACE() option rewrites are retargeted at the new text.

    8. XACT_STATE() = -1 (SSC-EWI-TS0219) - removed. Snowflake has no
       uncommittable-transaction state, so that branch cannot arise.

    9. CURSOR_STATUS (SSC-FDM-TS0082) - not supported. Cursor cleanup now
       attempts CLOSE inside a nested handler that ignores a not-open error.
    ============================================================================
*/
CREATE OR REPLACE PROCEDURE Planning.usp_ProcessBudgetConsolidation (SOURCEBUDGETHEADERID INT, TARGETBUDGETHEADERID OUT INT, CONSOLIDATIONTYPE STRING DEFAULT 'FULL',         -- FULL, INCREMENTAL, DELTA
INCLUDEELIMINATIONS BOOLEAN DEFAULT 1, RECALCULATEALLOCATIONS BOOLEAN DEFAULT 1, PROCESSINGOPTIONS VARIANT DEFAULT NULL, USERID INT DEFAULT NULL, DEBUGMODE BOOLEAN DEFAULT 0, ROWSPROCESSED OUT INT, ERRORMESSAGE OUT STRING)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
EXECUTE AS CALLER
AS
$$
    DECLARE

        -- =========================================================================
        -- Variable declarations
        -- =========================================================================
        PROCSTARTTIME TIMESTAMP_NTZ(7);
        STEPSTARTTIME TIMESTAMP_NTZ(7);
        CURRENTSTEP NVARCHAR(100);
        RETURNCODE INT := 0;
        TOTALROWSPROCESSED INT := 0;
        BATCHSIZE INT := 5000;
        CURRENTBATCH INT := 0;
        MAXITERATIONS INT := 1000;
        CONSOLIDATIONRUNID VARCHAR;
        TRANCOUNTATPROCENTRY INT;
        PROCOWNSTRANSACTION BOOLEAN := FALSE;
        CALLEROWNSTRANSACTION BOOLEAN := FALSE;
        NEWBUDGETCODE VARCHAR(60);

        -- =========================================================================
        -- Cursor declarations
        -- =========================================================================
        CURSORCOSTCENTERID INT;
        CURSORLEVEL INT;
        CURSORPARENTID INT;
        CURSORSUBTOTAL DECIMAL(19, 4);
        --** SSC-FDM-TS0013 - SNOWFLAKE SCRIPTING CURSOR ROWS ARE NOT MODIFIABLE **
        HierarchyCursor CURSOR
        FOR
            SELECT
                NodeID,
                NodeLevel,
                ParentNodeID
            FROM
                T_HierarchyNodes
            ORDER BY NodeLevel DESC, NodeID; -- Process bottom-up
    -- Secondary cursor for elimination entries
        ELIMACCOUNTID INT;
        ELIMCOSTCENTERID INT;
        ELIMAMOUNT DECIMAL(19, 4);
        PARTNERENTITYCODE VARCHAR(20);
        ELIMINATIONCOUNT INT := 0;
        -- Check for matching offsetting entry
        OFFSETEXISTS BOOLEAN;
        OFFSETAMOUNT DECIMAL(19, 4);
        -- Manual resolution 5: forward-only, read-only. SCROLL / KEYSET /
        -- FOR UPDATE OF bli.AdjustedAmount are not supported and were unused.
        EliminationCursor CURSOR
        FOR
            SELECT
                bli.GLAccountID,
                bli.CostCenterID,
                bli.FinalAmount,
                gla.StatutoryAccountCode  -- Uses SPARSE column
            FROM <%financial_planning%>.Planning.BudgetLineItem bli
            INNER JOIN <%financial_planning%>.Planning.GLAccount gla ON bli.GLAccountID = gla.GLAccountID
            WHERE bli.BudgetHeaderID = ?
              AND gla.IntercompanyFlag = 1
            ORDER BY bli.GLAccountID, bli.CostCenterID;
        DYNAMICSQL NVARCHAR;
        ALLOCATIONROWCOUNT INT;
        INCLUDEZEROBALANCES BOOLEAN;
        ROUNDINGPRECISION INT;
        INITFINALROWCOUNT INT;
    BEGIN
--        --** SSC-FDM-TS0029 - SET NOCOUNT STATEMENT IS COMMENTED OUT, WHICH IS NOT APPLICABLE IN SNOWFLAKE. **
--        SET NOCOUNT ON;
        -- Manual resolution 1: SET XACT_ABORT OFF removed (no Snowflake equivalent).

        PROCSTARTTIME := SYSDATE();
        CONSOLIDATIONRUNID := UUID_STRING();
        -- Manual resolution 2: @@TRANCOUNT replaced with a caller-transaction probe.
        TRANCOUNTATPROCENTRY := IFF(CURRENT_TRANSACTION() IS NULL, 0, 1);

        -- Table variables - These don't exist in Snowflake
        CREATE OR REPLACE TEMPORARY TABLE T_PROCESSINGLOG (
            LogID INT IDENTITY(1,1) ORDER PRIMARY KEY,
            StepName NVARCHAR(100),
            StartTime TIMESTAMP_NTZ(7),
            EndTime TIMESTAMP_NTZ(7),
            RowsAffected INT,
            StatusCode VARCHAR(20),
            Message NVARCHAR
--                            ,
--            --** SSC-FDM-0021 - CREATE INDEX IS NOT SUPPORTED BY SNOWFLAKE **
--            INDEX IX_StepName (StepName)
        );
        CREATE OR REPLACE TEMPORARY TABLE T_HIERARCHYNODES (
            NodeID INT PRIMARY KEY,
            ParentNodeID INT,
            NodeLevel INT,
            ProcessingOrder INT,
            IsProcessed BOOLEAN DEFAULT false,
            SubtotalAmount DECIMAL(19, 4)
--                                         ,
--            --** SSC-FDM-0021 - CREATE INDEX IS NOT SUPPORTED BY SNOWFLAKE **
--            INDEX IX_Level (NodeLevel, IsProcessed)
        );

        -- Patch 02: local temp table #ConsolidatedAmounts (replaces @ConsolidatedAmounts) for sp_executesql scope
        DROP TABLE IF EXISTS T_ConsolidatedAmounts;
        CREATE OR REPLACE TEMPORARY TABLE T_ConsolidatedAmounts (
            GLAccountID INT NOT NULL,
            CostCenterID INT NOT NULL,
            FiscalPeriodID INT NOT NULL,
            ConsolidatedAmount DECIMAL(19, 4) NOT NULL,
            EliminationAmount DECIMAL(19, 4) NOT NULL DEFAULT (0) /*** SSC-FDM-0012 - CONSTRAINT NAME 'DF_ConsolidatedAmounts_Elim' IN DEFAULT EXPRESSION CONSTRAINT IS NOT SUPPORTED IN SNOWFLAKE ***/,
            FinalAmount DECIMAL(19, 4) NULL,
            SourceCount INT NULL,
            CONSTRAINT PK_ConsolidatedAmounts PRIMARY KEY (GLAccountID, CostCenterID, FiscalPeriodID)
        );

        -- =========================================================================
        -- TRY-CATCH Error Handling - Different in Snowflake
        -- =========================================================================
        BEGIN
            -- Validate input parameters
            CURRENTSTEP := 'Parameter Validation';
            STEPSTARTTIME := SYSDATE();
            IF (NOT EXISTS (SELECT 1 FROM
                    <%financial_planning%>.Planning.BudgetHeader
                WHERE
                    BudgetHeaderID = :SOURCEBUDGETHEADERID
            )) THEN
                BEGIN
                    ERRORMESSAGE := 'Source budget header not found: ' || CAST(:SOURCEBUDGETHEADERID AS VARCHAR);
                    --** SSC-FDM-TS0019 - RAISERROR ERROR MESSAGE MAY DIFFER BECAUSE OF THE SQL SERVER STRING FORMAT **
                    SELECT
                        <%AIM_DB%>.PUBLIC.RAISERROR_UDF(:ERRORMESSAGE, 16, 1, array_construct());
                END;
            END IF;
            -- Check if source is locked
            IF (EXISTS (
                SELECT 1 FROM
                    <%financial_planning%>.Planning.BudgetHeader
                WHERE
                    BudgetHeaderID = :SOURCEBUDGETHEADERID
                  AND
                    --** SSC-FDM-TS0191 - TEXT COMPARISON ON A COLUMN DECLARED WITHOUT COLLATE IS CASE AND ACCENT SENSITIVE IN SNOWFLAKE; RESULTS DIFFER IF THE SOURCE DEFAULT COLLATION IS CASE OR ACCENT INSENSITIVE **
                    StatusCode NOT IN ('APPROVED', 'LOCKED')
            )) THEN
            BEGIN
                    ERRORMESSAGE := 'Source budget must be in APPROVED or LOCKED status for consolidation';
                    CALL <%AIM_DB%>.PUBLIC.THROW_UDP(50001, :ERRORMESSAGE, 1);  -- THROW syntax differs from RAISERROR
            END;
            END IF;
            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), 0, 'COMPLETED');
            -- =====================================================================
            -- Create or update target budget header
            -- =====================================================================
            CURRENTSTEP := 'Create Target Budget';
            STEPSTARTTIME := SYSDATE();
            IF (:TRANCOUNTATPROCENTRY = 0) THEN
                BEGIN
                    BEGIN TRANSACTION;
                    PROCOWNSTRANSACTION := TRUE;
                END;
            ELSE
                BEGIN
                    -- Manual resolution 3: SAVE TRANSACTION SavePoint_ProcEntry removed.
                    -- Snowflake cannot roll back to a savepoint; on error this
                    -- procedure re-raises and the caller must roll back.
                    CALLEROWNSTRANSACTION := TRUE;
                END;
            END IF;
            IF (:TARGETBUDGETHEADERID IS NULL) THEN
                BEGIN
                    -- Manual resolution 4: OUTPUT clause replaced by read-back.
                    -- The generated BudgetCode is computed first so the new
                    -- BudgetHeaderID can be selected back by it.
                    SELECT
                        BudgetCode || '_CONSOL_' || TO_CHAR(CURRENT_TIMESTAMP() :: TIMESTAMP, 'YYYYMMDD')
                    INTO
                        :NEWBUDGETCODE
                    FROM
                        <%financial_planning%>.Planning.BudgetHeader
                    WHERE
                        BudgetHeaderID = :SOURCEBUDGETHEADERID;

                    INSERT INTO <%financial_planning%>.Planning.BudgetHeader (BudgetCode, BudgetName, BudgetType, ScenarioType, FiscalYear, StartPeriodID, EndPeriodID, BaseBudgetHeaderID, StatusCode, VersionNumber, ExtendedProperties
                    )
                    SELECT
                        :NEWBUDGETCODE,
                        BudgetName || ' - Consolidated',
                        'CONSOLIDATED',
                        ScenarioType,
                        FiscalYear,
                        StartPeriodID,
                        EndPeriodID,
                        BudgetHeaderID,
                        'DRAFT',
                        1,
                        -- XML modification - very different in Snowflake
                        PARSE_XML(
                        '<Root>' ||
                        '<ConsolidationRun RunID="' || CAST(:CONSOLIDATIONRUNID AS VARCHAR(36)) || '" ' ||
                        'SourceID="' || CAST(:SOURCEBUDGETHEADERID AS VARCHAR(20)) || '" ' ||
                        'Timestamp="' || LEFT(TO_VARCHAR(:PROCSTARTTIME, 'yyyy-mm-dd"T"hh:mi:ss.ff3'), 30) || '"/>' || NVL(CAST(ExtendedProperties AS NVARCHAR), '') ||
                        '</Root>')
                    FROM
                        <%financial_planning%>.Planning.BudgetHeader
                    WHERE
                        BudgetHeaderID = :SOURCEBUDGETHEADERID;

                    SELECT
                        MAX(BudgetHeaderID)
                    INTO
                        :TARGETBUDGETHEADERID
                    FROM
                        <%financial_planning%>.Planning.BudgetHeader
                    WHERE
                        BudgetCode = :NEWBUDGETCODE;

                    IF (:TARGETBUDGETHEADERID IS NULL) THEN
                        BEGIN
                            ERRORMESSAGE := 'Failed to create target budget header';
                            CALL <%AIM_DB%>.PUBLIC.THROW_UDP(50002, :ERRORMESSAGE, 1);
                        END;
                    END IF;
                END;
            END IF;

            -- Manual resolution 3: SAVE TRANSACTION SavePoint_AfterHeader removed.
            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), 1, 'COMPLETED');
            -- =====================================================================
            -- Build hierarchy for bottom-up rollup using TVF
            -- =====================================================================
            CURRENTSTEP := 'Build Hierarchy';
            STEPSTARTTIME := SYSDATE();
            INSERT INTO T_HIERARCHYNODES (NodeID, ParentNodeID, NodeLevel, ProcessingOrder)
            SELECT
                h.CostCenterID,
                h.ParentCostCenterID,
                h.HierarchyLevel,
                ROW_NUMBER() OVER (ORDER BY h.HierarchyLevel DESC NULLS LAST, h.CostCenterID NULLS FIRST)
            FROM
                /* Manual resolution: SQL Server coerced these arguments
                   implicitly (NULL to INT, 0 to BIT, GETDATE() to the DATE
                   parameter @AsOfDate). Snowflake requires explicit types, so
                   the casts are spelled out here. Casting to DATE matches the
                   source, whose @AsOfDate parameter is DATE. */
                TABLE(<%financial_planning%>.Planning.tvf_ExplodeCostCenterHierarchy(NULL :: INT, 10, FALSE, CURRENT_TIMESTAMP() /*** SSC-FDM-TS0186 - GETDATE() RETURNS THE LOCAL TIME OF THE SQL SERVER HOST; THE CONVERTED CALL FOLLOWS THE SNOWFLAKE SESSION TIMEZONE. SET TIMEZONE TO THE SOURCE SERVER'S ZONE FOR THE USERS THAT RUN THIS CODE ***/ :: DATE)) h;  -- CROSS APPLY to TVF

            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), :SQLROWCOUNT, 'COMPLETED');
            -- =====================================================================
            -- Process consolidation using cursor (bottom-up hierarchy traversal)
            -- =====================================================================
            CURRENTSTEP := 'Hierarchy Consolidation';
            STEPSTARTTIME := SYSDATE();
            OPEN HierarchyCursor;
            -- Manual resolution 6: NULL sentinel stands in for @@FETCH_STATUS.
            CURSORCOSTCENTERID := NULL;
            FETCH
                HierarchyCursor
            INTO
                :CURSORCOSTCENTERID,
                :CURSORLEVEL,
                :CURSORPARENTID;
            WHILE (:CURSORCOSTCENTERID IS NOT NULL AND :CURRENTBATCH < :MAXITERATIONS) LOOP
                CURRENTBATCH := :CURRENTBATCH + 1;

                -- Calculate subtotal for this node
                SELECT
                    SUM(bli.FinalAmount)
                INTO
                    :CURSORSUBTOTAL
                FROM
                    <%financial_planning%>.Planning.BudgetLineItem bli
                WHERE
                    bli.BudgetHeaderID = :SOURCEBUDGETHEADERID
                  AND bli.CostCenterID = :CURSORCOSTCENTERID;

                -- Add child subtotals (already processed due to bottom-up order)
                SELECT
                    NVL(:CURSORSUBTOTAL, 0) + NVL(SUM(h.SubtotalAmount), 0)
                INTO
                    :CURSORSUBTOTAL
                FROM
                    T_HierarchyNodes h
                WHERE
                    h.ParentNodeID = :CURSORCOSTCENTERID
                  AND h.IsProcessed = TRUE;

                -- Update node
                UPDATE T_HierarchyNodes
                SET
                        SubtotalAmount = :CURSORSUBTOTAL,
                        IsProcessed = TRUE
                WHERE
                        NodeID = :CURSORCOSTCENTERID;
                -- MERGE to update or insert consolidated amounts
                MERGE INTO T_ConsolidatedAmounts AS target
                USING (
                    SELECT
                        bli.GLAccountID,
                        :CURSORCOSTCENTERID AS CostCenterID,
                        bli.FiscalPeriodID,
                        SUM(bli.FinalAmount) AS Amount,
                        COUNT(*) AS SourceCnt
                    FROM
                        <%financial_planning%>.Planning.BudgetLineItem bli
                    WHERE
                        bli.BudgetHeaderID = :SOURCEBUDGETHEADERID
                      AND bli.CostCenterID = :CURSORCOSTCENTERID
                    GROUP BY
                        bli.GLAccountID,
                        bli.FiscalPeriodID
                ) AS source
                ON target.GLAccountID = source.GLAccountID
                   AND target.CostCenterID = source.CostCenterID
                   AND target.FiscalPeriodID = source.FiscalPeriodID
                WHEN MATCHED THEN
                    UPDATE SET
                        ConsolidatedAmount = target.ConsolidatedAmount + source.Amount,
                        SourceCount = target.SourceCount + source.SourceCnt
                WHEN NOT MATCHED THEN
                    INSERT (GLAccountID, CostCenterID, FiscalPeriodID, ConsolidatedAmount, SourceCount)
                    VALUES (source.GLAccountID, source.CostCenterID, source.FiscalPeriodID, source.Amount, source.SourceCnt);
                TOTALROWSPROCESSED := :TOTALROWSPROCESSED + SQLROWCOUNT;
                --** SSC-PRF-0003 - FETCH INSIDE A LOOP IS CONSIDERED A COMPLEX PATTERN, THIS COULD DEGRADE SNOWFLAKE PERFORMANCE. **
                CURSORCOSTCENTERID := NULL;
                FETCH
                    HierarchyCursor
                INTO
                    :CURSORCOSTCENTERID,
                    :CURSORLEVEL,
                    :CURSORPARENTID;
            END LOOP;
            CLOSE HierarchyCursor;
--            --** SSC-FDM-TS0057 - DEALLOCATE IS NOT REQUIRED IN SNOWFLAKE SCRIPTING. CURSORS ARE AUTOMATICALLY DEALLOCATED WHEN THEY GO OUT OF SCOPE. **
--            DEALLOCATE HierarchyCursor
                                      ;
            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), :TOTALROWSPROCESSED, 'COMPLETED');
            -- =====================================================================
            -- Process intercompany eliminations using updateable cursor
            -- =====================================================================
            IF (:INCLUDEELIMINATIONS = TRUE) THEN
            BEGIN
                    CURRENTSTEP := 'Intercompany Eliminations';
                    STEPSTARTTIME := SYSDATE();

                -- Manual resolution 3: SAVE TRANSACTION SavePoint_BeforeEliminations removed.
                    OPEN EliminationCursor USING (SOURCEBUDGETHEADERID);
                    ELIMACCOUNTID := NULL;
                    FETCH
                        EliminationCursor
                INTO
                        :ELIMACCOUNTID,
                        :ELIMCOSTCENTERID,
                        :ELIMAMOUNT,
                        :PARTNERENTITYCODE;
                    WHILE (:ELIMACCOUNTID IS NOT NULL) LOOP
                        -- Elimination logic. Every fetch below is FETCH NEXT, as
                        -- in the source; no backward positioning is performed.
                        IF (:ELIMAMOUNT <> 0) THEN
                            -- Check for matching offsetting entry
                        BEGIN
                                OFFSETEXISTS := FALSE;

                                -- Look ahead one row for an offsetting amount
                                --** SSC-PRF-0003 - FETCH INSIDE A LOOP IS CONSIDERED A COMPLEX PATTERN, THIS COULD DEGRADE SNOWFLAKE PERFORMANCE. **
                                OFFSETAMOUNT := NULL;
                                FETCH
                                    EliminationCursor
                                INTO
                                    :ELIMACCOUNTID,
                                    :ELIMCOSTCENTERID,
                                    :OFFSETAMOUNT,
                                    :PARTNERENTITYCODE;
                                IF (:OFFSETAMOUNT IS NOT NULL AND :OFFSETAMOUNT = -:ELIMAMOUNT) THEN
                                    BEGIN
                                        OFFSETEXISTS := TRUE;

                                        -- Create elimination entry
                                        UPDATE T_ConsolidatedAmounts
                                        SET
                                            EliminationAmount = EliminationAmount + :ELIMAMOUNT
                                        WHERE
                                            GLAccountID = :ELIMACCOUNTID
                                          AND CostCenterID = :ELIMCOSTCENTERID;
                                        ELIMINATIONCOUNT := :ELIMINATIONCOUNT + 1;
                                    END;
                                END IF;
                                -- Advance again if no offset found
                                IF (:OFFSETEXISTS = FALSE) THEN
                                    --** SSC-PRF-0003 - FETCH INSIDE A LOOP IS CONSIDERED A COMPLEX PATTERN, THIS COULD DEGRADE SNOWFLAKE PERFORMANCE. **
                                    ELIMACCOUNTID := NULL;
                                    FETCH
                                        EliminationCursor
                                    INTO
                                        :ELIMACCOUNTID,
                                        :ELIMCOSTCENTERID,
                                        :ELIMAMOUNT,
                                        :PARTNERENTITYCODE;
                                END IF;
                        END;
                        END IF;
                        --** SSC-PRF-0003 - FETCH INSIDE A LOOP IS CONSIDERED A COMPLEX PATTERN, THIS COULD DEGRADE SNOWFLAKE PERFORMANCE. **
                        ELIMACCOUNTID := NULL;
                        FETCH
                            EliminationCursor
                    INTO
                            :ELIMACCOUNTID,
                            :ELIMCOSTCENTERID,
                            :ELIMAMOUNT,
                            :PARTNERENTITYCODE;
                    END LOOP;
                    CLOSE EliminationCursor;
--                    --** SSC-FDM-TS0057 - DEALLOCATE IS NOT REQUIRED IN SNOWFLAKE SCRIPTING. CURSORS ARE AUTOMATICALLY DEALLOCATED WHEN THEY GO OUT OF SCOPE. **
--                DEALLOCATE EliminationCursor
                                            ;
                INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
                VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), :ELIMINATIONCOUNT, 'COMPLETED');
            END;
            END IF;
            -- =====================================================================
            -- Recalculate allocations using dynamic SQL
            -- =====================================================================
            IF (:RECALCULATEALLOCATIONS = TRUE) THEN
            BEGIN
                    CURRENTSTEP := 'Recalculate Allocations';
                    STEPSTARTTIME := SYSDATE();

                    -- Manual resolution 7: dynamic SQL rewritten as Snowflake SQL.
                    -- The source built a T-SQL UPDATE..FROM and read @@ROWCOUNT
                    -- into an OUTPUT parameter via sp_executesql; here the
                    -- statement is Snowflake-native and SQLROWCOUNT is used.
                    DYNAMICSQL :=
                    'UPDATE T_ConsolidatedAmounts ca
                        SET FinalAmount = ca.ConsolidatedAmount - ca.EliminationAmount
                      WHERE ca.ConsolidatedAmount <> 0
                         OR ca.EliminationAmount <> 0';
                    -- Extract options from XML if provided
                    IF (:PROCESSINGOPTIONS IS NOT NULL) THEN
                    BEGIN
                        SELECT
                                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REGEXP_REPLACE(TO_VARCHAR(XMLGET(IFF(GET(:PROCESSINGOPTIONS, '@') :: VARCHAR = 'Options', :PROCESSINGOPTIONS, null), 'IncludeZeroBalances', 0)), '<[^>]+>', ''), '&lt;', '<'), '&gt;', '>'), '&apos;', ''''), '&quot;', '"'), '&amp;', '&') :: BOOLEAN,
                                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REGEXP_REPLACE(TO_VARCHAR(XMLGET(IFF(GET(:PROCESSINGOPTIONS, '@') :: VARCHAR = 'Options', :PROCESSINGOPTIONS, null), 'RoundingPrecision', 0)), '<[^>]+>', ''), '&lt;', '<'), '&gt;', '>'), '&apos;', ''''), '&quot;', '"'), '&amp;', '&') :: INT
                            INTO
                                :INCLUDEZEROBALANCES,
                                :ROUNDINGPRECISION;
                            -- Modify SQL based on options
                            IF (:INCLUDEZEROBALANCES = FALSE) THEN
                                DYNAMICSQL :=
                                REPLACE(:DYNAMICSQL,
                                    'WHERE ca.ConsolidatedAmount <> 0',
                                    'WHERE ca.ConsolidatedAmount <> 0 AND ca.FinalAmount <> 0');
                            END IF;
                            IF (:ROUNDINGPRECISION IS NOT NULL) THEN
                                DYNAMICSQL :=
                                REPLACE(:DYNAMICSQL,
                                'ca.ConsolidatedAmount - ca.EliminationAmount',
                                'ROUND(ca.ConsolidatedAmount - ca.EliminationAmount, ' || CAST(:ROUNDINGPRECISION AS VARCHAR) || ')');
                            END IF;
                    END;
                    END IF;
                    EXECUTE IMMEDIATE :DYNAMICSQL;
                    ALLOCATIONROWCOUNT := SQLROWCOUNT;

                INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
                VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), :ALLOCATIONROWCOUNT, 'COMPLETED');
            END;
            ELSE
            BEGIN
                    CURRENTSTEP := 'Initialize Final Amounts';
                    STEPSTARTTIME := SYSDATE();

                UPDATE T_ConsolidatedAmounts ca
                SET
                            FinalAmount = ca.ConsolidatedAmount - ca.EliminationAmount
                WHERE
                            ca.ConsolidatedAmount <> 0
                   OR ca.EliminationAmount <> 0;
                    INITFINALROWCOUNT := SQLROWCOUNT;
                INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
                VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), :INITFINALROWCOUNT, 'COMPLETED');
            END;
            END IF;
            -- =====================================================================
            -- Insert final results
            -- =====================================================================
            CURRENTSTEP := 'Insert INTO Results ;';
            STEPSTARTTIME := SYSDATE();
            CREATE OR REPLACE TEMPORARY TABLE T_INSERTEDLINES (
                BudgetLineItemID BIGINT,
                GLAccountID INT,
                CostCenterID INT,
                Amount DECIMAL(19, 4)
            );

            INSERT INTO <%financial_planning%>.Planning.BudgetLineItem (BudgetHeaderID, GLAccountID, CostCenterID, FiscalPeriodID, OriginalAmount, AdjustedAmount, SpreadMethodCode, SourceSystem, SourceReference, IsAllocated, LastModifiedByUserID, LastModifiedDateTime
            )
            SELECT
                :TARGETBUDGETHEADERID,
                ca.GLAccountID,
                ca.CostCenterID,
                ca.FiscalPeriodID,
                ca.FinalAmount,
                0,
                'CONSOLIDATED',
                'CONSOLIDATION_PROC',
                CAST(:CONSOLIDATIONRUNID AS VARCHAR(50)),
                0,
                :USERID,
                SYSDATE()
            FROM
                T_ConsolidatedAmounts ca
            WHERE
                ca.FinalAmount IS NOT NULL;
            TOTALROWSPROCESSED := :TOTALROWSPROCESSED + SQLROWCOUNT;

            -- Manual resolution 4: OUTPUT clause replaced by read-back on this
            -- run's unique SourceReference.
            INSERT INTO T_INSERTEDLINES (BudgetLineItemID, GLAccountID, CostCenterID, Amount)
            SELECT
                bli.BudgetLineItemID,
                bli.GLAccountID,
                bli.CostCenterID,
                bli.OriginalAmount
            FROM
                <%financial_planning%>.Planning.BudgetLineItem bli
            WHERE
                bli.SourceReference = CAST(:CONSOLIDATIONRUNID AS VARCHAR(50));

            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), 1, 'COMPLETED');
            -- =====================================================================
            -- Commit transaction
            -- =====================================================================
            IF (:PROCOWNSTRANSACTION = TRUE AND CURRENT_TRANSACTION() IS NOT NULL) THEN
                COMMIT;
            END IF;
            ROWSPROCESSED := :TOTALROWSPROCESSED;
            -- Debug output
            IF (:DEBUGMODE = TRUE) THEN
            BEGIN
                SELECT
                        *
                    FROM
                        T_ProcessingLog
                    ORDER BY LogID;
                SELECT
                        *
                    FROM
                        T_InsertedLines;
            END;
            END IF;
            DROP TABLE IF EXISTS T_ConsolidatedAmounts;
        EXCEPTION
            WHEN OTHER THEN
                -- =====================================================================
                -- Error handling block - Pattern differs significantly in Snowflake
                -- =====================================================================
                RETURNCODE := :SQLCODE /*** SSC-FDM-TS0023 - ERROR NUMBER COULD BE DIFFERENT IN SNOWFLAKE ***/;
                ERRORMESSAGE := :SQLERRM /*** SSC-FDM-TS0023 - ERROR MESSAGE COULD BE DIFFERENT IN SNOWFLAKE ***/;
                -- Manual resolutions 3 and 8: no savepoints and no uncommittable
                -- transaction state in Snowflake.
                --   * Procedure-owned transaction -> full rollback, as before.
                --   * Caller-owned transaction -> cannot undo only this
                --     procedure's work; the error is re-raised and the caller
                --     owns the rollback decision.
                IF (:PROCOWNSTRANSACTION = TRUE AND CURRENT_TRANSACTION() IS NOT NULL) THEN
                BEGIN
                    BEGIN
                        ROLLBACK;
                    EXCEPTION
                        WHEN OTHER THEN
                            NULL;
                    END;
                END;
                END IF;
                -- Manual resolution 9: CURSOR_STATUS has no Snowflake equivalent;
                -- attempt the close and ignore a not-open error.
                BEGIN
                    CLOSE HierarchyCursor;
                EXCEPTION
                    WHEN OTHER THEN
                        NULL;
                END;
                BEGIN
                    CLOSE EliminationCursor;
                EXCEPTION
                    WHEN OTHER THEN
                        NULL;
                END;

            -- Log the error
            INSERT INTO T_PROCESSINGLOG (StepName, StartTime, EndTime, RowsAffected, StatusCode, Message)
            VALUES (:CURRENTSTEP, :STEPSTARTTIME, SYSDATE(), 0, 'ERROR', :ERRORMESSAGE);
                DROP TABLE IF EXISTS T_ConsolidatedAmounts;

                -- Re-throw the error
                RAISE;
        END;
        DROP TABLE IF EXISTS T_PROCESSINGLOG;
        DROP TABLE IF EXISTS T_HIERARCHYNODES;
        DROP TABLE IF EXISTS T_INSERTEDHEADERS;
        DROP TABLE IF EXISTS T_INSERTEDLINES;
        RETURN :RETURNCODE;
    END;
$$;