-- Optional: keep everything organized in a dedicated schema
CREATE SCHEMA IF NOT EXISTS hospital_crm;
SET search_path = hospital_crm;

-- ---------- Lookups / Core org structure ----------
CREATE TABLE departments (
  department_id  BIGSERIAL PRIMARY KEY,
  name           TEXT NOT NULL UNIQUE,
  phone          TEXT,
  email          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE providers (
  provider_id    BIGSERIAL PRIMARY KEY,
  department_id  BIGINT REFERENCES departments(department_id) ON DELETE SET NULL,
  first_name     TEXT NOT NULL,
  last_name      TEXT NOT NULL,
  npi            TEXT UNIQUE,               -- optional (US)
  phone          TEXT,
  email          TEXT,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Patients + Contacts ----------
CREATE TABLE patients (
  patient_id     BIGSERIAL PRIMARY KEY,
  mrn            TEXT UNIQUE,               -- medical record number
  first_name     TEXT NOT NULL,
  last_name      TEXT NOT NULL,
  dob            DATE,
  sex            TEXT,                      -- keep simple; can be enum later
  phone          TEXT,
  email          TEXT,
  address_line1  TEXT,
  address_line2  TEXT,
  city           TEXT,
  state          TEXT,
  postal_code    TEXT,
  country        TEXT DEFAULT 'USA',
  status         TEXT NOT NULL DEFAULT 'active', -- active/inactive/deceased, etc.
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One patient can have multiple related contacts (guardian, spouse, etc.)
CREATE TABLE patient_contacts (
  contact_id     BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  relationship   TEXT NOT NULL,             -- e.g., spouse, parent, caregiver
  full_name      TEXT NOT NULL,
  phone          TEXT,
  email          TEXT,
  is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Ensure at most one primary contact per patient
CREATE UNIQUE INDEX patient_one_primary_contact
  ON patient_contacts(patient_id)
  WHERE is_primary;

-- ---------- CRM-ish "cases" (care episodes) ----------
CREATE TABLE cases (
  case_id        BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  provider_id    BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  department_id  BIGINT REFERENCES departments(department_id) ON DELETE SET NULL,
  title          TEXT NOT NULL,             -- e.g., "Post-op follow-up"
  status         TEXT NOT NULL DEFAULT 'open', -- open/closed/on_hold
  priority       TEXT DEFAULT 'normal',     -- low/normal/high
  opened_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at      TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX cases_patient_idx ON cases(patient_id);
CREATE INDEX cases_provider_idx ON cases(provider_id);
CREATE INDEX cases_status_idx ON cases(status);

-- ---------- Appointments ----------
CREATE TABLE appointments (
  appointment_id BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  provider_id    BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  department_id  BIGINT REFERENCES departments(department_id) ON DELETE SET NULL,
  case_id        BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  starts_at      TIMESTAMPTZ NOT NULL,
  ends_at        TIMESTAMPTZ,
  status         TEXT NOT NULL DEFAULT 'scheduled', -- scheduled/confirmed/cancelled/no_show/completed
  reason         TEXT,
  location       TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX appt_patient_time_idx ON appointments(patient_id, starts_at DESC);
CREATE INDEX appt_provider_time_idx ON appointments(provider_id, starts_at DESC);

-- ---------- Notes (clinical-ish but simple CRM log) ----------
CREATE TABLE notes (
  note_id        BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  case_id        BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  appointment_id BIGINT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
  author_provider_id BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  note_type      TEXT NOT NULL DEFAULT 'general', -- general/call/followup
  body           TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX notes_patient_idx ON notes(patient_id, created_at DESC);
CREATE INDEX notes_case_idx ON notes(case_id, created_at DESC);

-- ---------- CRM Tasks (follow-ups, reminders) ----------
CREATE TABLE tasks (
  task_id        BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT REFERENCES patients(patient_id) ON DELETE CASCADE,
  case_id        BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  assigned_provider_id BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  title          TEXT NOT NULL,
  description    TEXT,
  status         TEXT NOT NULL DEFAULT 'open', -- open/in_progress/done/cancelled
  due_at         TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX tasks_assigned_status_idx ON tasks(assigned_provider_id, status);
CREATE INDEX tasks_due_idx ON tasks(due_at);

-- ---------- Communications (calls/emails/sms) ----------
CREATE TABLE communications (
  comm_id        BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  case_id        BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  appointment_id BIGINT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
  channel        TEXT NOT NULL,             -- phone/email/sms/portal/in_person
  direction      TEXT NOT NULL,             -- inbound/outbound
  subject        TEXT,
  body           TEXT,
  outcome        TEXT,                      -- reached/left_vm/bounced/etc.
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX comm_patient_time_idx ON communications(patient_id, occurred_at DESC);

-- ---------- updated_at helper (simple approach) ----------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER patients_set_updated_at
BEFORE UPDATE ON patients
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- Continue in same schema
SET search_path = hospital_crm;

-- =========================
-- USER ACCOUNTS + ROLES (RBAC)
-- =========================

CREATE TABLE users (
  user_id        BIGSERIAL PRIMARY KEY,
  provider_id    BIGINT UNIQUE REFERENCES providers(provider_id) ON DELETE SET NULL,
  email          TEXT NOT NULL UNIQUE,
  password_hash  TEXT NOT NULL,               -- store a strong hash (bcrypt/argon2) from app
  first_name     TEXT,
  last_name      TEXT,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at  TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE roles (
  role_id        BIGSERIAL PRIMARY KEY,
  name           TEXT NOT NULL UNIQUE,        -- admin, billing, clinician, frontdesk, etc.
  description    TEXT
);

CREATE TABLE user_roles (
  user_id        BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  role_id        BIGINT NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);

-- Optional: fine-grained permissions
CREATE TABLE permissions (
  permission_id  BIGSERIAL PRIMARY KEY,
  code           TEXT NOT NULL UNIQUE,        -- e.g., "billing.invoice.read"
  description    TEXT
);

CREATE TABLE role_permissions (
  role_id        BIGINT NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
  permission_id  BIGINT NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- Seed common roles (optional)
INSERT INTO roles (name, description) VALUES
('admin', 'Full access'),
('clinician', 'Clinical workflows: cases, notes, meds'),
('frontdesk', 'Scheduling and patient intake'),
('billing', 'Invoices, payments, claims')
ON CONFLICT (name) DO NOTHING;


-- =========================
-- INSURANCE
-- =========================

CREATE TABLE payers (
  payer_id       BIGSERIAL PRIMARY KEY,
  name           TEXT NOT NULL UNIQUE,
  phone          TEXT,
  address        TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE insurance_policies (
  policy_id      BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  payer_id       BIGINT NOT NULL REFERENCES payers(payer_id) ON DELETE RESTRICT,
  member_id      TEXT NOT NULL,
  group_number   TEXT,
  plan_name      TEXT,
  relationship   TEXT DEFAULT 'self',         -- self/spouse/dependent
  effective_from DATE,
  effective_to   DATE,
  is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One primary policy per patient (simple rule)
CREATE UNIQUE INDEX insurance_one_primary_policy
  ON insurance_policies(patient_id)
  WHERE is_primary;

CREATE INDEX insurance_patient_idx ON insurance_policies(patient_id);
CREATE INDEX insurance_payer_idx ON insurance_policies(payer_id);


-- =========================
-- BILLING CORE (encounters, services, charges)
-- =========================

-- Encounter can align with appointment or case; used as billing container
CREATE TABLE encounters (
  encounter_id   BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  case_id        BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  appointment_id BIGINT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
  provider_id    BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  department_id  BIGINT REFERENCES departments(department_id) ON DELETE SET NULL,
  started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at       TIMESTAMPTZ,
  status         TEXT NOT NULL DEFAULT 'open', -- open/closed/void
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX encounters_patient_idx ON encounters(patient_id, started_at DESC);

-- Catalog of billable services/procedures (keep simple)
CREATE TABLE services (
  service_id     BIGSERIAL PRIMARY KEY,
  code           TEXT NOT NULL UNIQUE,        -- CPT/HCPCS/internal code
  description    TEXT NOT NULL,
  default_price  NUMERIC(12,2) NOT NULL DEFAULT 0,
  taxable        BOOLEAN NOT NULL DEFAULT FALSE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Charge line-items for an encounter
CREATE TABLE charge_items (
  charge_item_id BIGSERIAL PRIMARY KEY,
  encounter_id   BIGINT NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
  service_id     BIGINT REFERENCES services(service_id) ON DELETE SET NULL,
  description    TEXT NOT NULL,               -- snapshot description
  qty            NUMERIC(12,2) NOT NULL DEFAULT 1,
  unit_price     NUMERIC(12,2) NOT NULL DEFAULT 0,
  amount         NUMERIC(12,2) GENERATED ALWAYS AS (qty * unit_price) STORED,
  status         TEXT NOT NULL DEFAULT 'open', -- open/posted/void
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX charge_items_encounter_idx ON charge_items(encounter_id);


-- =========================
-- INVOICES + PAYMENTS
-- =========================

CREATE TABLE invoices (
  invoice_id     BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  encounter_id   BIGINT REFERENCES encounters(encounter_id) ON DELETE SET NULL,
  invoice_number TEXT NOT NULL UNIQUE,
  status         TEXT NOT NULL DEFAULT 'draft', -- draft/issued/paid/void/partial
  issued_at      TIMESTAMPTZ,
  due_at         TIMESTAMPTZ,
  subtotal       NUMERIC(12,2) NOT NULL DEFAULT 0,
  discount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax            NUMERIC(12,2) NOT NULL DEFAULT 0,
  total          NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX invoices_patient_idx ON invoices(patient_id, created_at DESC);
CREATE INDEX invoices_status_idx ON invoices(status);

-- Invoice line-items (usually from charge_items, but kept as snapshot)
CREATE TABLE invoice_items (
  invoice_item_id BIGSERIAL PRIMARY KEY,
  invoice_id      BIGINT NOT NULL REFERENCES invoices(invoice_id) ON DELETE CASCADE,
  charge_item_id  BIGINT REFERENCES charge_items(charge_item_id) ON DELETE SET NULL,
  description     TEXT NOT NULL,
  qty             NUMERIC(12,2) NOT NULL DEFAULT 1,
  unit_price      NUMERIC(12,2) NOT NULL DEFAULT 0,
  amount          NUMERIC(12,2) GENERATED ALWAYS AS (qty * unit_price) STORED,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX invoice_items_invoice_idx ON invoice_items(invoice_id);

CREATE TABLE payments (
  payment_id     BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  invoice_id     BIGINT REFERENCES invoices(invoice_id) ON DELETE SET NULL,
  amount         NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
  method         TEXT NOT NULL,               -- cash/card/ach/check/insurance
  reference      TEXT,                        -- txn id, check number, etc.
  received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     BIGINT REFERENCES users(user_id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX payments_invoice_idx ON payments(invoice_id);
CREATE INDEX payments_patient_idx ON payments(patient_id, received_at DESC);


-- =========================
-- CLAIMS (very simplified)
-- =========================

CREATE TABLE claims (
  claim_id       BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  policy_id      BIGINT REFERENCES insurance_policies(policy_id) ON DELETE SET NULL,
  encounter_id   BIGINT REFERENCES encounters(encounter_id) ON DELETE SET NULL,
  invoice_id     BIGINT REFERENCES invoices(invoice_id) ON DELETE SET NULL,
  status         TEXT NOT NULL DEFAULT 'created', -- created/submitted/accepted/denied/paid/closed
  submitted_at   TIMESTAMPTZ,
  payer_claim_id TEXT,
  total_billed   NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_paid     NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_patient_responsibility NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX claims_patient_idx ON claims(patient_id, created_at DESC);
CREATE INDEX claims_status_idx ON claims(status);

CREATE TABLE claim_items (
  claim_item_id  BIGSERIAL PRIMARY KEY,
  claim_id       BIGINT NOT NULL REFERENCES claims(claim_id) ON DELETE CASCADE,
  invoice_item_id BIGINT REFERENCES invoice_items(invoice_item_id) ON DELETE SET NULL,
  service_code   TEXT,
  description    TEXT,
  qty            NUMERIC(12,2) NOT NULL DEFAULT 1,
  unit_price     NUMERIC(12,2) NOT NULL DEFAULT 0,
  billed_amount  NUMERIC(12,2) GENERATED ALWAYS AS (qty * unit_price) STORED,
  allowed_amount NUMERIC(12,2),
  paid_amount    NUMERIC(12,2),
  status         TEXT NOT NULL DEFAULT 'pending', -- pending/paid/denied
  denial_reason  TEXT
);

CREATE INDEX claim_items_claim_idx ON claim_items(claim_id);


-- =========================
-- MEDICATION
-- =========================

-- Medication catalog (could later be RxNorm-backed)
CREATE TABLE medications (
  medication_id  BIGSERIAL PRIMARY KEY,
  name           TEXT NOT NULL,
  generic_name   TEXT,
  form           TEXT,                        -- tablet/capsule/solution
  strength       TEXT,                        -- 10 mg, 5 mg/5 mL
  route          TEXT,                        -- oral/iv/topical
  code           TEXT,                        -- NDC/RxNorm/internal
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX medications_name_idx ON medications(name);

-- Patient prescriptions
CREATE TABLE prescriptions (
  prescription_id BIGSERIAL PRIMARY KEY,
  patient_id      BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  case_id         BIGINT REFERENCES cases(case_id) ON DELETE SET NULL,
  encounter_id    BIGINT REFERENCES encounters(encounter_id) ON DELETE SET NULL,
  prescribing_provider_id BIGINT REFERENCES providers(provider_id) ON DELETE SET NULL,
  medication_id   BIGINT REFERENCES medications(medication_id) ON DELETE SET NULL,
  medication_text TEXT NOT NULL,              -- snapshot name/strength in case catalog changes
  sig             TEXT NOT NULL,              -- directions (e.g., "1 tab PO BID")
  quantity        NUMERIC(12,2),
  refills_allowed INT NOT NULL DEFAULT 0 CHECK (refills_allowed >= 0),
  start_date      DATE,
  end_date        DATE,
  status          TEXT NOT NULL DEFAULT 'active', -- active/discontinued/completed
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX prescriptions_patient_idx ON prescriptions(patient_id, created_at DESC);
CREATE INDEX prescriptions_status_idx ON prescriptions(status);

-- Track dispense/refills
CREATE TABLE prescription_dispenses (
  dispense_id     BIGSERIAL PRIMARY KEY,
  prescription_id BIGINT NOT NULL REFERENCES prescriptions(prescription_id) ON DELETE CASCADE,
  dispensed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  quantity        NUMERIC(12,2),
  pharmacy_name   TEXT,
  pharmacy_phone  TEXT,
  reference       TEXT
);

CREATE INDEX dispenses_rx_idx ON prescription_dispenses(prescription_id, dispensed_at DESC);

-- Optional: allergies (handy for meds)
CREATE TABLE allergies (
  allergy_id     BIGSERIAL PRIMARY KEY,
  patient_id     BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
  substance      TEXT NOT NULL,              -- penicillin, latex, peanuts
  reaction       TEXT,
  severity       TEXT,                       -- mild/moderate/severe
  noted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX allergies_patient_idx ON allergies(patient_id);


-- =========================
-- (Optional) SIMPLE AUDIT for CRM actions
-- =========================
CREATE TABLE audit_log (
  audit_id       BIGSERIAL PRIMARY KEY,
  actor_user_id  BIGINT REFERENCES users(user_id) ON DELETE SET NULL,
  entity_type    TEXT NOT NULL,              -- patients, invoices, prescriptions, etc.
  entity_id      TEXT NOT NULL,              -- store as text for flexibility
  action         TEXT NOT NULL,              -- create/update/delete/login
  details        JSONB,
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_entity_idx ON audit_log(entity_type, entity_id);
CREATE INDEX audit_actor_time_idx ON audit_log(actor_user_id, occurred_at DESC);
