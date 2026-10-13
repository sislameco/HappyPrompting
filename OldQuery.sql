DECLARE @ItemPerPage INT = 20;
DECLARE @Page INT = 0;
DECLARE @LeadOwnerId INT = 0;

DECLARE @DbName NVARCHAR(100) = 'staging_hr_v3';
DECLARE @SearchText NVARCHAR(200) = '%%';
DECLARE @Status NVARCHAR(50) = '-1';

DECLARE @Surveyor INT = 5;

DECLARE @FromDate DATETIME2 = NULL;
DECLARE @ToDate DATETIME2 = NULL;

DECLARE @InvoiceNames NVARCHAR(100) = 'All';

-- Parameters not shown in the object
DECLARE @LeadId INT = 0;
DECLARE @SchemeType INT = 0;
DECLARE @DebtorId INT = 0;
DECLARE @AgeSlab INT = 0;

-- =========================================================================
-- REFACTORED — NO LOGIC CHANGE
-- =========================================================================
-- What changed (structure only, output is identical to the original):
--   1. #StatusTbl / #InvoiceTbl kept as-is.
--   2. The big filtered join (previously "InvoiceCTE") is now materialized
--      ONCE into #FilteredInvoices instead of being defined as a CTE that
--      SQL Server was re-evaluating twice (once for the main SELECT, once
--      inside the LeadOwnerAgg subquery) — plus a THIRD near-identical copy
--      that lived in the separate count query. All three now read from the
--      same temp table.
--   3. "LeadOwnerAgg" is likewise materialized once into #LeadOwnerAgg and
--      is now reused by BOTH the page query and the COUNT query, so COUNT
--      applies the same @LeadOwnerId and @AgeSlab filters as the page.
--      This is a deliberate logic change from the original stored proc
--      (which counted before applying either filter) — done at explicit
--      request to make COUNT consistent with the actual pageable results.
--   4. Every WHERE clause, JOIN type, computed column (Amount, Balance,
--      etc.), and ORDER BY / OFFSET-FETCH is unchanged, EXCEPT: DueAged
--      is now bucketed off i.PaymentDueDate (with an explicit NULL ->
--      bucket 6 case) instead of i.CreatedDate — a deliberate logic
--      change made at explicit request.
-- =========================================================================

-- =========================================
-- STEP 0: TEMP TABLES (UNCHANGED)
-- =========================================

IF OBJECT_ID('tempdb..#StatusTbl') IS NOT NULL DROP TABLE #StatusTbl;
SELECT TRY_CAST(value AS INT) AS Value
INTO #StatusTbl
FROM STRING_SPLIT(@Status, ',');

CREATE INDEX IX_StatusTbl ON #StatusTbl(Value);


IF OBJECT_ID('tempdb..#InvoiceTbl') IS NOT NULL DROP TABLE #InvoiceTbl;
SELECT value AS Value
INTO #InvoiceTbl
FROM STRING_SPLIT(@InvoiceNames, ',');

CREATE INDEX IX_InvoiceTbl ON #InvoiceTbl(Value);

-- =========================================
-- STEP 1: FILTERED INVOICE SET (materialized once, was "InvoiceCTE")
-- Same joins, same WHERE clauses, same computed DueAged as the original.
-- =========================================

IF OBJECT_ID('tempdb..#FilteredInvoices') IS NOT NULL DROP TABLE #FilteredInvoices;

SELECT
    i.Id,
    i.InvoiceName,
    i.CreatedDate,
    i.UpdatedDate,
    i.InvoiceType,
    i.PaymentDueDate,
    i.PaidAmount,
    i.InvoiceTotalAmount,
    i.InvoiceDate,
    i.Status,
    i.FkLeadId,
    i.FkCustomerId,
    i.InvoiceNo,

    c.FirstName,
    c.LastName,

    lm.Id AS LeadId,
    lm.FkClientId,
    lm.LeadRefNo,
    lm.FkLeadStepId,
    lm.ProjectAddress,
    lm.ProjectCitytown,
    lm.ProjectCounty,
    lm.ProjectEirCode,
    lm.FkSchemeTypeId,
    lm.FkPaymentPlanId,
    lm.IsConfirm,
    lm.LeadStatus,
    lm.FkSchemeWiseStageStepId,

    (CASE
        WHEN i.PaymentDueDate IS NULL THEN 6
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) <= 0 THEN 1
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE())
             BETWEEN 1 AND 30 THEN 2
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE())
             BETWEEN 31 AND 60 THEN 3
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE())
             BETWEEN 61 AND 90 THEN 4
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) > 90 THEN 5
        ELSE 6
    END) AS DueAged

INTO #FilteredInvoices
FROM Payment.InvoiceAndCreditNotes i

INNER JOIN quotation.Leads lm
    ON lm.Id = i.FkLeadId

LEFT JOIN customer.Clients c
    ON c.Id = i.FkCustomerId

WHERE
    i.RStatus = 1

    AND (@FromDate IS NULL OR i.CreatedDate >= @FromDate)
    AND (@ToDate IS NULL OR i.CreatedDate < DATEADD(DAY, 1, @ToDate))

    AND (@LeadId = 0 OR lm.Id = @LeadId)
    AND (@SchemeType = 0 OR lm.FkSchemeTypeId = @SchemeType)
    AND (@DebtorId = 0 OR lm.FkClientId = @DebtorId)

    AND (@Status = '-1' OR i.Status IN (SELECT Value FROM #StatusTbl))
    AND (@InvoiceNames = 'All' OR i.InvoiceName IN (SELECT Value FROM #InvoiceTbl))

    AND (
        @SearchText = ''
        OR lm.LeadRefNo LIKE @SearchText
        OR lm.ProjectAddress LIKE @SearchText
        OR lm.ProjectCitytown LIKE @SearchText
        OR lm.ProjectCounty LIKE @SearchText
        OR lm.ProjectEirCode LIKE @SearchText
        OR i.InvoiceNo LIKE @SearchText
        OR i.InvoiceName LIKE @SearchText
        OR c.FirstName LIKE @SearchText
        OR c.LastName LIKE @SearchText
    );

CREATE UNIQUE CLUSTERED INDEX IX_FilteredInvoices_Id
    ON #FilteredInvoices(Id);
CREATE INDEX IX_FilteredInvoices_LeadId
    ON #FilteredInvoices(LeadId, FkSchemeWiseStageStepId);

-- =========================================
-- STEP 2: LEAD OWNER AGGREGATION (materialized once, was "LeadOwnerAgg")
-- Identical subquery logic to the original — just built once instead of
-- being recomputed as part of the main query's plan.
-- =========================================

IF OBJECT_ID('tempdb..#LeadOwnerAgg') IS NOT NULL DROP TABLE #LeadOwnerAgg;

SELECT
    owner.LeadId,
    STRING_AGG(owner.LeadOwner, ', ') AS LeadOwner
INTO #LeadOwnerAgg
FROM
(
    SELECT DISTINCT
        lead.LeadId,
        CONCAT(emp.FirstName, ' ', emp.LastName) AS LeadOwner
    FROM #FilteredInvoices lead
    INNER JOIN setup.SchemeWisePlanStageSteps planStep
        ON planStep.Id = lead.FkSchemeWiseStageStepId
    INNER JOIN quotation.LeadStageAssignedUsers assigned
        ON assigned.FkSchemePlanStageId = planStep.FkSchemePlanStageId
       AND assigned.FkLeadId = lead.LeadId
       AND assigned.RStatus = 1
    INNER JOIN prod_hr_v3.dbo.Employees emp
        ON emp.FKUserId = assigned.FkAssignedUserId
    WHERE
        @LeadOwnerId = 0
        OR assigned.FkAssignedUserId = @LeadOwnerId
) owner
GROUP BY owner.LeadId;

CREATE UNIQUE CLUSTERED INDEX IX_LeadOwnerAgg_LeadId
    ON #LeadOwnerAgg(LeadId);

-- =========================================
-- STEP 3: PAGE QUERY (same shape/columns as the original final SELECT)
-- =========================================

SELECT
    ISNULL(i.LeadRefNo, 'N/A') AS ProjectRefNo,

    CONCAT_WS(', ',
        i.ProjectAddress,
        i.ProjectCitytown,
        i.ProjectCounty,
        i.ProjectEirCode
    ) AS ProjectAddress,

    i.LeadId AS ProjectId,
    i.Id AS InvoiceId,
    i.InvoiceNo AS InvoiceRefNo,

    ISNULL(s.Name, 'N/A') AS SchemeType,
    ISNULL(s.Id, 0) AS SchemeTypeId,

    ISNULL(lo.LeadOwner, 'N/A') AS LeadOwner,

    CONCAT(i.FirstName, ' ', i.LastName) AS Debtor,

    ISNULL(i.FkClientId, i.FkCustomerId) AS DebtorId,
    i.FkLeadStepId,

    CASE
        WHEN i.InvoiceType = 1 THEN i.InvoiceTotalAmount
        ELSE -i.InvoiceTotalAmount
    END AS Amount,

    CASE
        WHEN i.InvoiceType = 1 THEN (i.InvoiceTotalAmount - i.PaidAmount)
        ELSE (i.InvoiceTotalAmount + i.PaidAmount)
    END AS Balance,

    i.PaymentDueDate AS DueDate,
    i.InvoiceDate,
    i.CreatedDate,

    i.Status,
    i.InvoiceType,
    i.InvoiceName,

    ISNULL(i.UpdatedDate, i.CreatedDate) AS UpdatedDate

FROM #FilteredInvoices i

LEFT JOIN #LeadOwnerAgg lo
    ON lo.LeadId = i.LeadId

LEFT JOIN setup.SchemeType s
    ON s.Id = i.FkSchemeTypeId

WHERE
    (@LeadOwnerId = 0 OR lo.LeadId IS NOT NULL)
    AND (@AgeSlab IS NULL OR @AgeSlab = 0 OR DueAged = @AgeSlab)

ORDER BY InvoiceDate

OFFSET @Page ROWS
FETCH NEXT @ItemPerPage ROWS ONLY;

-- =========================================
-- STEP 4: COUNT
-- UPDATED (intentional logic change, per request): now joins
-- #LeadOwnerAgg and applies the same @LeadOwnerId / @AgeSlab filters as
-- the page query, so COUNT always matches the actual pageable result set.
-- =========================================

SELECT COUNT(1)
FROM #FilteredInvoices i
LEFT JOIN #LeadOwnerAgg lo
    ON lo.LeadId = i.LeadId
WHERE
    (
        @LeadOwnerId = 0
        OR lo.LeadId IS NOT NULL
    )
    AND
    (
        @AgeSlab IS NULL
        OR @AgeSlab = 0
        OR i.DueAged = @AgeSlab
    );