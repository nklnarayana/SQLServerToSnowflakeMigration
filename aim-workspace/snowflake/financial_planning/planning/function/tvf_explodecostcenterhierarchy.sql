USE DATABASE <%financial_planning%>;

/*
    tvf_ExplodeCostCenterHierarchy - Multi-statement TVF to explode hierarchy
    Dependencies: CostCenter

    ============================================================================
    MANUAL TRANSLATION (was SSC-EWI-TS0204: SnowConvert emitted an empty body)
    ============================================================================
    The source is a multi-statement table-valued function: it seeds a table
    variable with the root rows, then loops (WHILE @RowsInserted > 0 AND
    @CurrentLevel < @MaxDepth) adding one level of children per iteration, and
    finally updates IsLeaf / ChildCount. Snowflake has no multi-statement TVFs
    and no table variables, so the whole body is expressed here as one query
    built on a recursive CTE. Notes on fidelity:

    1. Root-row filter: reproduced EXACTLY as written, including a quirk of
       T-SQL precedence. In the source, AND binds tighter than OR, so
         (@RootCostCenterID IS NULL AND cc.ParentCostCenterID IS NULL)
         OR cc.CostCenterID = @RootCostCenterID AND <active/date filters>
       means the IsActive and effective-date filters apply ONLY when a root id
       is supplied. Called with @RootCostCenterID = NULL, the source returns
       every top-level cost centre regardless of IsActive or dates. That is
       preserved here; it is very likely unintended, so review it.

    2. Depth: the loop ran while @CurrentLevel < @MaxDepth, producing levels
       0..@MaxDepth. The recursion stops on the same condition
       (h.HierarchyLevel < MAXDEPTH).

    3. Cycle guard: the source skipped any cost centre already in the table
       (NOT EXISTS over the whole accumulated set). A recursive CTE cannot see
       its full accumulation, so an ancestor-path check is used instead. Since
       ParentCostCenterID gives each node a single parent, the two are
       equivalent for any real tree; they differ only if the data contains a
       cycle, which both forms refuse to loop on.

    4. IsLeaf counts children in Planning.CostCenter (honouring
       INCLUDEINACTIVE), whereas ChildCount counts children present in the
       returned set - exactly as the source's final UPDATE did. The two can
       therefore disagree, by design.

    5. SortPath used RIGHT('0000000000' + CAST(id AS VARCHAR(10)), 10); LPAD
       is the direct equivalent for ids of up to 10 digits.

    6. RETURNS TABLE drops the source's PRIMARY KEY CLUSTERED (CostCenterID)
       and WITH SCHEMABINDING: Snowflake supports neither on a function
       result. Neither affects the rows returned.
    ============================================================================
*/
CREATE OR REPLACE FUNCTION Planning.tvf_ExplodeCostCenterHierarchy (ROOTCOSTCENTERID INT DEFAULT NULL, MAXDEPTH INT DEFAULT 10, INCLUDEINACTIVE BOOLEAN DEFAULT 0, ASOFDATE DATE DEFAULT NULL
)
RETURNS TABLE (
    CostCenterID INT,
    CostCenterCode VARCHAR(20),
    CostCenterName NVARCHAR(100),
    ParentCostCenterID INT,
    HierarchyLevel INT,
    HierarchyPath NVARCHAR(500),
    SortPath VARCHAR(500),
    IsLeaf BOOLEAN,
    ChildCount INT,
    CumulativeWeight DECIMAL(18, 10)
)
COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
AS
$$
WITH RECURSIVE hier AS (
    -- Root level (HierarchyLevel 0)
    SELECT
        cc.CostCenterID                                            AS CostCenterID,
        cc.CostCenterCode                                          AS CostCenterCode,
        cc.CostCenterName                                          AS CostCenterName,
        cc.ParentCostCenterID                                      AS ParentCostCenterID,
        0                                                          AS HierarchyLevel,
        CAST(cc.CostCenterName AS VARCHAR(500))                    AS HierarchyPath,
        CAST(LPAD(CAST(cc.CostCenterID AS VARCHAR(10)), 10, '0') AS VARCHAR(500)) AS SortPath,
        cc.AllocationWeight                                        AS CumulativeWeight,
        '/' || CAST(cc.CostCenterID AS VARCHAR(10)) || '/'         AS IdPath
    FROM
        Planning.CostCenter cc
    WHERE
        (ROOTCOSTCENTERID IS NULL AND cc.ParentCostCenterID IS NULL)
        OR (cc.CostCenterID = ROOTCOSTCENTERID
            AND (cc.IsActive = TRUE OR INCLUDEINACTIVE = TRUE)
            AND cc.EffectiveFromDate <= NVL(ASOFDATE, CURRENT_DATE())
            AND (cc.EffectiveToDate IS NULL OR cc.EffectiveToDate >= NVL(ASOFDATE, CURRENT_DATE())))

    UNION ALL

    -- One level of children per recursion step
    SELECT
        cc.CostCenterID,
        cc.CostCenterCode,
        cc.CostCenterName,
        cc.ParentCostCenterID,
        h.HierarchyLevel + 1,
        CAST(h.HierarchyPath || ' > ' || cc.CostCenterName AS VARCHAR(500)),
        CAST(h.SortPath || '/' || LPAD(CAST(cc.CostCenterID AS VARCHAR(10)), 10, '0') AS VARCHAR(500)),
        h.CumulativeWeight * cc.AllocationWeight,
        h.IdPath || CAST(cc.CostCenterID AS VARCHAR(10)) || '/'
    FROM
        hier h
    INNER JOIN
        Planning.CostCenter cc
        ON cc.ParentCostCenterID = h.CostCenterID
    WHERE
        h.HierarchyLevel < MAXDEPTH
        AND (cc.IsActive = TRUE OR INCLUDEINACTIVE = TRUE)
        AND cc.EffectiveFromDate <= NVL(ASOFDATE, CURRENT_DATE())
        AND (cc.EffectiveToDate IS NULL OR cc.EffectiveToDate >= NVL(ASOFDATE, CURRENT_DATE()))
        AND h.IdPath NOT LIKE '%/' || CAST(cc.CostCenterID AS VARCHAR(10)) || '/%'
),
returned_children AS (
    -- ChildCount: children present in the returned set (as the source's UPDATE did)
    SELECT
        h.ParentCostCenterID AS ParentID,
        COUNT(*)             AS Cnt
    FROM
        hier h
    WHERE
        h.ParentCostCenterID IS NOT NULL
    GROUP BY
        h.ParentCostCenterID
),
source_children AS (
    -- IsLeaf: any child in Planning.CostCenter, honouring INCLUDEINACTIVE
    SELECT
        cc.ParentCostCenterID AS ParentID,
        COUNT(*)              AS Cnt
    FROM
        Planning.CostCenter cc
    WHERE
        cc.ParentCostCenterID IS NOT NULL
        AND (cc.IsActive = TRUE OR INCLUDEINACTIVE = TRUE)
    GROUP BY
        cc.ParentCostCenterID
)
SELECT
    h.CostCenterID,
    h.CostCenterCode,
    h.CostCenterName,
    h.ParentCostCenterID,
    h.HierarchyLevel,
    h.HierarchyPath,
    h.SortPath,
    IFF(NVL(sch.Cnt, 0) > 0, FALSE, TRUE) AS IsLeaf,
    NVL(rch.Cnt, 0)                       AS ChildCount,
    h.CumulativeWeight
FROM
    hier h
LEFT JOIN
    source_children sch
    ON sch.ParentID = h.CostCenterID
LEFT JOIN
    returned_children rch
    ON rch.ParentID = h.CostCenterID
$$;
