USE DATABASE <%financial_planning%>;

/*
    BudgetHeader - Budget version and scenario header
    Dependencies: FiscalPeriod
*/
    -- ANNUAL, QUARTERLY, ROLLING, FORECAST
    -- BASE, OPTIMISTIC, PESSIMISTIC, STRETCH
    -- For variance calculations
CREATE OR REPLACE TABLE Planning.BudgetHeader (
    BudgetHeaderID INT IDENTITY(1,1) ORDER NOT NULL,
    BudgetCode VARCHAR(30) NOT NULL,
    BudgetName NVARCHAR(100) NOT NULL,
    BudgetType VARCHAR(20) NOT NULL,
    ScenarioType VARCHAR(20) NOT NULL,
    FiscalYear SMALLINT NOT NULL,
    StartPeriodID INT NOT NULL,
    EndPeriodID INT NOT NULL,
    BaseBudgetHeaderID INT NULL,
    StatusCode VARCHAR(15) NOT NULL DEFAULT 'DRAFT',
    SubmittedByUserID INT NULL,
    SubmittedDateTime TIMESTAMP_NTZ(7) NULL,
    ApprovedByUserID INT NULL,
    ApprovedDateTime TIMESTAMP_NTZ(7) NULL,
    LockedDateTime TIMESTAMP_NTZ(7) NULL,
    IsLocked NUMERIC AS (CASE WHEN LockedDateTime IS NOT NULL THEN 1 ELSE 0 END),
    VersionNumber INT NOT NULL DEFAULT 1,
    Notes NVARCHAR NULL,
    -- XML column for flexible metadata - Snowflake handles XML differently (VARIANT)
    ExtendedProperties VARIANT NULL,
    CreatedDateTime TIMESTAMP_NTZ(7) NOT NULL DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7),
    ModifiedDateTime TIMESTAMP_NTZ(7) NOT NULL DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7),
    CONSTRAINT PK_BudgetHeader PRIMARY KEY (BudgetHeaderID),
    CONSTRAINT UQ_BudgetHeader_Code_Year UNIQUE (BudgetCode, FiscalYear, VersionNumber),
    CONSTRAINT FK_BudgetHeader_StartPeriod FOREIGN KEY (StartPeriodID)
        REFERENCES Planning.FiscalPeriod (FiscalPeriodID),
    CONSTRAINT FK_BudgetHeader_EndPeriod FOREIGN KEY (EndPeriodID)
        REFERENCES Planning.FiscalPeriod (FiscalPeriodID),
    CONSTRAINT FK_BudgetHeader_BaseBudget FOREIGN KEY (BaseBudgetHeaderID)
        REFERENCES Planning.BudgetHeader (BudgetHeaderID),
    CONSTRAINT CK_BudgetHeader_Status CHECK (
    --** SSC-FDM-TS0191 - TEXT COMPARISON ON A COLUMN DECLARED WITHOUT COLLATE IS CASE AND ACCENT SENSITIVE IN SNOWFLAKE; RESULTS DIFFER IF THE SOURCE DEFAULT COLLATION IS CASE OR ACCENT INSENSITIVE **
    StatusCode IN ('DRAFT','SUBMITTED','APPROVED','REJECTED','LOCKED','ARCHIVED'))
)
COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
;