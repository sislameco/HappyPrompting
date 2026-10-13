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

DECLARE @TotalCount BIGINT;

DROP TABLE IF EXISTS #StatusTbl;
DROP TABLE IF EXISTS #InvoiceTbl;
DROP TABLE IF EXISTS #FilteredInvoices;
DROP TABLE IF EXISTS #LeadOwnerAgg;
DROP TABLE IF EXISTS #OwnerEligibleLeads;
DROP TABLE IF EXISTS #PageInvoices;
DROP TABLE IF EXISTS #PageLeadStages;
DROP TABLE IF EXISTS #PageOwners;
DROP TABLE IF EXISTS #PageOwnerAgg;

SELECT TRY_CAST(value AS INT) AS Value
INTO #StatusTbl
FROM STRING_SPLIT(@Status, ',');
CREATE INDEX IX_StatusTbl_Value ON #StatusTbl(Value);

SELECT value AS Value
INTO #InvoiceTbl
FROM STRING_SPLIT(@InvoiceNames, ',');
CREATE INDEX IX_InvoiceTbl_Value ON #InvoiceTbl(Value);

/* Base filtering only. Do not join assignment/employee tables here unless owner filtering requires it. */
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
    CASE
        WHEN i.PaymentDueDate IS NULL THEN 6
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) <= 0 THEN 1
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) BETWEEN 1 AND 30 THEN 2
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) BETWEEN 31 AND 60 THEN 3
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) BETWEEN 61 AND 90 THEN 4
        WHEN DATEDIFF(DAY, i.PaymentDueDate, GETDATE()) > 90 THEN 5
        ELSE 6
    END AS DueAged
INTO #FilteredInvoices
FROM Payment.InvoiceAndCreditNotes AS i
INNER JOIN quotation.Leads AS lm
    ON lm.Id = i.FkLeadId
LEFT JOIN customer.Clients AS c
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
    )
OPTION (RECOMPILE);

/* Supports distinct lead/stage combinations for page-only owner lookup. */
CREATE NONCLUSTERED INDEX IX_FilteredInvoices_Lead_Stage
    ON #FilteredInvoices (LeadId, FkSchemeWiseStageStepId)
    INCLUDE (DueAged);

/* Materialize only the page. Owner aggregation is performed afterward. */
SELECT TOP (0) * INTO #PageInvoices FROM #FilteredInvoices;
SELECT TOP (0) LeadId, CAST(NULL AS NVARCHAR(MAX)) AS LeadOwner
INTO #PageOwnerAgg FROM #FilteredInvoices;

/* If an owner is selected, determine eligible LeadIds before count/pagination.
   A lead qualifies when the selected owner is assigned to any stage represented by
   that lead in #FilteredInvoices, matching the original lead-level filter semantics. */
IF @LeadOwnerId <> 0
BEGIN
    SELECT DISTINCT fi.LeadId
    INTO #OwnerEligibleLeads
    FROM #FilteredInvoices AS fi
    INNER JOIN setup.SchemeWisePlanStageSteps AS planStep
        ON planStep.Id = fi.FkSchemeWiseStageStepId
    INNER JOIN quotation.LeadStageAssignedUsers AS assigned
        ON assigned.FkLeadId = fi.LeadId
       AND assigned.FkSchemePlanStageId = planStep.FkSchemePlanStageId
       AND assigned.RStatus = 1
       AND assigned.FkAssignedUserId = @LeadOwnerId
    INNER JOIN prod_hr_v3.dbo.Employees AS emp
        ON emp.FKUserId = assigned.FkAssignedUserId;

    CREATE UNIQUE CLUSTERED INDEX IX_OwnerEligibleLeads_LeadId
        ON #OwnerEligibleLeads(LeadId);

    SELECT @TotalCount = COUNT_BIG(*)
    FROM #FilteredInvoices AS fi
    INNER JOIN #OwnerEligibleLeads AS eligible
        ON eligible.LeadId = fi.LeadId
    WHERE (@AgeSlab IS NULL OR @AgeSlab = 0 OR fi.DueAged = @AgeSlab);

    INSERT INTO #PageInvoices
    SELECT fi.*
    FROM #FilteredInvoices AS fi
    INNER JOIN #OwnerEligibleLeads AS eligible
        ON eligible.LeadId = fi.LeadId
    WHERE (@AgeSlab IS NULL OR @AgeSlab = 0 OR fi.DueAged = @AgeSlab)
    ORDER BY fi.InvoiceDate, fi.Id
    OFFSET @Page ROWS FETCH NEXT @ItemPerPage ROWS ONLY;
END
ELSE
BEGIN
    SELECT @TotalCount = COUNT_BIG(*)
    FROM #FilteredInvoices AS fi
    WHERE (@AgeSlab IS NULL OR @AgeSlab = 0 OR fi.DueAged = @AgeSlab);

    INSERT INTO #PageInvoices
    SELECT fi.*
    FROM #FilteredInvoices AS fi
    WHERE (@AgeSlab IS NULL OR @AgeSlab = 0 OR fi.DueAged = @AgeSlab)
    ORDER BY fi.InvoiceDate, fi.Id
    OFFSET @Page ROWS FETCH NEXT @ItemPerPage ROWS ONLY;
END;

/* Resolve owners only for leads present on the page. The stage combinations are taken
   from all base-filtered invoices for those leads to preserve the original aggregation scope. */
IF @LeadOwnerId <> 0
BEGIN
    INSERT INTO #PageOwnerAgg (LeadId, LeadOwner)
    SELECT owner.LeadId, STRING_AGG(owner.LeadOwner, ', ') AS LeadOwner
    FROM
    (
        SELECT DISTINCT
            fi.LeadId,
            CONCAT(emp.FirstName, ' ', emp.LastName) AS LeadOwner
        FROM #FilteredInvoices AS fi
        INNER JOIN (SELECT DISTINCT LeadId FROM #PageInvoices) AS p
            ON p.LeadId = fi.LeadId
        INNER JOIN setup.SchemeWisePlanStageSteps AS planStep
            ON planStep.Id = fi.FkSchemeWiseStageStepId
        INNER JOIN quotation.LeadStageAssignedUsers AS assigned
            ON assigned.FkLeadId = fi.LeadId
           AND assigned.FkSchemePlanStageId = planStep.FkSchemePlanStageId
           AND assigned.RStatus = 1
           AND assigned.FkAssignedUserId = @LeadOwnerId
        INNER JOIN prod_hr_v3.dbo.Employees AS emp
            ON emp.FKUserId = assigned.FkAssignedUserId
    ) AS owner
    GROUP BY owner.LeadId;
END
ELSE
BEGIN
    INSERT INTO #PageOwnerAgg (LeadId, LeadOwner)
    SELECT owner.LeadId, STRING_AGG(owner.LeadOwner, ', ') AS LeadOwner
    FROM
    (
        SELECT DISTINCT
            fi.LeadId,
            CONCAT(emp.FirstName, ' ', emp.LastName) AS LeadOwner
        FROM #FilteredInvoices AS fi
        INNER JOIN (SELECT DISTINCT LeadId FROM #PageInvoices) AS p
            ON p.LeadId = fi.LeadId
        INNER JOIN setup.SchemeWisePlanStageSteps AS planStep
            ON planStep.Id = fi.FkSchemeWiseStageStepId
        INNER JOIN quotation.LeadStageAssignedUsers AS assigned
            ON assigned.FkLeadId = fi.LeadId
           AND assigned.FkSchemePlanStageId = planStep.FkSchemePlanStageId
           AND assigned.RStatus = 1
        INNER JOIN prod_hr_v3.dbo.Employees AS emp
            ON emp.FKUserId = assigned.FkAssignedUserId
    ) AS owner
    GROUP BY owner.LeadId;
END;

CREATE UNIQUE CLUSTERED INDEX IX_PageOwnerAgg_LeadId ON #PageOwnerAgg(LeadId);

/* Final result: one aggregated owner row per page lead. */
SELECT
    ISNULL(i.LeadRefNo, 'N/A') AS ProjectRefNo,
    CONCAT_WS(', ', i.ProjectAddress, i.ProjectCitytown, i.ProjectCounty, i.ProjectEirCode) AS ProjectAddress,
    i.LeadId AS ProjectId,
    i.Id AS InvoiceId,
    i.InvoiceNo AS InvoiceRefNo,
    ISNULL(s.Name, 'N/A') AS SchemeType,
    ISNULL(s.Id, 0) AS SchemeTypeId,
    ISNULL(lo.LeadOwner, 'N/A') AS LeadOwner,
    CONCAT(i.FirstName, ' ', i.LastName) AS Debtor,
    ISNULL(i.FkClientId, i.FkCustomerId) AS DebtorId,
    i.FkLeadStepId,
    CASE WHEN i.InvoiceType = 1 THEN i.InvoiceTotalAmount ELSE -i.InvoiceTotalAmount END AS Amount,
    CASE WHEN i.InvoiceType = 1 THEN (i.InvoiceTotalAmount - i.PaidAmount) ELSE (i.InvoiceTotalAmount + i.PaidAmount) END AS Balance,
    i.PaymentDueDate AS DueDate,
    i.InvoiceDate,
    i.CreatedDate,
    i.Status,
    i.InvoiceType,
    i.InvoiceName,
    ISNULL(i.UpdatedDate, i.CreatedDate) AS UpdatedDate
FROM #PageInvoices AS i
LEFT JOIN #PageOwnerAgg AS lo ON lo.LeadId = i.LeadId
LEFT JOIN setup.SchemeType AS s ON s.Id = i.FkSchemeTypeId
ORDER BY i.InvoiceDate, i.Id;

/* Keep the total-count result set after the page result set. */
SELECT @TotalCount AS TotalCount;

/* Candidate permanent index only; inspect sys.indexes first and test actual logical reads.
CREATE NONCLUSTERED INDEX IX_LeadStageAssignedUsers_Active_LeadStage
ON quotation.LeadStageAssignedUsers (FkLeadId, FkSchemePlanStageId)
INCLUDE (FkAssignedUserId)
WHERE RStatus = 1;
*/
