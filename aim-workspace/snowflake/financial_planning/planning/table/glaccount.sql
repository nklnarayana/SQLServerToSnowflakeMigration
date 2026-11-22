USE DATABASE <%financial_planning%>;

/*
    GLAccount - General Ledger Account master
    Dependencies: None (base table)
*/
    -- A=Asset, L=Liability, E=Equity, R=Revenue, X=Expense
    -- D=Debit, C=Credit
CREATE OR REPLACE TABLE Planning.GLAccount (
    GLAccountID INT IDENTITY(1,1) ORDER NOT NULL,
    AccountNumber VARCHAR(20) NOT NULL,
    AccountName NVARCHAR(150) NOT NULL,
    AccountType CHAR(1) NOT NULL,
    AccountSubType VARCHAR(30) NULL,
    ParentAccountID INT NULL,
    AccountLevel TINYINT NOT NULL DEFAULT 1,
    IsPostable BOOLEAN NOT NULL DEFAULT true,
    IsBudgetable BOOLEAN NOT NULL DEFAULT true,
    IsStatistical BOOLEAN NOT NULL DEFAULT false,
    NormalBalance CHAR(1) NOT NULL DEFAULT 'D',
    CurrencyCode CHAR(3) NOT NULL DEFAULT 'USD',
    ConsolidationAccountID INT NULL,
    IntercompanyFlag BOOLEAN NOT NULL DEFAULT false,
    IsActive BOOLEAN NOT NULL DEFAULT true,
    CreatedDateTime TIMESTAMP_NTZ(7) NOT NULL DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7),
    ModifiedDateTime TIMESTAMP_NTZ(7) NOT NULL DEFAULT SYSDATE() :: TIMESTAMP_NTZ(7),
    -- Sparse columns for rarely-populated attributes - Snowflake doesn't support SPARSE
    TaxCode VARCHAR(20) NULL,
    StatutoryAccountCode VARCHAR(30) NULL,
    IFRSAccountCode VARCHAR(30) NULL,
    CONSTRAINT PK_GLAccount PRIMARY KEY (GLAccountID),
    CONSTRAINT UQ_GLAccount_Number UNIQUE (AccountNumber),
    CONSTRAINT FK_GLAccount_Parent FOREIGN KEY (ParentAccountID)
        REFERENCES Planning.GLAccount (GLAccountID),
    CONSTRAINT CK_GLAccount_Type CHECK (
    --** SSC-FDM-TS0191 - TEXT COMPARISON ON A COLUMN DECLARED WITHOUT COLLATE IS CASE AND ACCENT SENSITIVE IN SNOWFLAKE; RESULTS DIFFER IF THE SOURCE DEFAULT COLLATION IS CASE OR ACCENT INSENSITIVE **
    AccountType IN ('A','L','E','R','X')),
    CONSTRAINT CK_GLAccount_Balance CHECK (
    --** SSC-FDM-TS0191 - TEXT COMPARISON ON A COLUMN DECLARED WITHOUT COLLATE IS CASE AND ACCENT SENSITIVE IN SNOWFLAKE; RESULTS DIFFER IF THE SOURCE DEFAULT COLLATION IS CASE OR ACCENT INSENSITIVE **
    NormalBalance IN ('D','C'))
)
COMMENT = '{ "origin": "sf_sc", "name": "snowconvert", "version": {  "major": 2,  "minor": 54,  "patch": "2-Pr" }, "attributes": {  "component": "transact",  "convertedOn": "11/21/2026",  "domain": "no-domain-provided",  "migrationid": "wACiAZC/6HqmQFXn1qdfyw==" }}'
;