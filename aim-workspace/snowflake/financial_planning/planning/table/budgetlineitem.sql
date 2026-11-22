USE DATABASE <%financial_planning%>;

/*
    BudgetLineItem - Individual budget amounts by account/cost center/period
    Dependencies: BudgetHeader, GLAccount, CostCenter, FiscalPeriod
*/
    -- Computed persisted
    -- EVEN, SEASONAL, CUSTOM, PRIOR_YEAR, CONSOLIDATED
    -- GUID type
    -- HASHBYTES computed
CREATE OR REPLACE TABLE Planning.BudgetLineItem (
    BudgetLineItemID BIGINT IDENTITY(1,1) ORDER NOT NULL,
    BudgetHeaderID INT NOT NULL,
    GLAccountID INT NOT NULL,
    CostCenterID INT NOT NULL,
    FiscalPeriodID INT NOT NULL,
    -- Amounts in multiple representations
    OriginalAmount DECIMAL(19, 4) NOT NULL DEFAULT 0,
    AdjustedAmount DECIMAL(19, 4) NOT NULL DEFAULT 0,
    FinalAmount DECIMAL(20, 4) AS (OriginalAmount + AdjustedAmount),
    LocalCurrencyAmount DECIMAL(19, 4) NULL,
    ReportingCurrencyAmount DECIMAL(19, 4) NULL,
    StatisticalQuantity DECIMAL(18, 6) NULL,
    UnitOfMeasure VARCHAR(10) NULL,
    -- Spreading pattern for forecast
    SpreadMethodCode VARCHAR(20) NULL,
    SeasonalityFactor DECIMAL(8, 6) NULL,
    -- Source tracking
    SourceSystem VARCHAR(30) NULL,
    SourceReference VARCHAR(100) NULL,
    ImportBatchID VARCHAR NULL,
    -- Allocation tracking
    IsAllocated BOOLEAN NOT NULL DEFAULT false,
    AllocationSourceLineID BIGINT NULL,
    AllocationPercentage DECIMAL(8, 6) NULL,
    -- Audit columns
    LastModifiedByUserID INT NULL,
    LastModifiedDateTime TIMESTAMP_NTZ(7) NOT NULL DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7),
    RowHash VARBINARY AS (SHA2_BINARY(CONCAT(COALESCE(CAST(GLAccountID AS VARCHAR) :: STRING, ''), '|', COALESCE(
    CAST(CostCenterID AS VARCHAR) :: STRING, ''), '|', COALESCE(
    CAST(FiscalPeriodID AS VARCHAR) :: STRING, ''), '|', COALESCE(
    CAST(/*FinalAmount*/OriginalAmount + AdjustedAmount AS VARCHAR) :: STRING, '')), 256)),
    CONSTRAINT PK_BudgetLineItem PRIMARY KEY (BudgetLineItemID),
    CONSTRAINT FK_BudgetLineItem_Header FOREIGN KEY (BudgetHeaderID)
        REFERENCES Planning.BudgetHeader (BudgetHeaderID),
    CONSTRAINT FK_BudgetLineItem_Account FOREIGN KEY (GLAccountID)
        REFERENCES Planning.GLAccount (GLAccountID),
    CONSTRAINT FK_BudgetLineItem_CostCenter FOREIGN KEY (CostCenterID)
        REFERENCES Planning.CostCenter (CostCenterID),
    CONSTRAINT FK_BudgetLineItem_Period FOREIGN KEY (FiscalPeriodID)
        REFERENCES Planning.FiscalPeriod (FiscalPeriodID),
    CONSTRAINT FK_BudgetLineItem_AllocationSource FOREIGN KEY (AllocationSourceLineID)
        REFERENCES Planning.BudgetLineItem (BudgetLineItemID)
)
COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
;