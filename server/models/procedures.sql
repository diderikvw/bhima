/*
  This file contains all the stored procedures used in bhima's database.  It
  should be loaded after functions.sql.
*/

DELIMITER $$

CREATE PROCEDURE StageInvoice(
  IN date DATETIME,
  IN cost DECIMAL(19, 4) UNSIGNED,
  IN description TEXT,
  IN service_id SMALLINT(5) UNSIGNED,
  IN debtor_uuid BINARY(16),
  IN project_id SMALLINT(5),
  IN user_id SMALLINT(5),
  IN uuid BINARY(16)
)
BEGIN
  -- verify if invoice stage already exists within this connection, if the
  -- stage already exists simply write to it, otherwise create it select into it
  DECLARE `no_invoice_stage` TINYINT(1) DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLSTATE '42S02' SET `no_invoice_stage` = 1;
  SELECT NULL FROM `stage_invoice` LIMIT 0;

  IF (`no_invoice_stage` = 1) THEN
    CREATE TEMPORARY TABLE stage_invoice
    (SELECT project_id, uuid, cost, debtor_uuid, service_id, user_id, date, description);
  ELSE
    INSERT INTO stage_invoice
    (SELECT project_id, uuid, cost, debtor_uuid, service_id, user_id, date, description);
  END IF;
END $$

CREATE PROCEDURE StageInvoiceItem(
  IN uuid BINARY(16),
  IN inventory_uuid BINARY(16),
  IN quantity INT(10) UNSIGNED,
  IN transaction_price decimal(19, 4),
  IN inventory_price decimal(19, 4),
  IN debit decimal(19, 4),
  IN credit decimal(19, 4),
  IN invoice_uuid BINARY(16)
)
BEGIN
  -- verify if invoice item stage already exists within this connection, if the
  -- stage already exists simply write to it, otherwise create it select into it
  DECLARE `no_invoice_item_stage` TINYINT(1) DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLSTATE '42S02' SET `no_invoice_item_stage` = 1;
  SELECT NULL FROM `stage_invoice_item` LIMIT 0;

  IF (`no_invoice_item_stage` = 1) THEN
    -- tables does not exist - create and enter data
    CREATE TEMPORARY TABLE stage_invoice_item
      (select uuid, inventory_uuid, quantity, transaction_price, inventory_price, debit, credit, invoice_uuid);
  ELSE
    -- table exists - only enter data
    INSERT INTO stage_invoice_item
      (SELECT uuid, inventory_uuid, quantity, transaction_price, inventory_price, debit, credit, invoice_uuid);
  END IF;
END $$


CREATE PROCEDURE StageBillingService(
  IN id SMALLINT UNSIGNED,
  IN invoice_uuid BINARY(16)
)
BEGIN
  CALL VerifyBillingServiceStageTable();

   INSERT INTO stage_billing_service
  (SELECT id, invoice_uuid);
END $$

CREATE PROCEDURE StageSubsidy(
  IN id SMALLINT UNSIGNED,
  IN invoice_uuid BINARY(16)
)
BEGIN
  CALL VerifySubsidyStageTable();

  INSERT INTO stage_subsidy
  (SELECT id, invoice_uuid);
END $$

-- create a temporary staging table for the subsidies, this is done via a helper
-- method to ensure it has been created as sale writing time (subsidies are an
-- optional entity that may or may not have been called for staging)
CREATE PROCEDURE VerifySubsidyStageTable()
BEGIN
  CREATE TEMPORARY TABLE IF NOT EXISTS stage_subsidy (id INTEGER, invoice_uuid BINARY(16));
END $$

CREATE PROCEDURE VerifyBillingServiceStageTable()
BEGIN
  CREATE TEMPORARY TABLE IF NOT EXISTS stage_billing_service (id INTEGER, invoice_uuid BINARY(16));
END $$

CREATE PROCEDURE WriteInvoice(
  IN uuid BINARY(16)
)
BEGIN
  -- running calculation variables
  DECLARE items_cost decimal(19, 4);
  DECLARE billing_services_cost decimal(19, 4);
  DECLARE total_cost_to_debtor decimal(19, 4);
  DECLARE total_subsidy_cost decimal(19, 4);
  DECLARE total_subsidised_cost decimal(19, 4);

  -- ensure that all optional entities have staging tables available, it is
  -- possible that the invoice has not invoked methods to stage subsidies and
  -- billing services if they are not relevant - this makes sure the tables exist
  -- for queries within this method
  CALL VerifySubsidyStageTable();
  CALL VerifyBillingServiceStageTable();

  -- invoice details
  INSERT INTO invoice (project_id, uuid, cost, debtor_uuid, service_id, user_id, date, description)
  SELECT * FROM stage_invoice WHERE stage_invoice.uuid = uuid;

  -- invoice item details
  INSERT INTO invoice_item (uuid, inventory_uuid, quantity, transaction_price, inventory_price, debit, credit, invoice_uuid)
  SELECT * from stage_invoice_item WHERE stage_invoice_item.invoice_uuid = uuid;

  -- Total cost of all invoice items
  SET items_cost = (SELECT SUM(credit) as cost FROM invoice_item where invoice_uuid = uuid);

  -- calculate billing services based on total item cost
  INSERT INTO invoice_billing_service (invoice_uuid, value, billing_service_id)
  SELECT uuid, (billing_service.value / 100) * items_cost, billing_service.id
  FROM billing_service WHERE id in (SELECT id FROM stage_billing_service where invoice_uuid = uuid);

  -- total cost of all invoice items and billing services
  SET billing_services_cost = (SELECT IFNULL(SUM(value), 0) AS value from invoice_billing_service WHERE invoice_uuid = uuid);
  SET total_cost_to_debtor = items_cost + billing_services_cost;

  -- calculate subsidy cost based on total cost to debtor
  INSERT INTO invoice_subsidy (invoice_uuid, value, subsidy_id)
  SELECT uuid, (subsidy.value / 100) * total_cost_to_debtor, subsidy.id
  FROM subsidy WHERE id in (SELECT id FROM stage_subsidy where invoice_uuid = uuid);

  -- calculate final value debtor must pay based on subsidised costs
  SET total_subsidy_cost = (SELECT IFNULL(SUM(value), 0) AS value from invoice_subsidy WHERE invoice_uuid = uuid);
  SET total_subsidised_cost = total_cost_to_debtor - total_subsidy_cost;

  -- update relevant fields to represent final costs
  UPDATE invoice SET cost = total_subsidised_cost
  WHERE invoice.uuid = uuid;

  -- return information relevant to the final calculated and written bill
  SELECT items_cost, billing_services_cost, total_cost_to_debtor, total_subsidy_cost, total_subsidised_cost;
END $$

CREATE PROCEDURE PostInvoice(
  IN uuid binary(16)
)
BEGIN
  DECLARE InvalidSalesAccounts CONDITION FOR SQLSTATE '45006';

  -- required posting values
  DECLARE date DATETIME;
  DECLARE enterprise_id SMALLINT(5);
  DECLARE project_id SMALLINT(5);
  DECLARE currency_id TINYINT(3) UNSIGNED;

  -- variables to store core set-up results
  DECLARE current_fiscal_year_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_period_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_exchange_rate DECIMAL(19, 4) UNSIGNED;
  DECLARE enterprise_currency_id TINYINT(3) UNSIGNED;
  DECLARE transaction_id VARCHAR(100);
  DECLARE gain_account_id INT UNSIGNED;
  DECLARE loss_account_id INT UNSIGNED;

  DECLARE verify_invalid_accounts SMALLINT(5);

  -- populate initial values specifically for this invoice
  SELECT invoice.date, enterprise.id, project.id, enterprise.currency_id
    INTO date, enterprise_id, project_id, currency_id
  FROM invoice join project join enterprise on invoice.project_id = project.id AND project.enterprise_id = enterprise.id
  WHERE invoice.uuid = uuid;

  -- populate core set-up values
  CALL PostingSetupUtil(date, enterprise_id, project_id, currency_id, current_fiscal_year_id, current_period_id, current_exchange_rate, enterprise_currency_id, transaction_id, gain_account_id, loss_account_id);

  -- Check that all invoice items have sales accounts - if they do not the transaction will be imbalanced
  SELECT COUNT(invoice_item.uuid)
    INTO verify_invalid_accounts
  FROM invoice JOIN invoice_item JOIN inventory JOIN inventory_group
  ON invoice.uuid = invoice_item.invoice_uuid
    AND invoice_item.inventory_uuid = inventory.uuid
    AND inventory.group_uuid = inventory_group.uuid
  WHERE invoice.uuid = uuid
  AND inventory_group.sales_account IS NULL;

  IF verify_invalid_accounts > 0 THEN
    SIGNAL InvalidSalesAccounts
    SET MESSAGE_TEXT = 'A NULL sales account has been found for an inventory item in this invoice.';
  END IF;

  CALL CopyInvoiceToPostingJournal(uuid, transaction_id, project_id, current_fiscal_year_id, current_period_id, currency_id);
END $$


CREATE PROCEDURE PostingSetupUtil(
  IN date DATETIME,
  IN enterprise_id SMALLINT(5),
  IN project_id SMALLINT(5),
  IN currency_id TINYINT(3) UNSIGNED,
  OUT current_fiscal_year_id MEDIUMINT(8) UNSIGNED,
  OUT current_period_id MEDIUMINT(8) UNSIGNED,
  OUT current_exchange_rate DECIMAL(19, 4) UNSIGNED,
  OUT enterprise_currency_id TINYINT(3) UNSIGNED,
  OUT transaction_id VARCHAR(100),
  OUT gain_account INT UNSIGNED,
  OUT loss_account INT UNSIGNED
)
BEGIN
  SET current_fiscal_year_id = (
    SELECT id FROM fiscal_year AS fy
    WHERE date BETWEEN fy.start_date AND DATE(ADDDATE(fy.start_date, INTERVAL fy.number_of_months MONTH)) AND fy.enterprise_id = enterprise_id
  );

  SET current_period_id = (
    SELECT id FROM period AS p
    WHERE DATE(date) BETWEEN DATE(p.start_date) AND DATE(p.end_date) AND p.fiscal_year_id = current_fiscal_year_id
  );

  SELECT e.gain_account_id, e.loss_account_id, e.currency_id
    INTO gain_account, loss_account, enterprise_currency_id
  FROM enterprise AS e WHERE e.id = enterprise_id;

  -- this uses the currency id passed in as a dependency
  SET current_exchange_rate = GetExchangeRate(enterprise_id, currency_id, date);
  SET current_exchange_rate = (SELECT IF(currency_id = enterprise_currency_id, 1, current_exchange_rate));

  SET transaction_id = GenerateTransactionId(project_id);

  -- error handling
  CALL PostingJournalErrorHandler(enterprise_id, project_id, current_fiscal_year_id, current_period_id, current_exchange_rate, date);
END $$

-- detects MySQL Posting Journal Errors
CREATE PROCEDURE PostingJournalErrorHandler(
  enterprise INT,
  project INT,
  fiscal INT,
  period INT,
  exchange DECIMAL,
  date DATETIME
)
BEGIN

  -- set up error declarations
  DECLARE NoEnterprise CONDITION FOR SQLSTATE '45001';
  DECLARE NoProject CONDITION FOR SQLSTATE '45002';
  DECLARE NoFiscalYear CONDITION FOR SQLSTATE '45003';
  DECLARE NoPeriod CONDITION FOR SQLSTATE '45004';
  DECLARE NoExchangeRate CONDITION FOR SQLSTATE '45005';

  IF enterprise IS NULL THEN
    SIGNAL NoEnterprise
      SET MESSAGE_TEXT = 'No enterprise found in the database.';
  END IF;

  IF project IS NULL THEN
    SIGNAL NoProject
      SET MESSAGE_TEXT = 'No project provided for that record.';
  END IF;

  IF fiscal IS NULL THEN
    SET @text = CONCAT('No fiscal year found for the provided date: ', CAST(date AS char));
    SIGNAL NoFiscalYear
      SET MESSAGE_TEXT = @text;
  END IF;

  IF period IS NULL THEN
    SET @text = CONCAT('No period found for the provided date: ', CAST(date AS char));
    SIGNAL NoPeriod
      SET MESSAGE_TEXT = @text;
  END IF;

  IF exchange IS NULL THEN
    SET @text = CONCAT('No exchange rate found for the provided date: ', CAST(date AS char));
    SIGNAL NoExchangeRate
      SET MESSAGE_TEXT = @text;
  END IF;
END
$$

-- Credit For Cautions
CREATE PROCEDURE CopyInvoiceToPostingJournal(
  iuuid BINARY(16),  -- the UUID of the patient invoice
  transId TEXT,
  projectId INT,
  fiscalYearId INT,
  periodId INT,
  currencyId INT
)
BEGIN
  -- local variables
  DECLARE done INT DEFAULT FALSE;

  -- invoice variables
  DECLARE idate DATETIME;
  DECLARE icost DECIMAL(19,4);
  DECLARE ientityId BINARY(16);
  DECLARE iuserId INT;
  DECLARE idescription TEXT;
  DECLARE iaccountId INT;

  -- caution variables
  DECLARE cid BINARY(16);
  DECLARE cbalance DECIMAL(19,4);
  DECLARE cdate DATETIME;
  DECLARE cdescription TEXT;

 -- cursor for debtor's cautions
  DECLARE curse CURSOR FOR
    SELECT c.id, c.date, c.description, SUM(c.credit - c.debit) AS balance FROM (

        -- get the record_uuids in the posting journal
        SELECT debit_equiv as debit, credit_equiv as credit, posting_journal.trans_date as date, posting_journal.description, record_uuid AS id
        FROM posting_journal JOIN cash
          ON cash.uuid = posting_journal.record_uuid
        WHERE reference_uuid IS NULL AND entity_uuid = ientityId AND cash.is_caution = 0

      UNION ALL

        -- get the record_uuids in the general ledger
        SELECT debit_equiv as debit, credit_equiv as credit, general_ledger.trans_date as date, general_ledger.description, record_uuid AS id
        FROM general_ledger JOIN cash
          ON cash.uuid = general_ledger.record_uuid
        WHERE reference_uuid IS NULL AND entity_uuid = ientityId AND cash.is_caution = 0

      UNION ALL

        -- get the reference_uuids in the posting_journal
        SELECT debit_equiv as debit, credit_equiv as credit, posting_journal.trans_date as date, posting_journal.description, reference_uuid AS id
        FROM posting_journal JOIN cash
          ON cash.uuid = posting_journal.reference_uuid
        WHERE entity_uuid = ientityId AND cash.is_caution = 0

      UNION ALL

        -- get the reference_uuids in the general_ledger
        SELECT debit_equiv as debit, credit_equiv as credit, general_ledger.trans_date as date, general_ledger.description, reference_uuid AS id
        FROM general_ledger JOIN cash
          ON cash.uuid = general_ledger.reference_uuid
        WHERE entity_uuid = ientityId AND cash.is_caution = 0
    ) AS c
    GROUP BY c.id
    HAVING balance > 0
    ORDER BY c.date;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  -- set the invoice variables
  SELECT cost, debtor_uuid, date, user_id, description
    INTO icost, ientityId, idate, iuserId, idescription
  FROM invoice WHERE invoice.uuid = iuuid;

  -- set the transaction variables (account)
  SELECT account_id INTO iaccountId
  FROM debtor JOIN debtor_group
   ON debtor.group_uuid = debtor_group.uuid
  WHERE debtor.uuid = ientityId;

  -- open the cursor
  OPEN curse;

  -- create a prepared statement for efficiently writing to the posting_journal
  -- from within the caution LOOP

  -- loop through the cursor of caution payments and allocate payments against
  -- the current invoice to the caution by setting reference_uuid to the
  -- caution's record_uuid.
  cautionLoop: LOOP
    FETCH curse INTO cid, cdate, cdescription, cbalance;

    IF done THEN
      LEAVE cautionLoop;
    END IF;

    -- check: if the caution is more than the cost, assign the total cost of the
    -- invoice to the caution and exit the loop.
    IF cbalance >= scost THEN

      -- write the cost value from into the posting journal
      INSERT INTO posting_journal
          (uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
          record_uuid, description, account_id, debit, credit, debit_equiv,
          credit_equiv, currency_id, entity_uuid, reference_uuid,
          user_id, origin_id)
        VALUES (
          HUID(UUID()), projectId, fiscalYearId, periodId, transId, idate, iuuid, cdescription,
          iaccountId, icost, 0, icost, 0, currencyId, ientityId, cid, iuserId, 11
        );

      -- exit the loop
      SET done = TRUE;

    -- else: the caution is less than the cost, assign the total caution cost to
    -- the caution (making it 0), and continue
    ELSE

      -- if there is no more caution balance escape
      IF cbalance = 0 THEN
        SET done = TRUE;
      ELSE
        -- subtract the caution's balance from the cost
        SET icost = icost - cbalance;

        INSERT INTO posting_journal (
          uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
          record_uuid, description, account_id, debit, credit, debit_equiv,
          credit_equiv, currency_id, entity_uuid, reference_uuid,
          user_id, origin_id
        ) VALUES (
          HUID(UUID()), projectId, fiscalYearId, periodId, transId, idate,
          iuuid, cdescription, iaccountId, cbalance, 0, cbalance, 0,
          currencyId, ientityId, cid, iuserId, 11
        );

      END IF;
    END IF;
  END LOOP;

  -- close the cursor
  CLOSE curse;

  -- if there is remainder cost, bill the debtor the full amount
  IF icost > 0 THEN
    INSERT INTO posting_journal (
      uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
      record_uuid, description, account_id, debit, credit, debit_equiv,
      credit_equiv, currency_id, entity_uuid, user_id, origin_id
    ) VALUES (
      HUID(UUID()), projectId, fiscalYearId, periodId, transId, idate,
      iuuid, idescription, iaccountId, icost, 0, icost, 0,
      currencyId, ientityId, iuserId, 11
    );
  END IF;

  -- copy the invoice_items into the posting_journal
  INSERT INTO posting_journal (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  )
   SELECT
    HUID(UUID()), i.project_id, fiscalYearId, periodId, transId, i.date, i.uuid,
    CONCAT(dm.text,': ', inv.text) as txt, ig.sales_account, ii.debit, ii.credit, ii.debit, ii.credit,
    currencyId, 11, i.user_id
  FROM invoice AS i JOIN invoice_item AS ii JOIN inventory as inv JOIN inventory_group AS ig JOIN document_map as dm ON
    i.uuid = ii.invoice_uuid AND
    ii.inventory_uuid = inv.uuid AND
    inv.group_uuid = ig.uuid AND
    dm.uuid = i.uuid
  WHERE i.uuid = iuuid;

  -- copy the invoice_subsidy records into the posting_journal (debits)
  INSERT INTO posting_journal (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  ) SELECT
    HUID(UUID()), i.project_id, fiscalYearId, periodId, transId, i.date, i.uuid,
    i.description, su.account_id, isu.value, 0, isu.value, 0, currencyId, 11,
    i.user_id
  FROM invoice AS i JOIN invoice_subsidy AS isu JOIN subsidy AS su ON
    i.uuid = isu.invoice_uuid AND
    isu.subsidy_id = su.id
  WHERE i.uuid = iuuid;

  -- copy the invoice_billing_service records into the posting_journal (credits)
  INSERT INTO posting_journal (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  ) SELECT
    HUID(UUID()), i.project_id, fiscalYearId, periodId, transId, i.date, i.uuid,
    i.description, b.account_id, 0, ib.value, 0, ib.value, currencyId, 11,
    i.user_id
  FROM invoice AS i JOIN invoice_billing_service AS ib JOIN billing_service AS b ON
    i.uuid = ib.invoice_uuid AND
    ib.billing_service_id = b.id
  WHERE i.uuid = iuuid;
END
$$

CREATE PROCEDURE PostToGeneralLedger(
  IN transactions TEXT
) BEGIN

  CREATE TEMPORARY TABLE IF NOT EXISTS stage_journal_transaction (record_uuid BINARY(16));

  SET @sql = CONCAT(
   "INSERT INTO stage_journal_transaction SELECT DISTINCT record_uuid FROM posting_journal WHERE trans_id IN (", transactions, ");"
  );

  PREPARE stmt FROM @sql;
  EXECUTE stmt;

  DEALLOCATE PREPARE stmt;

  -- write into the posting journal
  INSERT INTO general_ledger (
    project_id, uuid, fiscal_year_id, period_id, trans_id, trans_date, record_uuid,
    description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id,
    entity_uuid, reference_uuid, comment, origin_id, user_id, cc_id, pc_id
  ) SELECT project_id, uuid, fiscal_year_id, period_id, trans_id, trans_date, record_uuid,
    description, account_id, debit, credit, debit_equiv, credit_equiv, currency_id,
    entity_uuid, reference_uuid, comment, origin_id, user_id, cc_id, pc_id
  FROM posting_journal
  WHERE posting_journal.record_uuid IN (SELECT record_uuid FROM stage_journal_transaction);

  -- write into period_total
  INSERT INTO period_total (
    account_id, credit, debit, fiscal_year_id, enterprise_id, period_id
  )
  SELECT account_id, SUM(credit_equiv) AS credit, SUM(debit_equiv) as debit,
    fiscal_year_id, project.enterprise_id, period_id
  FROM posting_journal JOIN project
    ON posting_journal.project_id = project.id
  WHERE posting_journal.record_uuid IN (SELECT record_uuid FROM stage_journal_transaction)
  GROUP BY period_id, account_id
  ON DUPLICATE KEY UPDATE credit = credit + VALUES(credit), debit = debit + VALUES(debit);

  -- remove from posting journal
  DELETE FROM posting_journal WHERE record_uuid IN (SELECT record_uuid FROM stage_journal_transaction);
END $$

/*
 Create Fiscal Year and Periods

 This procedure help to create fiscal year and fiscal year's periods
 periods include period `0` and period `13`
*/
DELIMITER $$

CREATE PROCEDURE CreateFiscalYear(
  IN p_enterprise_id SMALLINT(5),
  IN p_previous_fiscal_year_id MEDIUMINT(8),
  IN p_user_id SMALLINT(5),
  IN p_label VARCHAR(50),
  IN p_number_of_months MEDIUMINT(8),
  IN p_start_date DATE,
  IN p_end_date DATE,
  IN p_note TEXT,
  OUT fiscalYearId MEDIUMINT(8)
)
BEGIN
  INSERT INTO fiscal_year (
    `enterprise_id`, `previous_fiscal_year_id`, `user_id`, `label`,
    `number_of_months`, `start_date`, `end_date`, `note`
  ) VALUES (
    p_enterprise_id, p_previous_fiscal_year_id, p_user_id, p_label,
    p_number_of_months, p_start_date, p_end_date, p_note
  );

  SET fiscalYearId = LAST_INSERT_ID();
  CALL CreatePeriods(fiscalYearId);
END $$

CREATE PROCEDURE GetPeriodRange(
  IN fiscalYearStartDate DATE,
  IN periodNumberIndex SMALLINT(5),
  OUT periodStartDate DATE,
  OUT periodEndDate DATE
)
BEGIN
  DECLARE `innerDate` DATE;

  SET innerDate = (SELECT DATE_ADD(fiscalYearStartDate, INTERVAL periodNumberIndex-1 MONTH));
  SET periodStartDate = (SELECT CAST(DATE_FORMAT(innerDate ,'%Y-%m-01') as DATE));
  SET periodEndDate = (SELECT LAST_DAY(innerDate));
END $$

CREATE PROCEDURE CreatePeriods(
  IN fiscalYearId MEDIUMINT(8)
)
BEGIN
  DECLARE periodId MEDIUMINT(8);
  DECLARE periodNumber SMALLINT(5) DEFAULT 0;
  DECLARE periodStartDate DATE;
  DECLARE periodEndDate DATE;
  DECLARE periodLocked TINYINT(1);

  DECLARE fyEnterpriseId SMALLINT(5);
  DECLARE fyNumberOfMonths MEDIUMINT(8) DEFAULT 0;
  DECLARE fyLabel VARCHAR(50);
  DECLARE fyStartDate DATE;
  DECLARE fyEndDate DATE;
  DECLARE fyPreviousFYId SMALLINT(5);
  DECLARE fyLocked TINYINT(1);
  DECLARE fyCreatedAt TIMESTAMP;
  DECLARE fyUpdatedAt TIMESTAMP;
  DECLARE fyUserId MEDIUMINT(5);
  DECLARE fyNote TEXT;


  -- get the fiscal year informations
  SELECT
    enterprise_id, number_of_months, label, start_date, end_date,
    previous_fiscal_year_id, locked, created_at, updated_at, user_id, note
    INTO
    fyEnterpriseId, fyNumberOfMonths, fyLabel, fyStartDate, fyEndDate,
    fyPreviousFYId, fyLocked, fyCreatedAt, fyUpdatedAt, fyUserId, fyNote
  FROM fiscal_year WHERE id = fiscalYearId;

  -- insert N+2 period
  WHILE periodNumber <= fyNumberOfMonths + 1 DO

    IF periodNumber = 0 OR periodNumber = fyNumberOfMonths + 1 THEN
      -- Extremum periods 0 and N+1
      -- Insert periods with null dates - period id is YYYY00
      INSERT INTO period (`id`, `fiscal_year_id`, `number`, `start_date`, `end_date`, `locked`)
      VALUES (CONCAT(YEAR(fyStartDate), periodNumber), fiscalYearId, periodNumber, NULL, NULL, 0);
    ELSE
      -- Normal periods
      -- Get period dates range
      CALL GetPeriodRange(fyStartDate, periodNumber, periodStartDate, periodEndDate);

      -- Inserting periods -- period id is YYYYMM
      INSERT INTO period(`id`, `fiscal_year_id`, `number`, `start_date`, `end_date`, `locked`)
      VALUES (DATE_FORMAT(periodStartDate, '%Y%m'), fiscalYearId, periodNumber, periodStartDate, periodEndDate, 0);
    END IF;

    SET periodNumber = periodNumber + 1;
  END WHILE;
END $$

CREATE PROCEDURE PostVoucher(
  IN uuid BINARY(16)
)
BEGIN
  DECLARE enterprise_id INT;
  DECLARE project_id INT;
  DECLARE currency_id INT;
  DECLARE date TIMESTAMP;

  -- variables to store core set-up results
  DECLARE fiscal_year_id MEDIUMINT(8) UNSIGNED;
  DECLARE period_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_exchange_rate DECIMAL(19, 4) UNSIGNED;
  DECLARE enterprise_currency_id TINYINT(3) UNSIGNED;
  DECLARE transaction_id VARCHAR(100);
  DECLARE gain_account_id INT UNSIGNED;
  DECLARE loss_account_id INT UNSIGNED;

  --
  SELECT p.enterprise_id, p.id, v.currency_id, v.date
    INTO enterprise_id, project_id, currency_id, date
  FROM voucher AS v JOIN project AS p ON v.project_id = p.id
  WHERE v.uuid = uuid;

  -- populate core setup values
  CALL PostingSetupUtil(date, enterprise_id, project_id, currency_id, fiscal_year_id, period_id, current_exchange_rate, enterprise_currency_id, transaction_id, gain_account_id, loss_account_id);

  -- make sure the exchange rate is correct
  SET current_exchange_rate = GetExchangeRate(enterprise_id, currency_id, date);
  SET current_exchange_rate = (SELECT IF(currency_id = enterprise_currency_id, 1, current_exchange_rate));

  -- POST to the posting journal
  INSERT INTO posting_journal (uuid, project_id, fiscal_year_id, period_id,
    trans_id, trans_date, record_uuid, description, account_id, debit,
    credit, debit_equiv, credit_equiv, currency_id, entity_uuid,
    reference_uuid, comment, origin_id, user_id)
  SELECT
    HUID(UUID()), v.project_id, fiscal_year_id, period_id, transaction_id, v.date,
    v.uuid, v.description, vi.account_id, vi.debit, vi.credit,
    vi.debit * (1 / current_exchange_rate), vi.credit * (1 / current_exchange_rate), v.currency_id,
    vi.entity_uuid, vi.document_uuid, NULL, v.type_id, v.user_id
  FROM voucher AS v JOIN voucher_item AS vi ON v.uuid = vi.voucher_uuid
  WHERE v.uuid = uuid;

  -- NOTE: this does not handle any rounding - it simply converts the currency as needed.
END $$

CREATE PROCEDURE ReverseTransaction(
  IN uuid BINARY(16),
  IN user_id INT,
  IN description TEXT,
  IN voucher_uuid BINARY(16)
)
BEGIN
  -- NOTE: someone should check that the record_uuid is not used as a reference_uuid somewhere
  -- This is done in JS currently, but could be done here.
  DECLARE isInvoice BOOLEAN;
  DECLARE isCashPayment BOOLEAN;
  DECLARE reversalType INT;

  SET reversalType = 10;

  SET isInvoice = (SELECT IFNULL((SELECT 1 FROM invoice WHERE invoice.uuid = uuid), 0));

  -- avoid a scan of the cash table if we already know this is an invoice reversal
  IF NOT isInvoice THEN
    SET isCashPayment = (SELECT IFNULL((SELECT 1 FROM cash WHERE cash.uuid = uuid), 0));
  END IF;

  -- @fixme - why do we have `amount` in the voucher table?
  -- @todo - make only one type of reversal (not cash, credit, or voucher)

  INSERT INTO voucher (uuid, date, project_id, currency_id, amount, description, user_id, type_id, reference_uuid)
    SELECT voucher_uuid, NOW(), zz.project_id, enterprise.currency_id, 0, CONCAT_WS(' ', '(REVERSAL)', description), user_id, reversalType, uuid
    FROM (
      SELECT pj.project_id, pj.description FROM posting_journal AS pj WHERE pj.record_uuid = uuid
      UNION ALL
      SELECT gl.project_id, gl.description FROM general_ledger AS gl WHERE gl.record_uuid = uuid
    ) AS zz
      JOIN project ON zz.project_id = project.id
      JOIN enterprise ON project.enterprise_id = enterprise.id
    LIMIT 1;

  -- NOTE: the debits and credits are swapped on purpose here
  INSERT INTO voucher_item (uuid, account_id, debit, credit, voucher_uuid, document_uuid, entity_uuid)
    SELECT HUID(UUID()), zz.account_id, zz.credit_equiv, zz.debit_equiv, voucher_uuid, zz.reference_uuid, zz.entity_uuid
    FROM (
      SELECT pj.account_id, pj.credit_equiv, pj.debit_equiv, pj.reference_uuid, pj.entity_uuid
      FROM posting_journal AS pj WHERE pj.record_uuid = uuid
      UNION ALL
      SELECT gl.account_id, gl.credit_equiv, gl.debit_equiv, gl.reference_uuid, gl.entity_uuid
      FROM general_ledger AS gl WHERE gl.record_uuid = uuid
    ) AS zz;

  -- make sure we update the invoice with the fact that it got reversed.
  IF isInvoice THEN
    UPDATE invoice SET reversed = 1 WHERE invoice.uuid = uuid;
  END IF;

  -- make sure we update the cash payment that was reversed
  IF isCashPayment THEN
    UPDATE cash SET reversed = 1 WHERE cash.uuid = uuid;
  END IF;

  CALL PostVoucher(voucher_uuid);
END $$


-- this stored procedure merges two locations, deleting the first location_uuid after
-- all locations have been migrated.
CREATE PROCEDURE MergeLocations(
  IN beforeUuid BINARY(16),
  IN afterUuid BINARY(16)
) BEGIN

  -- Go through every location in the database, replacing the location uuid with the new location uuid
  UPDATE patient SET origin_location_id = afterUuid WHERE origin_location_id = beforeUuid;
  UPDATE patient SET current_location_id = afterUuid WHERE current_location_id = beforeUuid;

  UPDATE debtor_group SET location_id = afterUuid WHERE location_id = beforeUuid;

  UPDATE enterprise SET location_id = afterUuid WHERE location_id = beforeUuid;

  -- delete the beforeUuid village and leave the afterUuid village.
  DELETE FROM village WHERE village.uuid = beforeUuid;
END $$


-- this writes transactions to a temporary table
CREATE PROCEDURE StageTrialBalanceTransaction(
  IN trans_id TEXT
)
BEGIN
  CREATE TEMPORARY TABLE IF NOT EXISTS stage_trial_balance_transaction (record_uuid BINARY(16));

  INSERT INTO stage_trial_balance_transaction
    SELECT record_uuid FROM posting_journal WHERE posting_journal.trans_id = trans_id COLLATE utf8_general_ci;
END $$

-- run the Trial Balance
CREATE PROCEDURE TrialBalance()
BEGIN

  -- this will hold our error cases
  CREATE TEMPORARY TABLE IF NOT EXISTS stage_trial_balance_errors (record_uuid BINARY(16), trans_id TEXT, code TEXT);

  -- check if dates are in the correct period
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.DATE_IN_WRONG_PERIOD' AS code
    FROM posting_journal AS pj
      JOIN stage_trial_balance_transaction AS temp ON pj.record_uuid = temp.record_uuid
      JOIN period AS p ON pj.period_id = p.id
    WHERE DATE(pj.trans_date) NOT BETWEEN DATE(p.start_date) AND DATE(p.end_date)
    GROUP BY pj.record_uuid;

  -- check to make sure that all lines of a transaction have a description
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.MISSING_DESCRIPTION' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    WHERE pj.description IS NULL
    GROUP BY pj.record_uuid;

  -- check that all dates are in the correct period_ids
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.DATE_IN_WRONG_PERIOD' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    JOIN period p ON pj.period_id = p.id
    WHERE DATE(pj.trans_date) NOT BETWEEN DATE(p.start_date) AND DATE(p.end_date)
    GROUP BY pj.record_uuid;

  -- check that all periods are unlocked
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.LOCKED_PERIOD' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    JOIN period p ON pj.period_id = p.id
    WHERE p.locked = 1 GROUP BY pj.record_uuid;

  -- check that all accounts are unlocked
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.LOCKED_ACCOUNT' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    JOIN account a ON pj.account_id = a.id
    WHERE a.locked = 1 GROUP BY pj.record_uuid;

  -- check that all transactions are balanced
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.UNBALANCED_TRANSACTIONS' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    GROUP BY pj.record_uuid
    HAVING SUM(pj.debit_equiv) <> SUM(pj.credit_equiv);

  -- check that all transactions have two or more lines
  INSERT INTO stage_trial_balance_errors
    SELECT pj.record_uuid, pj.trans_id, 'POSTING_JOURNAL.ERRORS.SINGLE_LINE_TRANSATION' AS code
    FROM posting_journal AS pj JOIN stage_trial_balance_transaction AS temp
      ON pj.record_uuid = temp.record_uuid
    GROUP BY pj.record_uuid
    HAVING COUNT(pj.record_uuid) < 2;

  SELECT DISTINCT BUID(record_uuid) AS record_uuid, trans_id, code FROM stage_trial_balance_errors ORDER BY code, trans_id;
END $$

-- stock consumption
CREATE PROCEDURE ComputeStockConsumptionByPeriod (
  IN inventory_uuid BINARY(16),
  IN depot_uuid BINARY(16),
  IN period_id MEDIUMINT(8),
  IN movementQuantity INT(11)
)
BEGIN
  INSERT INTO `stock_consumption` (`inventory_uuid`, `depot_uuid`, `period_id`, `quantity`) VALUES
    (inventory_uuid, depot_uuid, period_id, movementQuantity)
  ON DUPLICATE KEY UPDATE `quantity` = `quantity` + movementQuantity;
END $$

-- compute stock consumption
CREATE PROCEDURE ComputeStockConsumptionByDate (
  IN inventory_uuid BINARY(16),
  IN depot_uuid BINARY(16),
  IN movementDate DATE,
  IN movementQuantity INT(11)
)
BEGIN
  INSERT INTO `stock_consumption` (`inventory_uuid`, `depot_uuid`, `period_id`, `quantity`)
    SELECT inventory_uuid, depot_uuid, p.id, movementQuantity
    FROM period p
    WHERE DATE(movementDate) BETWEEN DATE(p.start_date) AND DATE(p.end_date)
  ON DUPLICATE KEY UPDATE `quantity` = `quantity` + movementQuantity;
END $$

-- stock movement document reference
-- This procedure calculate the reference of a movement based on the document_uuid
-- Insert this reference calculated into the document_map table as the movement reference
CREATE PROCEDURE ComputeMovementReference (
  IN documentUuid BINARY(16)
)
BEGIN
  DECLARE reference INT(11);

  SET reference = (SELECT COUNT(DISTINCT document_uuid) AS total FROM stock_movement LIMIT 1);

  INSERT INTO `document_map` (uuid, text)
  VALUES (documentUuid, CONCAT('MVT.', reference))
  ON DUPLICATE KEY UPDATE uuid = uuid;
END $$

-- This processus inserts records relative to the stock movement in the posting journal
CREATE PROCEDURE PostPurchase (
  IN document_uuid BINARY(16),
  IN date DATETIME,
  IN enterprise_id SMALLINT(5) UNSIGNED,
  IN project_id SMALLINT(5) UNSIGNED,
  IN currency_id TINYINT(3) UNSIGNED,
  IN user_id SMALLINT(5) UNSIGNED
)
BEGIN
  DECLARE InvalidInventoryAccounts CONDITION FOR SQLSTATE '45006';
  DECLARE current_fiscal_year_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_period_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_exchange_rate DECIMAL(19, 4) UNSIGNED;
  DECLARE transaction_id VARCHAR(100);
  DECLARE verify_invalid_accounts SMALLINT(5);
  DECLARE PURCHASE_TRANSACTION_TYPE TINYINT(3) UNSIGNED;

  -- should not be reassigned during the execution, to know why 9 please see the transaction_type table
  SET PURCHASE_TRANSACTION_TYPE = 9;


  -- getting the curent fiscal year
  SET current_fiscal_year_id = (
    SELECT id FROM fiscal_year AS fy
    WHERE date BETWEEN fy.start_date AND DATE(ADDDATE(fy.start_date, INTERVAL fy.number_of_months MONTH)) AND fy.enterprise_id = enterprise_id
  );

  -- getting the period id
  SET current_period_id = (
    SELECT id FROM period AS p
    WHERE DATE(date) BETWEEN DATE(p.start_date) AND DATE(p.end_date) AND p.fiscal_year_id = current_fiscal_year_id
  );

  CALL PostingJournalErrorHandler(enterprise_id, project_id, current_fiscal_year_id, current_period_id, 1, date);

 -- Check that all every inventory has a stock account and a variation account - if they do not the transaction will be Unbalanced
  SELECT
    COUNT(l.uuid) INTO verify_invalid_accounts
  FROM
    lot AS l
  JOIN
  	stock_movement sm ON sm.lot_uuid = l.uuid
  JOIN
  	inventory i ON i.uuid = l.inventory_uuid
  JOIN
  	inventory_group ig ON ig.uuid = i.group_uuid
  WHERE
  	ig.stock_account IS NULL AND
    ig.cogs_account IS NULL AND
    sm.document_uuid = document_uuid;

  IF verify_invalid_accounts > 0 THEN
    SIGNAL InvalidInventoryAccounts
    SET MESSAGE_TEXT = 'Every inventory should belong to a group with a cogs account and stock account.';
  END IF;

  -- getting the transaction number
  SET transaction_id = GenerateTransactionId(project_id);

  -- Debiting stock account, by inserting a record to the posting journal table
  INSERT INTO posting_journal
  (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  )
  SELECT
    HUID(UUID()), project_id, current_fiscal_year_id, current_period_id, transaction_id,
    date, p.uuid, sm.description, ig.stock_account, pi.total, 0, pi.total, 0, currency_id,
    PURCHASE_TRANSACTION_TYPE, user_id
  FROM
    stock_movement As sm
  JOIN
    lot l ON l.uuid = sm.lot_uuid
  JOIN
    purchase p ON p.uuid = l.origin_uuid
  JOIN
    purchase_item pi ON pi.purchase_uuid = p.uuid
  JOIN
    inventory i ON i.uuid = pi.inventory_uuid
  JOIN
    inventory_group ig ON ig.uuid = i.group_uuid
  WHERE
    sm.document_uuid = document_uuid
  GROUP BY i.uuid;

-- Crediting cost of good sale account, by inserting a record to the posting journal table
  INSERT INTO posting_journal
  (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  )
  SELECT
    HUID(UUID()), project_id, current_fiscal_year_id, current_period_id, transaction_id,
    date, p.uuid, sm.description, ig.cogs_account, 0, pi.total, 0, pi.total, currency_id,
    PURCHASE_TRANSACTION_TYPE, user_id
  FROM
    stock_movement As sm
  JOIN
    lot l ON l.uuid = sm.lot_uuid
  JOIN
    purchase p ON p.uuid = l.origin_uuid
  JOIN
    purchase_item pi ON pi.purchase_uuid = p.uuid
  JOIN
    inventory i ON i.uuid = pi.inventory_uuid
  JOIN
    inventory_group ig ON ig.uuid = i.group_uuid
  WHERE
    sm.document_uuid = document_uuid
  GROUP BY i.uuid;
END $$

-- This processus inserts records relative to the stock movement integration in the posting journal
CREATE PROCEDURE PostIntegration (
  IN document_uuid BINARY(16),
  IN date DATETIME,
  IN enterprise_id SMALLINT(5) UNSIGNED,
  IN project_id SMALLINT(5) UNSIGNED,
  IN currency_id TINYINT(3) UNSIGNED,
  IN user_id SMALLINT(5) UNSIGNED
)
BEGIN
  DECLARE InvalidInventoryAccounts CONDITION FOR SQLSTATE '45006';
  DECLARE current_fiscal_year_id MEDIUMINT(8) UNSIGNED;
  DECLARE current_period_id MEDIUMINT(8) UNSIGNED;
  DECLARE transaction_id VARCHAR(100);
  DECLARE verify_invalid_accounts SMALLINT(5);
  DECLARE STOCK_INTEGRATION_TRANSACTION_TYPE TINYINT(3) UNSIGNED;

  -- should not be reassigned during the execution, to know why 12 please see the transaction_type table
  SET STOCK_INTEGRATION_TRANSACTION_TYPE = 12;


  -- getting the curent fiscal year
  SET current_fiscal_year_id = (
    SELECT id FROM fiscal_year AS fy
    WHERE date BETWEEN fy.start_date AND DATE(ADDDATE(fy.start_date, INTERVAL fy.number_of_months MONTH)) AND fy.enterprise_id = enterprise_id
  );

  -- getting the period id
  SET current_period_id = (
    SELECT id FROM period AS p
    WHERE DATE(date) BETWEEN DATE(p.start_date) AND DATE(p.end_date) AND p.fiscal_year_id = current_fiscal_year_id
  );

  CALL PostingJournalErrorHandler(enterprise_id, project_id, current_fiscal_year_id, current_period_id, 1, date);

 -- Check that all every inventory has a stock account and a variation account - if they do not the transaction will be Unbalanced
  SELECT
    COUNT(l.uuid) INTO verify_invalid_accounts
  FROM
    lot AS l
  JOIN
  	stock_movement sm ON sm.lot_uuid = l.uuid
  JOIN
  	inventory i ON i.uuid = l.inventory_uuid
  JOIN
  	inventory_group ig ON ig.uuid = i.group_uuid
  WHERE
  	ig.stock_account IS NULL AND
    ig.cogs_account IS NULL AND
    sm.document_uuid = document_uuid;

  IF verify_invalid_accounts > 0 THEN
    SIGNAL InvalidInventoryAccounts
    SET MESSAGE_TEXT = 'Every inventory should belong to a group with a cogs account and stock account.';
  END IF;


  -- getting the transaction number
  SET transaction_id = GenerateTransactionId(project_id);

  -- Debiting stock account, by inserting a record to the posting journal table
  INSERT INTO posting_journal
  (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  )
  SELECT
    HUID(UUID()), project_id, current_fiscal_year_id, current_period_id, transaction_id,
    date, i.uuid, sm.description, ig.stock_account, l.quantity * l.unit_cost, 0, l.quantity * l.unit_cost, 0, currency_id,
    STOCK_INTEGRATION_TRANSACTION_TYPE, user_id
  FROM
    stock_movement As sm
  JOIN
    lot l ON l.uuid = sm.lot_uuid
  JOIN
    integration i ON i.uuid = l.origin_uuid
  JOIN
    inventory inv ON inv.uuid = l.inventory_uuid
  JOIN
    inventory_group ig ON ig.uuid = inv.group_uuid
  WHERE
    sm.document_uuid = document_uuid
  GROUP BY inv.uuid;

-- Crediting cost of good sale account, by inserting a record to the posting journal table
  INSERT INTO posting_journal
  (
    uuid, project_id, fiscal_year_id, period_id, trans_id, trans_date,
    record_uuid, description, account_id, debit, credit, debit_equiv,
    credit_equiv, currency_id, origin_id, user_id
  )
  SELECT
    HUID(UUID()), project_id, current_fiscal_year_id, current_period_id, transaction_id,
    date, i.uuid, sm.description, ig.cogs_account, 0, l.quantity * l.unit_cost, 0, l.quantity * l.unit_cost, currency_id,
    STOCK_INTEGRATION_TRANSACTION_TYPE, user_id
  FROM
    stock_movement As sm
  JOIN
    lot l ON l.uuid = sm.lot_uuid
  JOIN
    integration i ON i.uuid = l.origin_uuid
  JOIN
    inventory inv ON inv.uuid = l.inventory_uuid
  JOIN
    inventory_group ig ON ig.uuid = inv.group_uuid
  WHERE
    sm.document_uuid = document_uuid
  GROUP BY inv.uuid;
END $$
DELIMITER ;
