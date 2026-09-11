USE MSN_TexWeave_DB;
GO

-- ============================================================================
-- SECTION 1: NX-19 – CENTRAL AUDIT LOG SCHEMA
-- ============================================================================
IF OBJECT_ID('dbo.AuditLog', 'U') IS NOT NULL
    DROP TABLE dbo.AuditLog;
GO

CREATE TABLE dbo.AuditLog (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    TableName VARCHAR(100) NOT NULL,
    OperationType VARCHAR(20) NOT NULL, -- 'INSERT', 'UPDATE', 'DELETE'
    RecordID INT NOT NULL,
    ColumnName VARCHAR(100) NOT NULL,
    OldValue VARCHAR(MAX) NULL,
    NewValue VARCHAR(MAX) NULL,
    ChangedBy VARCHAR(100) DEFAULT SYSTEM_USER,
    ChangedAt DATE DEFAULT CAST(GETDATE() AS DATE)
);
GO

-- ============================================================================
-- SECTION 2: NX-20 – PURCHASE ORDERS & DETAILS AUTOMATION TRIGGERS
-- ============================================================================

-- Trigger 1: Header Audit (Status Changes, Soft Deletes, Hard Deletes)
CREATE OR ALTER TRIGGER trg_PurchaseOrders_Audit
ON PurchaseOrders
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- Track Soft-Delete / Deactivation
    IF UPDATE(IsActive)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'PurchaseOrders', 
            'UPDATE', 
            i.POID, 
            'IsActive', 
            CAST(d.IsActive AS VARCHAR(50)), 
            CAST(i.IsActive AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.POID = d.POID
        WHERE i.IsActive <> d.IsActive;
    END

    -- Track Status Transition (e.g., 'Pending' -> 'Approved')
    IF UPDATE(Status)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'PurchaseOrders', 
            'UPDATE', 
            i.POID, 
            'Status', 
            CAST(d.Status AS VARCHAR(50)), 
            CAST(i.Status AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.POID = d.POID
        WHERE i.Status <> d.Status;
    END

    -- Track Physical Hard Delete
    IF NOT EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'PurchaseOrders', 
            'DELETE', 
            d.POID, 
            'ALL', 
            d.PONumber, 
            NULL
        FROM deleted d;
    END
END;
GO

-- Trigger 2: Line Item Audit & Automatic Header Financial Rollup
CREATE OR ALTER TRIGGER trg_PurchaseOrderDetails_AuditAndRollup
ON PurchaseOrderDetails
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- A. Audit Line Insertions
    IF EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'PurchaseOrderDetails', 
            'INSERT', 
            i.PODetailID, 
            'QuantityOrdered', 
            NULL, 
            CAST(i.QuantityOrdered AS VARCHAR(50))
        FROM inserted i;
    END

    -- B. Audit Quantity / Price / Received Quantity Updates
    IF EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
    BEGIN
        IF UPDATE(QuantityOrdered)
        BEGIN
            INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
            SELECT 
                'PurchaseOrderDetails', 
                'UPDATE', 
                i.PODetailID, 
                'QuantityOrdered', 
                CAST(d.QuantityOrdered AS VARCHAR(50)), 
                CAST(i.QuantityOrdered AS VARCHAR(50))
            FROM inserted i
            INNER JOIN deleted d ON i.PODetailID = d.PODetailID
            WHERE i.QuantityOrdered <> d.QuantityOrdered;
        END

        IF UPDATE(ReceivedQuantity)
        BEGIN
            INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
            SELECT 
                'PurchaseOrderDetails', 
                'UPDATE', 
                i.PODetailID, 
                'ReceivedQuantity', 
                CAST(d.ReceivedQuantity AS VARCHAR(50)), 
                CAST(i.ReceivedQuantity AS VARCHAR(50))
            FROM inserted i
            INNER JOIN deleted d ON i.PODetailID = d.PODetailID
            WHERE i.ReceivedQuantity <> d.ReceivedQuantity;
        END

        IF UPDATE(UnitPrice)
        BEGIN
            INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
            SELECT 
                'PurchaseOrderDetails', 
                'UPDATE', 
                i.PODetailID, 
                'UnitPrice', 
                CAST(d.UnitPrice AS VARCHAR(50)), 
                CAST(i.UnitPrice AS VARCHAR(50))
            FROM inserted i
            INNER JOIN deleted d ON i.PODetailID = d.PODetailID
            WHERE i.UnitPrice <> d.UnitPrice;
        END
    END

    -- C. Automated Set-Based Rollup into PurchaseOrders.TotalAmount
    ;WITH AffectedPOs AS (
        SELECT DISTINCT POID FROM inserted
        UNION
        SELECT DISTINCT POID FROM deleted
    )
    UPDATE po
    SET TotalAmount = ISNULL((
        SELECT SUM(pod.QuantityOrdered * pod.UnitPrice)
        FROM PurchaseOrderDetails pod
        WHERE pod.POID = po.POID
    ), 0.00)
    FROM PurchaseOrders po
    INNER JOIN AffectedPOs a ON po.POID = a.POID;
END;
GO

-- ============================================================================
-- SECTION 3: NX-21 – PRODUCTION ORDERS TRIGGER
-- ============================================================================
CREATE OR ALTER TRIGGER trg_ProductionOrders_Complete_Audit
ON ProductionOrders
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(Status)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'ProductionOrders', 
            'UPDATE', 
            i.ProductionOrderID, 
            'Status', 
            CAST(d.Status AS VARCHAR(50)), 
            CAST(i.Status AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.ProductionOrderID = d.ProductionOrderID
        WHERE i.Status <> d.Status;
    END
END;
GO

-- ============================================================================
-- SECTION 4: NX-22 – QUALITY CHECKS TRIGGER
-- ============================================================================
CREATE OR ALTER TRIGGER trg_QualityChecks_Audit
ON QualityChecks
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
    SELECT 
        'QualityChecks',
        CASE WHEN d.CheckID IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
        i.CheckID,
        'CheckRecord',
        NULL,
        CONCAT('OrderID: ', i.ProductionOrderID)
    FROM inserted i
    LEFT JOIN deleted d ON i.CheckID = d.CheckID;
END;
GO

-- ============================================================================
-- SECTION 5: NX-23 – SALES ORDERS TRIGGER
-- ============================================================================
CREATE OR ALTER TRIGGER trg_SalesOrders_Audit
ON SalesOrders
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(Status)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'SalesOrders',
            'UPDATE',
            i.SalesOrderID,
            'Status',
            CAST(d.Status AS VARCHAR(50)),
            CAST(i.Status AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.SalesOrderID = d.SalesOrderID
        WHERE i.Status <> d.Status;
    END
END;
GO

-- ============================================================================
-- SECTION 6: NX-24 – SHIPMENTS TRIGGER
-- ============================================================================
CREATE OR ALTER TRIGGER trg_Shipments_Audit
ON Shipments
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
    SELECT 
        'Shipments',
        CASE WHEN d.ShipmentID IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
        i.ShipmentID,
        'ShipmentRecord',
        NULL,
        CONCAT('Tracking: ', i.TrackingNumber)
    FROM inserted i
    LEFT JOIN deleted d ON i.ShipmentID = d.ShipmentID;
END;
GO

-- ============================================================================
-- SECTION 7: NX-25 – INVENTORY & SOFT-DELETE AUTOMATION TRIGGERS
-- ============================================================================

-- Trigger: Product Soft-Delete Audit Tracker
CREATE OR ALTER TRIGGER trg_Products_Audit
ON Products
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(IsActive)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'Products', 
            'UPDATE', 
            i.ProductID, 
            'IsActive', 
            CAST(d.IsActive AS VARCHAR(50)), 
            CAST(i.IsActive AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.ProductID = d.ProductID
        WHERE i.IsActive <> d.IsActive;
    END
END;
GO

-- Trigger: Finished Goods Inventory Auditing
CREATE OR ALTER TRIGGER trg_FGInventory_Audit
ON FinishedGoodsInventory
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(QuantityOnHand)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'FinishedGoodsInventory', 
            'UPDATE', 
            i.FGInventoryID, 
            'QuantityOnHand', 
            CAST(d.QuantityOnHand AS VARCHAR(50)), 
            CAST(i.QuantityOnHand AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.FGInventoryID = d.FGInventoryID
        WHERE i.QuantityOnHand <> d.QuantityOnHand;
    END

    IF UPDATE(ReservedQuantity)
    BEGIN
        INSERT INTO AuditLog (TableName, OperationType, RecordID, ColumnName, OldValue, NewValue)
        SELECT 
            'FinishedGoodsInventory', 
            'UPDATE', 
            i.FGInventoryID, 
            'ReservedQuantity', 
            CAST(d.ReservedQuantity AS VARCHAR(50)), 
            CAST(i.ReservedQuantity AS VARCHAR(50))
        FROM inserted i
        INNER JOIN deleted d ON i.FGInventoryID = d.FGInventoryID
        WHERE i.ReservedQuantity <> d.ReservedQuantity;
    END
END;
GO

-- ============================================================================
-- SECTION 8: AUTOMATED UAT TEST CASES (TC-01 TO TC-10)
-- ============================================================================

-- Test 1: Inbound Stock Replenishment
UPDATE FinishedGoodsInventory
SET QuantityOnHand = QuantityOnHand + 150,
    LastUpdated = CAST(GETDATE() AS DATE)
WHERE FGInventoryID = 1;

-- Test 2: Outbound Stock Allocation
UPDATE FinishedGoodsInventory
SET ReservedQuantity = ReservedQuantity + 25,
    LastUpdated = CAST(GETDATE() AS DATE)
WHERE FGInventoryID = 1;

-- Test 3: Constraint Boundary Test (Negative Stock Blocked by Check Constraint)
BEGIN TRY
    UPDATE FinishedGoodsInventory SET QuantityOnHand = -50 WHERE FGInventoryID = 1;
    PRINT 'TC-INV-03 FAILED: Negative quantity was allowed.';
END TRY
BEGIN CATCH
    PRINT 'TC-INV-03 PASSED: Negative stock rejected by check constraint.';
END CATCH;

-- Test 4: Constraint Boundary Test (Over-Reservation Blocked by Check Constraint)
BEGIN TRY
    UPDATE FinishedGoodsInventory SET ReservedQuantity = QuantityOnHand + 500 WHERE FGInventoryID = 1;
    PRINT 'TC-INV-04 FAILED: Over-reservation was allowed.';
END TRY
BEGIN CATCH
    PRINT 'TC-INV-04 PASSED: Over-reservation rejected by check constraint.';
END CATCH;

-- Test 5: Master Data Guard (Hard Delete Blocked by Foreign Key)
BEGIN TRY
    DELETE FROM Products WHERE ProductID = 1;
    PRINT 'TC-SD-01 FAILED: Hard delete succeeded unexpectedly.';
END TRY
BEGIN CATCH
    PRINT 'TC-SD-01 PASSED: Hard delete blocked by Foreign Key reference.';
END CATCH;

-- Test 6: Soft Delete Execution
UPDATE Products SET IsActive = 0 WHERE ProductID = 1;

-- Test 7: Status Transitions (PO & SalesOrder)
-- Dynamically ensure statuses match constraints
DECLARE @ValidPOStatus VARCHAR(50) = COALESCE((SELECT TOP 1 Status FROM PurchaseOrders WHERE Status <> 'Pending' AND Status IS NOT NULL), 'Approved');
DECLARE @ValidSOStatus VARCHAR(50) = COALESCE((SELECT TOP 1 Status FROM SalesOrders WHERE Status <> 'Pending' AND Status IS NOT NULL), 'Shipped');

UPDATE PurchaseOrders SET Status = @ValidPOStatus WHERE POID = 1;
UPDATE SalesOrders SET Status = @ValidSOStatus WHERE SalesOrderID = 1;

-- Test 8: PO Details Modification & Automatic Total Rollup
UPDATE PurchaseOrderDetails 
SET QuantityOrdered = QuantityOrdered + 50 
WHERE PODetailID = 1;

-- Test 9: Reset Soft-Delete State
UPDATE Products SET IsActive = 1 WHERE ProductID = 1;
GO

-- ============================================================================
-- SECTION 9: VERIFICATION OUTPUT (PO ROLLUP & AUDIT TRAIL)
-- ============================================================================

-- 1. PO Recalculated Header Total
SELECT POID, PONumber, TotalAmount, Status 
FROM PurchaseOrders 
WHERE POID = 1;

-- 2. Audit Trail Proof (NX-26 Evidence)
SELECT TOP 15 
    LogID,
    TableName,
    OperationType,
    RecordID,
    ColumnName,
    OldValue,
    NewValue,
    ChangedBy,
    ChangedAt
FROM AuditLog
ORDER BY LogID DESC;
GO