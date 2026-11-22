USE DATABASE <%financial_planning%>;

/*
    CostCenter - Organizational hierarchy for cost allocation
    Dependencies: None (base table)

    Note: Uses HierarchyID which has no Snowflake equivalent
*/
    -- No Snowflake equivalent
    -- Computed column from HierarchyID
    -- Temporal table
    -- System-versioned temporal table
    --** SSC-FDM-0048 - UNSUPPORTED VIRTUAL COLUMN(S), VIEW Planning.CostCenter_View CREATED AS A WORKAROUND. REASON(S): UDF helper functions. **
CREATE OR REPLACE TABLE Planning.CostCenter (
        CostCenterID INT IDENTITY(1,1) ORDER NOT NULL,
        CostCenterCode VARCHAR(20) NOT NULL,
        CostCenterName NVARCHAR(100) NOT NULL,
        ParentCostCenterID INT NULL,
        HierarchyPath VARCHAR NULL,
        ManagerEmployeeID INT NULL,
        DepartmentCode VARCHAR(10) NULL,
        IsActive BOOLEAN NOT NULL DEFAULT true,
        EffectiveFromDate DATE NOT NULL,
        EffectiveToDate DATE NULL,
        AllocationWeight DECIMAL(5, 4) NOT NULL DEFAULT 1.0000,
        --** SSC-FDM-0017 - WITH SYSTEM VERSIONING CLAUSE IS NOT SUPPORTED BY SNOWFLAKE. **
        ValidFrom TIMESTAMP_NTZ(7) DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7) NOT NULL,
        --** SSC-FDM-0017 - WITH SYSTEM VERSIONING CLAUSE IS NOT SUPPORTED BY SNOWFLAKE. **
        ValidTo TIMESTAMP_NTZ(7) DEFAULT '9999-12-31 23:59:59.9999999' :: TIMESTAMP_NTZ(7) NOT NULL
--                                                                                                   ,
--        --** SSC-FDM-0017 - WITH SYSTEM VERSIONING CLAUSE IS NOT SUPPORTED BY SNOWFLAKE. **
--        PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
                                                   ,
        CONSTRAINT PK_CostCenter PRIMARY KEY (CostCenterID),
        CONSTRAINT UQ_CostCenter_Code UNIQUE (CostCenterCode),
        CONSTRAINT FK_CostCenter_Parent FOREIGN KEY (ParentCostCenterID)
            REFERENCES Planning.CostCenter (CostCenterID),
        CONSTRAINT CK_CostCenter_Weight CHECK (AllocationWeight BETWEEN 0 AND 1)
    )
--    WITH (
----        --** SSC-FDM-0017 - WITH SYSTEM VERSIONING CLAUSE IS NOT SUPPORTED BY SNOWFLAKE. **
--        SYSTEM_VERSIONING = ON (HISTORY_TABLE = Planning.CostCenterHistory))
    COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
;