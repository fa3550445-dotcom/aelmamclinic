-- v3_initial.sql
-- =========================================================
-- AELMAM CLINIC - SQLite initial schema (v3, baseline)
-- Compatible with SQLite 3.10 (no window functions)
-- This file creates the full local schema as used by the app.
-- NOTE:
--   * Sync metadata columns (account_id/device_id/local_id/updated_at)
--     are NOT created here. They are added later by aelmam_parity_v3.sql
--     (or by the app code), along with their triggers/indexes.
--   * Soft-delete columns (isDeleted, deletedAt) are included from day one.
--   * user_version is set to 28 to align with the app’s latest schema.
-- =========================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode  = WAL;
PRAGMA synchronous   = NORMAL;
PRAGMA busy_timeout  = 5000;

-- ---------------------------------------------------------
-- 0) جداول الأعمال الأساسية
-- ---------------------------------------------------------

-- patients
CREATE TABLE IF NOT EXISTS patients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  age INTEGER,
  diagnosis TEXT,
  paidAmount REAL,
  remaining REAL,
  registerDate TEXT,
  phoneNumber TEXT,
  healthStatus TEXT,
  preferences TEXT,
  doctorId INTEGER,
  doctorName TEXT,
  doctorSpecialization TEXT,
  notes TEXT,
  serviceType TEXT,
  serviceId INTEGER,
  serviceName TEXT,
  serviceCost REAL,
  doctorShare REAL DEFAULT 0,
  doctorInput REAL DEFAULT 0,
  towerShare REAL DEFAULT 0,
  departmentShare REAL DEFAULT 0,
  doctorReviewPending INTEGER NOT NULL DEFAULT 0,
  doctorReviewedAt TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (doctorId) REFERENCES doctors(id)
);

-- returns
CREATE TABLE IF NOT EXISTS returns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT,
  patientName TEXT,
  phoneNumber TEXT,
  diagnosis TEXT,
  remaining REAL,
  age INTEGER DEFAULT 0,
  doctor TEXT DEFAULT '',
  notes TEXT DEFAULT '',
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- consumptions
CREATE TABLE IF NOT EXISTS consumptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patientId TEXT,
  itemId TEXT,
  quantity INTEGER,
  date TEXT,
  amount REAL,
  note TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- drugs
CREATE TABLE IF NOT EXISTS drugs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  notes TEXT,
  createdAt TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_lower_name ON drugs(lower(name));

-- prescriptions
CREATE TABLE IF NOT EXISTS prescriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patientId INTEGER NOT NULL,
  doctorId  INTEGER,
  recordDate TEXT NOT NULL,
  createdAt  TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (patientId) REFERENCES patients(id),
  FOREIGN KEY (doctorId)  REFERENCES doctors(id)
);
CREATE INDEX IF NOT EXISTS idx_prescriptions_patientId ON prescriptions(patientId);

-- prescription_items
CREATE TABLE IF NOT EXISTS prescription_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  prescriptionId INTEGER NOT NULL,
  drugId INTEGER NOT NULL,
  days INTEGER NOT NULL,
  timesPerDay INTEGER NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (prescriptionId) REFERENCES prescriptions(id) ON DELETE CASCADE,
  FOREIGN KEY (drugId)        REFERENCES drugs(id)
);
CREATE INDEX IF NOT EXISTS idx_prescription_items_prescriptionId ON prescription_items(prescriptionId);

-- complaints
CREATE TABLE IF NOT EXISTS complaints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  createdAt TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- appointments
CREATE TABLE IF NOT EXISTS appointments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patientId INTEGER,
  appointmentTime TEXT,
  status TEXT,
  notes TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (patientId) REFERENCES patients(id)
);
CREATE INDEX IF NOT EXISTS idx_appointments_patientId ON appointments(patientId);

-- doctors
CREATE TABLE IF NOT EXISTS doctors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  employeeId INTEGER,
  name TEXT,
  specialization TEXT,
  phoneNumber TEXT,
  startTime TEXT,
  endTime TEXT,
  printCounter INTEGER DEFAULT 0,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- consumption_types
CREATE TABLE IF NOT EXISTS consumption_types (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT UNIQUE,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- medical_services
CREATE TABLE IF NOT EXISTS medical_services (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  cost REAL NOT NULL,
  serviceType TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- service_doctor_share
CREATE TABLE IF NOT EXISTS service_doctor_share (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  serviceId INTEGER NOT NULL,
  doctorId INTEGER NOT NULL,
  sharePercentage REAL NOT NULL,
  towerSharePercentage REAL NOT NULL DEFAULT 0,
  isHidden INTEGER NOT NULL DEFAULT 0,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (serviceId) REFERENCES medical_services(id),
  FOREIGN KEY (doctorId)  REFERENCES doctors(id)
);
CREATE INDEX IF NOT EXISTS idx_service_doctor_share_serviceId ON service_doctor_share(serviceId);
CREATE INDEX IF NOT EXISTS idx_service_doctor_share_doctorId  ON service_doctor_share(doctorId);

-- employees
CREATE TABLE IF NOT EXISTS employees (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  identityNumber TEXT,
  phoneNumber TEXT,
  jobTitle TEXT,
  address TEXT,
  maritalStatus TEXT,
  basicSalary REAL,
  finalSalary REAL,
  isDoctor INTEGER DEFAULT 0,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- employees_loans
CREATE TABLE IF NOT EXISTS employees_loans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  employeeId INTEGER,
  loanDateTime TEXT,
  finalSalary REAL,
  ratioSum REAL,
  loanAmount REAL,
  leftover REAL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY(employeeId) REFERENCES employees(id)
);
CREATE INDEX IF NOT EXISTS idx_employees_loans_employeeId ON employees_loans(employeeId);

-- employees_salaries
CREATE TABLE IF NOT EXISTS employees_salaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  employeeId INTEGER,
  year INTEGER,
  month INTEGER,
  finalSalary REAL,
  ratioSum REAL,
  totalLoans REAL,
  netPay REAL,
  isPaid INTEGER DEFAULT 0,
  paymentDate TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY(employeeId) REFERENCES employees(id)
);
CREATE INDEX IF NOT EXISTS idx_employees_salaries_employeeId ON employees_salaries(employeeId);

-- employees_discounts
CREATE TABLE IF NOT EXISTS employees_discounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  employeeId INTEGER,
  discountDateTime TEXT,
  amount REAL,
  notes TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY(employeeId) REFERENCES employees(id)
);
CREATE INDEX IF NOT EXISTS idx_employees_discounts_employeeId ON employees_discounts(employeeId);

-- item_types
CREATE TABLE IF NOT EXISTS item_types (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- items
CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type_id INTEGER,
  name TEXT NOT NULL,
  stock INTEGER NOT NULL DEFAULT 0,
  cost REAL DEFAULT 0,
  price REAL DEFAULT 0,
  notes TEXT,
  created_at TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (type_id) REFERENCES item_types(id)
);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);

-- purchases
CREATE TABLE IF NOT EXISTS purchases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER,
  quantity INTEGER NOT NULL DEFAULT 0,
  unit_price REAL NOT NULL DEFAULT 0,
  total REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  supplier TEXT,
  notes TEXT,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (item_id) REFERENCES items(id)
);
CREATE INDEX IF NOT EXISTS idx_purchases_created_at ON purchases(created_at);

-- alert_settings  (تتضمن camelCase + snake_case للتوافق)
CREATE TABLE IF NOT EXISTS alert_settings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  -- مفاتيح/أعمدة ثنائية (camel + snake)
  itemId INTEGER,
  item_id INTEGER,

  itemUuid TEXT,
  item_uuid TEXT,

  isEnabled INTEGER NOT NULL DEFAULT 1,
  is_enabled INTEGER NOT NULL DEFAULT 1,

  lastTriggered TEXT,
  last_triggered TEXT,

  notifyTime TEXT,
  notify_time TEXT,

  createdAt TEXT,
  created_at TEXT,

  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);
CREATE INDEX IF NOT EXISTS idx_alert_settings_item_id ON alert_settings(item_id);

-- financial_logs
CREATE TABLE IF NOT EXISTS financial_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transaction_type     TEXT NOT NULL,
  operation            TEXT NOT NULL DEFAULT 'create',
  amount               REAL NOT NULL,
  employee_id          TEXT NOT NULL,
  description          TEXT,
  modification_details TEXT,
  timestamp            TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT
);

-- attachments (محلية فقط)
CREATE TABLE IF NOT EXISTS attachments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patientId INTEGER NOT NULL,
  filePath  TEXT NOT NULL,
  mimeType  TEXT,
  createdAt TEXT NOT NULL,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (patientId) REFERENCES patients(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_attachments_patient_created ON attachments(patientId, createdAt);

-- patient_services (تُستخدم لحساب التكلفة وحصص الأطباء)
CREATE TABLE IF NOT EXISTS patient_services (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patientId  INTEGER NOT NULL,
  serviceId  INTEGER,                 -- قد يكون NULL في إدخال يدوي
  serviceCost REAL NOT NULL,
  createdAt   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  isDeleted INTEGER NOT NULL DEFAULT 0,
  deletedAt TEXT,
  FOREIGN KEY (patientId) REFERENCES patients(id),
  FOREIGN KEY (serviceId) REFERENCES medical_services(id)
);
CREATE INDEX IF NOT EXISTS idx_patient_services_patientId ON patient_services(patientId);
CREATE INDEX IF NOT EXISTS idx_patient_services_serviceId ON patient_services(serviceId);

-- فهرس طبيعة لعناصر المخزون
CREATE UNIQUE INDEX IF NOT EXISTS uix_items_type_name ON items(account_id, type_id, name);
-- ملاحظة: عمود account_id سيُضاف لاحقًا بواسطة aelmam_parity_v3.sql.
-- إذا لم تكن أعمدة المزامنة موجودة بعد، فلن يُنشأ هذا الفهرس الآن.
-- لذلك ننشيء بدلاً منه النسخة بدون account_id كتجهيز (سيتم استبدالها لاحقًا إن لزم).
CREATE UNIQUE INDEX IF NOT EXISTS uix_items_type_name_local ON items(type_id, name);

-- ---------------------------------------------------------
-- 1) sync_identity + إتمام أعمدة alert_settings (تعبئة تلقائية)
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_identity(
  account_id TEXT,
  device_id  TEXT
);

INSERT INTO sync_identity(account_id,device_id)
SELECT NULL, lower(hex(randomblob(16)))
WHERE NOT EXISTS(SELECT 1 FROM sync_identity);

-- ترحيل/توحيد alert_settings تلقائيًا بعد INSERT
CREATE TRIGGER IF NOT EXISTS trg_alert_settings_set_defaults
AFTER INSERT ON alert_settings
BEGIN
  UPDATE alert_settings
     SET createdAt      = COALESCE(NEW.createdAt,  CURRENT_TIMESTAMP),
         created_at     = COALESCE(NEW.created_at, COALESCE(NEW.createdAt, CURRENT_TIMESTAMP)),
         isEnabled      = COALESCE(NEW.isEnabled,  1),
         is_enabled     = COALESCE(NEW.is_enabled, 1),
         itemId         = COALESCE(NEW.itemId,     NEW.item_id),
         item_id        = COALESCE(NEW.item_id,    NEW.itemId),
         lastTriggered  = COALESCE(NEW.lastTriggered,  NEW.last_triggered),
         last_triggered = COALESCE(NEW.last_triggered, NEW.lastTriggered),
         notifyTime     = COALESCE(NEW.notifyTime, NEW.notify_time),
         notify_time    = COALESCE(NEW.notify_time, NEW.notifyTime)
   WHERE id = NEW.id;
END;

-- ---------------------------------------------------------
-- 2) stats_dirty + Triggers لتعليم الإحصاءات كـ Dirty
-- ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS stats_dirty (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  dirty INTEGER NOT NULL DEFAULT 1
);
INSERT OR IGNORE INTO stats_dirty(id, dirty) VALUES (1, 1);

-- الجداول التي تؤثر على لوحة الإحصاءات
-- (patients, returns, consumptions, appointments, items, employees_loans,
--  prescriptions, prescription_items, drugs, complaints)
CREATE TRIGGER IF NOT EXISTS tg_patients_insert_stats_dirty
AFTER INSERT ON patients
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_patients_update_stats_dirty
AFTER UPDATE ON patients
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_patients_delete_stats_dirty
AFTER DELETE ON patients
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_returns_insert_stats_dirty
AFTER INSERT ON returns
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_returns_update_stats_dirty
AFTER UPDATE ON returns
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_returns_delete_stats_dirty
AFTER DELETE ON returns
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_consumptions_insert_stats_dirty
AFTER INSERT ON consumptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_consumptions_update_stats_dirty
AFTER UPDATE ON consumptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_consumptions_delete_stats_dirty
AFTER DELETE ON consumptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_appointments_insert_stats_dirty
AFTER INSERT ON appointments
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_appointments_update_stats_dirty
AFTER UPDATE ON appointments
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_appointments_delete_stats_dirty
AFTER DELETE ON appointments
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_items_insert_stats_dirty
AFTER INSERT ON items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_items_update_stats_dirty
AFTER UPDATE ON items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_items_delete_stats_dirty
AFTER DELETE ON items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_employees_loans_insert_stats_dirty
AFTER INSERT ON employees_loans
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_employees_loans_update_stats_dirty
AFTER UPDATE ON employees_loans
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_employees_loans_delete_stats_dirty
AFTER DELETE ON employees_loans
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_prescriptions_insert_stats_dirty
AFTER INSERT ON prescriptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_prescriptions_update_stats_dirty
AFTER UPDATE ON prescriptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_prescriptions_delete_stats_dirty
AFTER DELETE ON prescriptions
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_prescription_items_insert_stats_dirty
AFTER INSERT ON prescription_items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_prescription_items_update_stats_dirty
AFTER UPDATE ON prescription_items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_prescription_items_delete_stats_dirty
AFTER DELETE ON prescription_items
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_drugs_insert_stats_dirty
AFTER INSERT ON drugs
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_drugs_update_stats_dirty
AFTER UPDATE ON drugs
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_drugs_delete_stats_dirty
AFTER DELETE ON drugs
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

CREATE TRIGGER IF NOT EXISTS tg_complaints_insert_stats_dirty
AFTER INSERT ON complaints
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_complaints_update_stats_dirty
AFTER UPDATE ON complaints
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;
CREATE TRIGGER IF NOT EXISTS tg_complaints_delete_stats_dirty
AFTER DELETE ON complaints
BEGIN UPDATE stats_dirty SET dirty = 1 WHERE id = 1; END;

-- ---------------------------------------------------------
-- 3) فهارس إضافية للأداء (مطابقة لما يعتمد عليه التطبيق)
-- ---------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_patients_doctorId          ON patients(doctorId);
CREATE INDEX IF NOT EXISTS idx_patients_registerDate      ON patients(registerDate);
CREATE INDEX IF NOT EXISTS idx_returns_date               ON returns(date);
CREATE INDEX IF NOT EXISTS idx_consumptions_patientId     ON consumptions(patientId);
CREATE INDEX IF NOT EXISTS idx_consumptions_itemId        ON consumptions(itemId);

-- ---------------------------------------------------------
-- 4) ضبط إصدار المخطط ليتوافق مع التطبيق
-- ---------------------------------------------------------
PRAGMA user_version = 28;

-- ---------------------------------------------------------
-- 5) ملاحظات:
-- - لتفعيل مزامنة v3 (أعمدة/فهارس/تريجر المزامنة) شغّل:
--     aelmam_parity_v3.sql
--   أو استدعِ DBParityV3 من التطبيق.
-- - يمكن تشغيل هذا الملف على قاعدة فارغة لإنشاء كل الجداول محليًا.
-- ---------------------------------------------------------
