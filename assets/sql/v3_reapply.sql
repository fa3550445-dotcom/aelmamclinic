-- v3_reapply.sql
-- =========================================================
-- AELMAM CLINIC - Re-apply Parity (v3)
-- الهدف: إعادة تطبيق أعمدة/فهارس/تريجر المزامنة على قاعدة موجودة
-- متوافق مع SQLite 3.10 (بدون window functions، وبدون "DELETE ... AS")
-- ملاحظات:
--   * إضافة الأعمدة قد تُظهر أخطاء "duplicate column name" لو كانت موجودة مسبقًا.
--     هذا طبيعي ويُمكن تجاهله عند التنفيذ عبر سكربت خارجي (.bail off).
--   * الملف آمن للإعادة عدة مرات (idempotent) قدر الإمكان.
--   * يزيل فهارس "محلية فقط" إذا توفّر بديل يعتمد account_id.
-- =========================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA busy_timeout = 5000;

-- ---------------------------------------------------------
-- 0) هوية المزامنة المحلية (مصدر account_id/device_id)
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_identity(
  account_id TEXT,     -- يُنصح أن يكتبها التطبيق بعد تسجيل الدخول
  device_id  TEXT      -- نولّد قيمة إن لم توجد
);
INSERT INTO sync_identity(account_id,device_id)
SELECT NULL, lower(hex(randomblob(16)))
WHERE NOT EXISTS(SELECT 1 FROM sync_identity);

-- ---------------------------------------------------------
-- 1) إضافة أعمدة المزامنة لكل الجداول (قد تُظهر duplicate column)
-- ---------------------------------------------------------
/* patients */              ALTER TABLE patients              ADD COLUMN account_id TEXT;
ALTER TABLE patients              ADD COLUMN device_id  TEXT;
ALTER TABLE patients              ADD COLUMN local_id   INTEGER;
ALTER TABLE patients              ADD COLUMN updated_at TEXT;

/* returns */               ALTER TABLE returns               ADD COLUMN account_id TEXT;
ALTER TABLE returns               ADD COLUMN device_id  TEXT;
ALTER TABLE returns               ADD COLUMN local_id   INTEGER;
ALTER TABLE returns               ADD COLUMN updated_at TEXT;

/* consumptions */          ALTER TABLE consumptions          ADD COLUMN account_id TEXT;
ALTER TABLE consumptions          ADD COLUMN device_id  TEXT;
ALTER TABLE consumptions          ADD COLUMN local_id   INTEGER;
ALTER TABLE consumptions          ADD COLUMN updated_at TEXT;

/* drugs */                 ALTER TABLE drugs                  ADD COLUMN account_id TEXT;
ALTER TABLE drugs                  ADD COLUMN device_id  TEXT;
ALTER TABLE drugs                  ADD COLUMN local_id   INTEGER;
ALTER TABLE drugs                  ADD COLUMN updated_at TEXT;

/* prescriptions */         ALTER TABLE prescriptions         ADD COLUMN account_id TEXT;
ALTER TABLE prescriptions         ADD COLUMN device_id  TEXT;
ALTER TABLE prescriptions         ADD COLUMN local_id   INTEGER;
ALTER TABLE prescriptions         ADD COLUMN updated_at TEXT;

/* prescription_items */    ALTER TABLE prescription_items    ADD COLUMN account_id TEXT;
ALTER TABLE prescription_items    ADD COLUMN device_id  TEXT;
ALTER TABLE prescription_items    ADD COLUMN local_id   INTEGER;
ALTER TABLE prescription_items    ADD COLUMN updated_at TEXT;

/* complaints */            ALTER TABLE complaints            ADD COLUMN account_id TEXT;
ALTER TABLE complaints            ADD COLUMN device_id  TEXT;
ALTER TABLE complaints            ADD COLUMN local_id   INTEGER;
ALTER TABLE complaints            ADD COLUMN updated_at TEXT;

/* appointments */          ALTER TABLE appointments          ADD COLUMN account_id TEXT;
ALTER TABLE appointments          ADD COLUMN device_id  TEXT;
ALTER TABLE appointments          ADD COLUMN local_id   INTEGER;
ALTER TABLE appointments          ADD COLUMN updated_at TEXT;

/* doctors */               ALTER TABLE doctors               ADD COLUMN account_id TEXT;
ALTER TABLE doctors               ADD COLUMN device_id  TEXT;
ALTER TABLE doctors               ADD COLUMN local_id   INTEGER;
ALTER TABLE doctors               ADD COLUMN updated_at TEXT;

/* consumption_types */     ALTER TABLE consumption_types     ADD COLUMN account_id TEXT;
ALTER TABLE consumption_types     ADD COLUMN device_id  TEXT;
ALTER TABLE consumption_types     ADD COLUMN local_id   INTEGER;
ALTER TABLE consumption_types     ADD COLUMN updated_at TEXT;

/* medical_services */      ALTER TABLE medical_services      ADD COLUMN account_id TEXT;
ALTER TABLE medical_services      ADD COLUMN device_id  TEXT;
ALTER TABLE medical_services      ADD COLUMN local_id   INTEGER;
ALTER TABLE medical_services      ADD COLUMN updated_at TEXT;

/* service_doctor_share */  ALTER TABLE service_doctor_share  ADD COLUMN account_id TEXT;
ALTER TABLE service_doctor_share  ADD COLUMN device_id  TEXT;
ALTER TABLE service_doctor_share  ADD COLUMN local_id   INTEGER;
ALTER TABLE service_doctor_share  ADD COLUMN updated_at TEXT;

/* employees */             ALTER TABLE employees             ADD COLUMN account_id TEXT;
ALTER TABLE employees             ADD COLUMN device_id  TEXT;
ALTER TABLE employees             ADD COLUMN local_id   INTEGER;
ALTER TABLE employees             ADD COLUMN updated_at TEXT;

/* employees_loans */       ALTER TABLE employees_loans       ADD COLUMN account_id TEXT;
ALTER TABLE employees_loans       ADD COLUMN device_id  TEXT;
ALTER TABLE employees_loans       ADD COLUMN local_id   INTEGER;
ALTER TABLE employees_loans       ADD COLUMN updated_at TEXT;

/* employees_salaries */    ALTER TABLE employees_salaries    ADD COLUMN account_id TEXT;
ALTER TABLE employees_salaries    ADD COLUMN device_id  TEXT;
ALTER TABLE employees_salaries    ADD COLUMN local_id   INTEGER;
ALTER TABLE employees_salaries    ADD COLUMN updated_at TEXT;

/* employees_discounts */   ALTER TABLE employees_discounts   ADD COLUMN account_id TEXT;
ALTER TABLE employees_discounts   ADD COLUMN device_id  TEXT;
ALTER TABLE employees_discounts   ADD COLUMN local_id   INTEGER;
ALTER TABLE employees_discounts   ADD COLUMN updated_at TEXT;

/* items */                 ALTER TABLE items                 ADD COLUMN account_id TEXT;
ALTER TABLE items                 ADD COLUMN device_id  TEXT;
ALTER TABLE items                 ADD COLUMN local_id   INTEGER;
ALTER TABLE items                 ADD COLUMN updated_at TEXT;

/* item_types */            ALTER TABLE item_types            ADD COLUMN account_id TEXT;
ALTER TABLE item_types            ADD COLUMN device_id  TEXT;
ALTER TABLE item_types            ADD COLUMN local_id   INTEGER;
ALTER TABLE item_types            ADD COLUMN updated_at TEXT;

/* purchases */             ALTER TABLE purchases             ADD COLUMN account_id TEXT;
ALTER TABLE purchases             ADD COLUMN device_id  TEXT;
ALTER TABLE purchases             ADD COLUMN local_id   INTEGER;
ALTER TABLE purchases             ADD COLUMN updated_at TEXT;

/* alert_settings */        ALTER TABLE alert_settings        ADD COLUMN account_id TEXT;
ALTER TABLE alert_settings        ADD COLUMN device_id  TEXT;
ALTER TABLE alert_settings        ADD COLUMN local_id   INTEGER;
ALTER TABLE alert_settings        ADD COLUMN updated_at TEXT;

/* financial_logs */        ALTER TABLE financial_logs        ADD COLUMN account_id TEXT;
ALTER TABLE financial_logs        ADD COLUMN device_id  TEXT;
ALTER TABLE financial_logs        ADD COLUMN local_id   INTEGER;
ALTER TABLE financial_logs        ADD COLUMN updated_at TEXT;

/* patient_services */      ALTER TABLE patient_services      ADD COLUMN account_id TEXT;
ALTER TABLE patient_services      ADD COLUMN device_id  TEXT;
ALTER TABLE patient_services      ADD COLUMN local_id   INTEGER;
ALTER TABLE patient_services      ADD COLUMN updated_at TEXT;

-- ---------------------------------------------------------
-- 2) تعبئة أعمدة المزامنة (COALESCE)
-- ---------------------------------------------------------
UPDATE patients              SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE returns               SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE consumptions          SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE drugs                 SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE prescriptions         SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE prescription_items    SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE complaints            SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE appointments          SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE doctors               SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE consumption_types     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE medical_services      SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE service_doctor_share  SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE employees             SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE employees_loans       SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE employees_salaries    SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE employees_discounts   SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE items                 SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE item_types            SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE purchases             SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE alert_settings        SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE financial_logs        SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));
UPDATE patient_services      SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity));

UPDATE patients              SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE returns               SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE consumptions          SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE drugs                 SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE prescriptions         SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE prescription_items    SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE complaints            SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE appointments          SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE doctors               SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE consumption_types     SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE medical_services      SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE service_doctor_share  SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE employees             SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE employees_loans       SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE employees_salaries    SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE employees_discounts   SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE items                 SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE item_types            SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE purchases             SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE alert_settings        SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE financial_logs        SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));
UPDATE patient_services      SET device_id  = COALESCE(device_id,(SELECT device_id FROM sync_identity));

UPDATE patients              SET local_id   = COALESCE(local_id, rowid);
UPDATE returns               SET local_id   = COALESCE(local_id, rowid);
UPDATE consumptions          SET local_id   = COALESCE(local_id, rowid);
UPDATE drugs                 SET local_id   = COALESCE(local_id, rowid);
UPDATE prescriptions         SET local_id   = COALESCE(local_id, rowid);
UPDATE prescription_items    SET local_id   = COALESCE(local_id, rowid);
UPDATE complaints            SET local_id   = COALESCE(local_id, rowid);
UPDATE appointments          SET local_id   = COALESCE(local_id, rowid);
UPDATE doctors               SET local_id   = COALESCE(local_id, rowid);
UPDATE consumption_types     SET local_id   = COALESCE(local_id, rowid);
UPDATE medical_services      SET local_id   = COALESCE(local_id, rowid);
UPDATE service_doctor_share  SET local_id   = COALESCE(local_id, rowid);
UPDATE employees             SET local_id   = COALESCE(local_id, rowid);
UPDATE employees_loans       SET local_id   = COALESCE(local_id, rowid);
UPDATE employees_salaries    SET local_id   = COALESCE(local_id, rowid);
UPDATE employees_discounts   SET local_id   = COALESCE(local_id, rowid);
UPDATE items                 SET local_id   = COALESCE(local_id, rowid);
UPDATE item_types            SET local_id   = COALESCE(local_id, rowid);
UPDATE purchases             SET local_id   = COALESCE(local_id, rowid);
UPDATE alert_settings        SET local_id   = COALESCE(local_id, rowid);
UPDATE financial_logs        SET local_id   = COALESCE(local_id, rowid);
UPDATE patient_services      SET local_id   = COALESCE(local_id, rowid);

UPDATE patients              SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE returns               SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE consumptions          SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE drugs                 SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE prescriptions         SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE prescription_items    SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE complaints            SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE appointments          SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE doctors               SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE consumption_types     SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE medical_services      SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE service_doctor_share  SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE employees             SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE employees_loans       SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE employees_salaries    SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE employees_discounts   SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE items                 SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE item_types            SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE purchases             SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE alert_settings        SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE financial_logs        SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);
UPDATE patient_services      SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP);

-- ---------------------------------------------------------
-- 3) إزالة التكرارات (acc_id,dev_id,local_id) – بدون "DELETE ... AS"
--    نبقي الأحدث حسب updated_at ثم الأكبر rowid
-- ---------------------------------------------------------
DELETE FROM patients WHERE EXISTS (
  SELECT 1 FROM patients AS b
  WHERE patients.account_id=b.account_id AND patients.device_id=b.device_id AND patients.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(patients.updated_at,'') OR (b.updated_at=patients.updated_at AND b.rowid>patients.rowid))
);
DELETE FROM returns WHERE EXISTS (
  SELECT 1 FROM returns AS b
  WHERE returns.account_id=b.account_id AND returns.device_id=b.device_id AND returns.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(returns.updated_at,'') OR (b.updated_at=returns.updated_at AND b.rowid>returns.rowid))
);
DELETE FROM consumptions WHERE EXISTS (
  SELECT 1 FROM consumptions AS b
  WHERE consumptions.account_id=b.account_id AND consumptions.device_id=b.device_id AND consumptions.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(consumptions.updated_at,'') OR (b.updated_at=consumptions.updated_at AND b.rowid>consumptions.rowid))
);
DELETE FROM drugs WHERE EXISTS (
  SELECT 1 FROM drugs AS b
  WHERE drugs.account_id=b.account_id AND drugs.device_id=b.device_id AND drugs.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(drugs.updated_at,'') OR (b.updated_at=drugs.updated_at AND b.rowid>drugs.rowid))
);
DELETE FROM prescriptions WHERE EXISTS (
  SELECT 1 FROM prescriptions AS b
  WHERE prescriptions.account_id=b.account_id AND prescriptions.device_id=b.device_id AND prescriptions.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(prescriptions.updated_at,'') OR (b.updated_at=prescriptions.updated_at AND b.rowid>prescriptions.rowid))
);
DELETE FROM prescription_items WHERE EXISTS (
  SELECT 1 FROM prescription_items AS b
  WHERE prescription_items.account_id=b.account_id AND prescription_items.device_id=b.device_id AND prescription_items.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(prescription_items.updated_at,'') OR (b.updated_at=prescription_items.updated_at AND b.rowid>prescription_items.rowid))
);
DELETE FROM complaints WHERE EXISTS (
  SELECT 1 FROM complaints AS b
  WHERE complaints.account_id=b.account_id AND complaints.device_id=b.device_id AND complaints.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(complaints.updated_at,'') OR (b.updated_at=complaints.updated_at AND b.rowid>complaints.rowid))
);
DELETE FROM appointments WHERE EXISTS (
  SELECT 1 FROM appointments AS b
  WHERE appointments.account_id=b.account_id AND appointments.device_id=b.device_id AND appointments.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(appointments.updated_at,'') OR (b.updated_at=appointments.updated_at AND b.rowid>appointments.rowid))
);
DELETE FROM doctors WHERE EXISTS (
  SELECT 1 FROM doctors AS b
  WHERE doctors.account_id=b.account_id AND doctors.device_id=b.device_id AND doctors.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(doctors.updated_at,'') OR (b.updated_at=doctors.updated_at AND b.rowid>doctors.rowid))
);
DELETE FROM consumption_types WHERE EXISTS (
  SELECT 1 FROM consumption_types AS b
  WHERE consumption_types.account_id=b.account_id AND consumption_types.device_id=b.device_id AND consumption_types.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(consumption_types.updated_at,'') OR (b.updated_at=consumption_types.updated_at AND b.rowid>consumption_types.rowid))
);
DELETE FROM medical_services WHERE EXISTS (
  SELECT 1 FROM medical_services AS b
  WHERE medical_services.account_id=b.account_id AND medical_services.device_id=b.device_id AND medical_services.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(medical_services.updated_at,'') OR (b.updated_at=medical_services.updated_at AND b.rowid>medical_services.rowid))
);
DELETE FROM service_doctor_share WHERE EXISTS (
  SELECT 1 FROM service_doctor_share AS b
  WHERE service_doctor_share.account_id=b.account_id AND service_doctor_share.device_id=b.device_id AND service_doctor_share.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(service_doctor_share.updated_at,'') OR (b.updated_at=service_doctor_share.updated_at AND b.rowid>service_doctor_share.rowid))
);
DELETE FROM employees WHERE EXISTS (
  SELECT 1 FROM employees AS b
  WHERE employees.account_id=b.account_id AND employees.device_id=b.device_id AND employees.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(employees.updated_at,'') OR (b.updated_at=employees.updated_at AND b.rowid>employees.rowid))
);
DELETE FROM employees_loans WHERE EXISTS (
  SELECT 1 FROM employees_loans AS b
  WHERE employees_loans.account_id=b.account_id AND employees_loans.device_id=b.device_id AND employees_loans.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(employees_loans.updated_at,'') OR (b.updated_at=employees_loans.updated_at AND b.rowid>employees_loans.rowid))
);
DELETE FROM employees_salaries WHERE EXISTS (
  SELECT 1 FROM employees_salaries AS b
  WHERE employees_salaries.account_id=b.account_id AND employees_salaries.device_id=b.device_id AND employees_salaries.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(employees_salaries.updated_at,'') OR (b.updated_at=employees_salaries.updated_at AND b.rowid>employees_salaries.rowid))
);
DELETE FROM employees_discounts WHERE EXISTS (
  SELECT 1 FROM employees_discounts AS b
  WHERE employees_discounts.account_id=b.account_id AND employees_discounts.device_id=b.device_id AND employees_discounts.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(employees_discounts.updated_at,'') OR (b.updated_at=employees_discounts.updated_at AND b.rowid>employees_discounts.rowid))
);
DELETE FROM items WHERE EXISTS (
  SELECT 1 FROM items AS b
  WHERE items.account_id=b.account_id AND items.device_id=b.device_id AND items.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(items.updated_at,'') OR (b.updated_at=items.updated_at AND b.rowid>items.rowid))
);
DELETE FROM item_types WHERE EXISTS (
  SELECT 1 FROM item_types AS b
  WHERE item_types.account_id=b.account_id AND item_types.device_id=b.device_id AND item_types.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(item_types.updated_at,'') OR (b.updated_at=item_types.updated_at AND b.rowid>item_types.rowid))
);
DELETE FROM purchases WHERE EXISTS (
  SELECT 1 FROM purchases AS b
  WHERE purchases.account_id=b.account_id AND purchases.device_id=b.device_id AND purchases.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(purchases.updated_at,'') OR (b.updated_at=purchases.updated_at AND b.rowid>purchases.rowid))
);
DELETE FROM alert_settings WHERE EXISTS (
  SELECT 1 FROM alert_settings AS b
  WHERE alert_settings.account_id=b.account_id AND alert_settings.device_id=b.device_id AND alert_settings.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(alert_settings.updated_at,'') OR (b.updated_at=alert_settings.updated_at AND b.rowid>alert_settings.rowid))
);
DELETE FROM financial_logs WHERE EXISTS (
  SELECT 1 FROM financial_logs AS b
  WHERE financial_logs.account_id=b.account_id AND financial_logs.device_id=b.device_id AND financial_logs.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(financial_logs.updated_at,'') OR (b.updated_at=financial_logs.updated_at AND b.rowid>financial_logs.rowid))
);
DELETE FROM patient_services WHERE EXISTS (
  SELECT 1 FROM patient_services AS b
  WHERE patient_services.account_id=b.account_id AND patient_services.device_id=b.device_id AND patient_services.local_id=b.local_id
    AND (COALESCE(b.updated_at,'')>COALESCE(patient_services.updated_at,'') OR (b.updated_at=patient_services.updated_at AND b.rowid>patient_services.rowid))
);

-- ---------------------------------------------------------
-- 4) إزالة تكرارات الأسماء الطبيعية
-- ---------------------------------------------------------
-- drugs: (account_id, lower(trim(name)))
DELETE FROM drugs
WHERE EXISTS (
  SELECT 1 FROM drugs AS b
  WHERE drugs.account_id=b.account_id
    AND lower(trim(drugs.name))=lower(trim(b.name))
    AND (COALESCE(b.updated_at,'')>COALESCE(drugs.updated_at,'') OR (b.updated_at=drugs.updated_at AND b.rowid>drugs.rowid))
);
UPDATE drugs SET name = TRIM(name) WHERE name IS NOT NULL;

-- items: (account_id, type_id, trim(name))
DELETE FROM items
WHERE EXISTS (
  SELECT 1 FROM items AS b
  WHERE items.account_id=b.account_id AND items.type_id=b.type_id
    AND TRIM(items.name)=TRIM(b.name)
    AND (COALESCE(b.updated_at,'')>COALESCE(items.updated_at,'') OR (b.updated_at=items.updated_at AND b.rowid>items.rowid))
);
UPDATE items SET name = TRIM(name) WHERE name IS NOT NULL;

-- ---------------------------------------------------------
-- 5) الفهارس المطابقة للسحابة + تنظيف الفهارس المحلية القديمة
-- ---------------------------------------------------------
-- (A) إنشاء فهارس acc_dev_local
CREATE UNIQUE INDEX IF NOT EXISTS patients_uix_acc_dev_local             ON patients(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS returns_uix_acc_dev_local              ON returns(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS consumptions_uix_acc_dev_local         ON consumptions(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS drugs_uix_acc_dev_local                ON drugs(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS prescriptions_uix_acc_dev_local        ON prescriptions(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS prescription_items_uix_acc_dev_local   ON prescription_items(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS complaints_uix_acc_dev_local           ON complaints(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS appointments_uix_acc_dev_local         ON appointments(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS doctors_uix_acc_dev_local              ON doctors(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS consumption_types_uix_acc_dev_local    ON consumption_types(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS medical_services_uix_acc_dev_local     ON medical_services(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS service_doctor_share_uix_acc_dev_local ON service_doctor_share(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS employees_uix_acc_dev_local            ON employees(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS employees_loans_uix_acc_dev_local      ON employees_loans(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS employees_salaries_uix_acc_dev_local   ON employees_salaries(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS employees_discounts_uix_acc_dev_local  ON employees_discounts(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS items_uix_acc_dev_local                ON items(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS item_types_uix_acc_dev_local           ON item_types(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS purchases_uix_acc_dev_local            ON purchases(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS alert_settings_uix_acc_dev_local       ON alert_settings(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS financial_logs_uix_acc_dev_local       ON financial_logs(account_id, device_id, local_id);
CREATE UNIQUE INDEX IF NOT EXISTS patient_services_uix_acc_dev_local     ON patient_services(account_id, device_id, local_id);

-- (B) فهارس الطبيعة لكل حساب
CREATE UNIQUE INDEX IF NOT EXISTS uidx_drugs_name_per_account ON drugs(account_id, lower(name));
CREATE UNIQUE INDEX IF NOT EXISTS items_type_name             ON items(account_id, type_id, name);

-- (C) تنظيف فهارس محلية قديمة كي لا تمنع تعدد الحسابات على نفس الجهاز
DROP INDEX IF EXISTS uix_drugs_lower_name;        -- كان يفرض uniqueness على lower(name) فقط
DROP INDEX IF EXISTS uix_items_type_name_local;    -- كان يفرض uniqueness على (type_id, name) فقط

-- ---------------------------------------------------------
-- 6) Triggers لتحديث updated_at بعد UPDATE (تجنّب الحلقات)
-- ---------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_patients_touch_updated_at
AFTER UPDATE ON patients FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE patients SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_returns_touch_updated_at
AFTER UPDATE ON returns FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE returns SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_consumptions_touch_updated_at
AFTER UPDATE ON consumptions FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE consumptions SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_drugs_touch_updated_at
AFTER UPDATE ON drugs FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE drugs SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_prescriptions_touch_updated_at
AFTER UPDATE ON prescriptions FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE prescriptions SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_prescription_items_touch_updated_at
AFTER UPDATE ON prescription_items FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE prescription_items SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_complaints_touch_updated_at
AFTER UPDATE ON complaints FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE complaints SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_appointments_touch_updated_at
AFTER UPDATE ON appointments FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE appointments SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_doctors_touch_updated_at
AFTER UPDATE ON doctors FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE doctors SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_consumption_types_touch_updated_at
AFTER UPDATE ON consumption_types FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE consumption_types SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_medical_services_touch_updated_at
AFTER UPDATE ON medical_services FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE medical_services SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_service_doctor_share_touch_updated_at
AFTER UPDATE ON service_doctor_share FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE service_doctor_share SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_employees_touch_updated_at
AFTER UPDATE ON employees FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE employees SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_employees_loans_touch_updated_at
AFTER UPDATE ON employees_loans FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE employees_loans SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_employees_salaries_touch_updated_at
AFTER UPDATE ON employees_salaries FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE employees_salaries SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_employees_discounts_touch_updated_at
AFTER UPDATE ON employees_discounts FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE employees_discounts SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_items_touch_updated_at
AFTER UPDATE ON items FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE items SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_item_types_touch_updated_at
AFTER UPDATE ON item_types FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE item_types SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_purchases_touch_updated_at
AFTER UPDATE ON purchases FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE purchases SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_alert_settings_touch_updated_at
AFTER UPDATE ON alert_settings FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE alert_settings SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_financial_logs_touch_updated_at
AFTER UPDATE ON financial_logs FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE financial_logs SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

CREATE TRIGGER IF NOT EXISTS trg_patient_services_touch_updated_at
AFTER UPDATE ON patient_services FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN UPDATE patient_services SET updated_at=CURRENT_TIMESTAMP WHERE rowid=NEW.rowid; END;

-- ---------------------------------------------------------
-- 6-bis) AFTER INSERT: تعبئة account_id/device_id/local_id/updated_at
-- ---------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_patients_fill_sync_cols
AFTER INSERT ON patients FOR EACH ROW
BEGIN
  UPDATE patients
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_returns_fill_sync_cols
AFTER INSERT ON returns FOR EACH ROW
BEGIN
  UPDATE returns
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_consumptions_fill_sync_cols
AFTER INSERT ON consumptions FOR EACH ROW
BEGIN
  UPDATE consumptions
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_drugs_fill_sync_cols
AFTER INSERT ON drugs FOR EACH ROW
BEGIN
  UPDATE drugs
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_prescriptions_fill_sync_cols
AFTER INSERT ON prescriptions FOR EACH ROW
BEGIN
  UPDATE prescriptions
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_prescription_items_fill_sync_cols
AFTER INSERT ON prescription_items FOR EACH ROW
BEGIN
  UPDATE prescription_items
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_complaints_fill_sync_cols
AFTER INSERT ON complaints FOR EACH ROW
BEGIN
  UPDATE complaints
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_appointments_fill_sync_cols
AFTER INSERT ON appointments FOR EACH ROW
BEGIN
  UPDATE appointments
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_doctors_fill_sync_cols
AFTER INSERT ON doctors FOR EACH ROW
BEGIN
  UPDATE doctors
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_consumption_types_fill_sync_cols
AFTER INSERT ON consumption_types FOR EACH ROW
BEGIN
  UPDATE consumption_types
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_medical_services_fill_sync_cols
AFTER INSERT ON medical_services FOR EACH ROW
BEGIN
  UPDATE medical_services
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_service_doctor_share_fill_sync_cols
AFTER INSERT ON service_doctor_share FOR EACH ROW
BEGIN
  UPDATE service_doctor_share
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_employees_fill_sync_cols
AFTER INSERT ON employees FOR EACH ROW
BEGIN
  UPDATE employees
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_employees_loans_fill_sync_cols
AFTER INSERT ON employees_loans FOR EACH ROW
BEGIN
  UPDATE employees_loans
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_employees_salaries_fill_sync_cols
AFTER INSERT ON employees_salaries FOR EACH ROW
BEGIN
  UPDATE employees_salaries
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_employees_discounts_fill_sync_cols
AFTER INSERT ON employees_discounts FOR EACH ROW
BEGIN
  UPDATE employees_discounts
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_items_fill_sync_cols
AFTER INSERT ON items FOR EACH ROW
BEGIN
  UPDATE items
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_item_types_fill_sync_cols
AFTER INSERT ON item_types FOR EACH ROW
BEGIN
  UPDATE item_types
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_purchases_fill_sync_cols
AFTER INSERT ON purchases FOR EACH ROW
BEGIN
  UPDATE purchases
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_alert_settings_fill_sync_cols
AFTER INSERT ON alert_settings FOR EACH ROW
BEGIN
  UPDATE alert_settings
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_financial_logs_fill_sync_cols
AFTER INSERT ON financial_logs FOR EACH ROW
BEGIN
  UPDATE financial_logs
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_patient_services_fill_sync_cols
AFTER INSERT ON patient_services FOR EACH ROW
BEGIN
  UPDATE patient_services
     SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
         device_id  = COALESCE(device_id,(SELECT device_id  FROM sync_identity)),
         local_id   = COALESCE(local_id, rowid),
         updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
   WHERE rowid = NEW.rowid;
END;

-- ---------------------------------------------------------
-- 7) فحوصات نهائية (يُفترض ترجع 0 في كل صف)
-- ---------------------------------------------------------
SELECT 'dup_acc_dev_local_patients',           COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM patients            GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_returns',            COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM returns             GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_consumptions',       COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM consumptions        GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_drugs',              COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM drugs               GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_prescriptions',      COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM prescriptions       GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_prescription_items', COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM prescription_items  GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_complaints',         COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM complaints          GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_appointments',       COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM appointments        GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_doctors',            COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM doctors             GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_consumption_types',  COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM consumption_types   GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_medical_services',   COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM medical_services    GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_service_doctor_share',COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM service_doctor_share GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_employees',          COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM employees           GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_employees_loans',    COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM employees_loans     GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_employees_salaries', COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM employees_salaries  GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_employees_discounts',COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM employees_discounts GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_items',              COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM items               GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_item_types',         COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM item_types          GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_purchases',          COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM purchases           GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_alert_settings',     COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM alert_settings      GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_financial_logs',     COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM financial_logs      GROUP BY 1,2,3 HAVING c>1);
SELECT 'dup_acc_dev_local_patient_services',   COUNT(*) FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM patient_services    GROUP BY 1,2,3 HAVING c>1);

-- Checks الطبيعية:
SELECT 'dup_drugs_name_per_account', COUNT(*) FROM (SELECT account_id, lower(TRIM(name)) k, COUNT(*) c FROM drugs GROUP BY 1,2 HAVING c>1);
SELECT 'dup_items_type_name',        COUNT(*) FROM (SELECT account_id, type_id, TRIM(name) k, COUNT(*) c FROM items GROUP BY 1,2,3 HAVING c>1);
