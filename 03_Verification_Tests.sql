USE MSN_TexWeave_DB;
GO

-- ============================================================================
-- NX-26 VERIFICATION SCRIPT
-- Purpose: Test each trigger's INSERT/UPDATE/DELETE audit behavior and
--          confirm before/after values are captured correctly in AuditLog.
-- ============================================================================


-- ============================================================================
-- 1. PurchaseOrders  (trg_PurchaseOrders_Audit)
-- Tracks: Status, IsActive, hard DELETE
-- ============================================================================

-- Dynamically fetch an alternate valid status to guarantee constraint compliance
DECLARE @OrigPOStatus VARCHAR(50) = (SELECT Status FROM PurchaseOrders WHERE POID = 1);
DECLARE @ValidPOStatus VARCHAR(50) = (
    SELECT TOP 1 Status 
    FROM PurchaseOrders 
    WHERE Status <> @OrigPOStatus AND Status IS NOT NULL
);
SET @ValidPOStatus = COALESCE(@ValidPOStatus, 'Approved');

-- TEST 1a: Status update
UPDATE PurchaseOrders SET Status = @ValidPOStatus WHERE POID = 1;

-- VERIFY 1a
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'PurchaseOrders' AND ColumnName = 'Status'
ORDER BY LogID DESC;

-- TEST 1b: Soft delete (IsActive)
UPDATE PurchaseOrders SET IsActive = 0 WHERE POID = 1;

-- VERIFY 1b
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'PurchaseOrders' AND ColumnName = 'IsActive'
ORDER BY LogID DESC;

-- Reset for repeatability
UPDATE PurchaseOrders SET IsActive = 1, Status = @OrigPOStatus WHERE POID = 1;
GO


-- ============================================================================
-- 2. PurchaseOrderDetails  (trg_PurchaseOrderDetails_AuditAndRollup)
-- Tracks: INSERT (QuantityOrdered), UPDATE (QuantityOrdered, ReceivedQuantity,
--         UnitPrice), and auto-rollup into PurchaseOrders.TotalAmount
-- ============================================================================

-- Step A: Insert a test line item
INSERT INTO PurchaseOrderDetails (POID, MaterialID, QuantityOrdered, UnitPrice, ReceivedQuantity)
VALUES (1, 1, 10, 100.00, 0);

-- Capture the generated ID safely for this entire test batch
DECLARE @TestDetailID INT = SCOPE_IDENTITY();

-- VERIFY 2a: Check Insert Log
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'PurchaseOrderDetails' AND OperationType = 'INSERT' AND RecordID = @TestDetailID
ORDER BY LogID DESC;

-- Step B: Update QuantityOrdered
UPDATE PurchaseOrderDetails SET QuantityOrdered = 25 WHERE PODetailID = @TestDetailID;

-- VERIFY 2b: Check Quantity Update Log
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'PurchaseOrderDetails' AND ColumnName = 'QuantityOrdered' AND RecordID = @TestDetailID
ORDER BY LogID DESC;

-- Step C: Update UnitPrice
UPDATE PurchaseOrderDetails SET UnitPrice = 150.00 WHERE PODetailID = @TestDetailID;

-- VERIFY 2c: Check Price Update Log
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'PurchaseOrderDetails' AND ColumnName = 'UnitPrice' AND RecordID = @TestDetailID
ORDER BY LogID DESC;

-- Step D: Update ReceivedQuantity
UPDATE PurchaseOrderDetails SET ReceivedQuantity = 5 WHERE PODetailID = @TestDetailID;

-- VERIFY 2d: Check Received Quantity Log
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'PurchaseOrderDetails' AND ColumnName = 'ReceivedQuantity' AND RecordID = @TestDetailID
ORDER BY LogID DESC;

-- VERIFY 2e: Confirm Header Rollup recalculated properly
SELECT POID, PONumber, TotalAmount
FROM PurchaseOrders
WHERE POID = 1;

-- Step E: Clean up the test row (Rollup trigger will automatically deduct it)
DELETE FROM PurchaseOrderDetails WHERE PODetailID = @TestDetailID;

-- Confirm Header Rollup re-adjusted after deletion
SELECT POID, PONumber, TotalAmount AS FinalCleanTotal
FROM PurchaseOrders
WHERE POID = 1;
GO


-- ============================================================================
-- 3. ProductionOrders  (trg_ProductionOrders_Complete_Audit)
-- Tracks: Status 
-- ============================================================================

-- Dynamically pick a different existing valid status from your DB to trigger an UPDATE
DECLARE @CurrentProdStatus VARCHAR(50) = (SELECT Status FROM ProductionOrders WHERE ProductionOrderID = 1);
DECLARE @NewValidProdStatus VARCHAR(50) = (
    SELECT TOP 1 Status 
    FROM ProductionOrders 
    WHERE Status <> @CurrentProdStatus AND Status IS NOT NULL
);
SET @NewValidProdStatus = COALESCE(@NewValidProdStatus, 'Completed');

-- TEST 3: Status update
UPDATE ProductionOrders SET Status = @NewValidProdStatus WHERE ProductionOrderID = 1;

-- VERIFY 3
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'ProductionOrders' AND ColumnName = 'Status'
ORDER BY LogID DESC;

-- Reset back to original status
UPDATE ProductionOrders SET Status = @CurrentProdStatus WHERE ProductionOrderID = 1;
GO


-- ============================================================================
-- 4. QualityChecks  (trg_QualityChecks_Audit) 
-- Tracks: INSERT / UPDATE (generic record marker)
-- ============================================================================

-- Dynamically pick a valid CheckResult value that already exists in your table
DECLARE @ValidQCResult VARCHAR(50) = COALESCE((SELECT TOP 1 CheckResult FROM QualityChecks WHERE CheckResult IS NOT NULL), 'Passed');

-- TEST 4: Insert a new quality check using known valid result
INSERT INTO QualityChecks (ProductionOrderID, StageID, InspectedQuantity, DefectQuantity, CheckResult, InspectedBy, Comments)
VALUES (1, 1, 100, 2, @ValidQCResult, 1, 'UAT test record for NX-22 trigger verification');

DECLARE @TestCheckID INT = SCOPE_IDENTITY();

-- VERIFY 4
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'QualityChecks' AND RecordID = @TestCheckID
ORDER BY LogID DESC;

-- CLEANUP test row
DELETE FROM QualityChecks WHERE CheckID = @TestCheckID;
GO


-- ============================================================================
-- 5. SalesOrders  (trg_SalesOrders_Audit)
-- Tracks: Status only
-- ============================================================================

-- Dynamically fetch an alternate valid status to guarantee constraint compliance
DECLARE @OrigSOStatus VARCHAR(50) = (SELECT Status FROM SalesOrders WHERE SalesOrderID = 1);
DECLARE @ValidSOStatus VARCHAR(50) = (
    SELECT TOP 1 Status 
    FROM SalesOrders 
    WHERE Status <> @OrigSOStatus AND Status IS NOT NULL
);
SET @ValidSOStatus = COALESCE(@ValidSOStatus, 'Shipped');

-- TEST 5: Status update
UPDATE SalesOrders SET Status = @ValidSOStatus WHERE SalesOrderID = 1;

-- VERIFY 5
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'SalesOrders' AND ColumnName = 'Status'
ORDER BY LogID DESC;

-- Reset back to original status
UPDATE SalesOrders SET Status = @OrigSOStatus WHERE SalesOrderID = 1;
GO


-- ============================================================================
-- 6. Shipments  (trg_Shipments_Audit) 
-- Tracks: INSERT / UPDATE (generic record marker)
-- ============================================================================

-- Dynamically fetch a valid status that already exists in Shipments
DECLARE @ValidShipmentStatus VARCHAR(50) = COALESCE((SELECT TOP 1 ShipmentStatus FROM Shipments WHERE ShipmentStatus IS NOT NULL), 'Shipped');

-- TEST 6: Insert a new shipment
INSERT INTO Shipments (
    SalesOrderID, 
    CarrierID, 
    TrackingNumber, 
    ContainerNumber, 
    PortOfOrigin, 
    PortOfDestination, 
    DispatchDate, 
    ExpectedDeliveryDate, 
    ShipmentStatus
)
VALUES (
    1, 
    1, 
    'TEST-TRACK-001', 
    'TEST-CONT-001', 
    'Karachi', 
    'Rotterdam', 
    CAST(GETDATE() AS DATE), 
    DATEADD(DAY, 14, CAST(GETDATE() AS DATE)), 
    @ValidShipmentStatus
);

DECLARE @TestShipmentID INT = SCOPE_IDENTITY();

-- VERIFY 6
SELECT TOP 1 * FROM AuditLog
WHERE TableName = 'Shipments' AND RecordID = @TestShipmentID
ORDER BY LogID DESC;

-- CLEANUP test row
DELETE FROM Shipments WHERE ShipmentID = @TestShipmentID;
GO


-- ============================================================================
-- 7. Products  (trg_Products_Audit)
-- Tracks: IsActive (soft delete)
-- ============================================================================

-- TEST 7a: Soft delete a product
UPDATE Products SET IsActive = 0 WHERE ProductID = 1;

-- VERIFY 7a
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'Products' AND ColumnName = 'IsActive'
ORDER BY LogID DESC;

-- Reset for repeatability
UPDATE Products SET IsActive = 1 WHERE ProductID = 1;
GO


-- ============================================================================
-- 8. FinishedGoodsInventory  (trg_FGInventory_Audit)
-- Tracks: QuantityOnHand, ReservedQuantity
-- ============================================================================

-- TEST 8a: Stock replenishment
UPDATE FinishedGoodsInventory 
SET QuantityOnHand = QuantityOnHand + 150,
    LastUpdated = CAST(GETDATE() AS DATE)
WHERE FGInventoryID = 1;

-- VERIFY 8a
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'FinishedGoodsInventory' AND ColumnName = 'QuantityOnHand'
ORDER BY LogID DESC;

-- TEST 8b: Stock allocation (reservation)
UPDATE FinishedGoodsInventory 
SET ReservedQuantity = ReservedQuantity + 25,
    LastUpdated = CAST(GETDATE() AS DATE)
WHERE FGInventoryID = 1;

-- VERIFY 8b
SELECT TOP 5 * FROM AuditLog
WHERE TableName = 'FinishedGoodsInventory' AND ColumnName = 'ReservedQuantity'
ORDER BY LogID DESC;
GO


-- ============================================================================
-- 9. AGGREGATE SANITY CHECKS
-- ============================================================================

-- 9a. Entries View
SELECT TableName, OperationType, COUNT(*) AS EntryCount
FROM AuditLog
GROUP BY TableName, OperationType
ORDER BY TableName, OperationType;

-- 9b. No NULL RecordID 
SELECT * FROM AuditLog WHERE RecordID IS NULL;

-- 9c. No numeric values leaking into OperationType 
SELECT * FROM AuditLog WHERE OperationType NOT IN ('INSERT', 'UPDATE', 'DELETE');

-- 9d. ChangedBy should never be blank
SELECT * FROM AuditLog WHERE ChangedBy IS NULL OR ChangedBy = '';

-- 9e. Most recent 30 entries overall, for a final visual scan
SELECT TOP 30 * FROM AuditLog ORDER BY LogID DESC;
GO