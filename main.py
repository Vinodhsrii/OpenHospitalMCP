from __future__ import annotations

import os
import re
from datetime import datetime, date
from typing import Any, Dict, List, Optional

import psycopg
from psycopg.rows import dict_row
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("Hospital_CRM")

DATABASE_URL = os.environ.get("DATABASE_URL")
DB_SCHEMA = os.environ.get("DB_SCHEMA", "hospital_crm")  # your SQL uses this schema by default

_ident_re = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")


def _validate_ident(name: str) -> str:
    if not _ident_re.match(name):
        raise ValueError(f"Invalid identifier: {name}")
    return name


def _schema() -> str:
    return _validate_ident(DB_SCHEMA)


def get_conn() -> psycopg.Connection:
    if not DATABASE_URL:
        raise RuntimeError(
            "DATABASE_URL not set. Example:\n"
            'export DATABASE_URL="postgresql://postgres:admin@localhost:5432/demoHospitalDb"'
        )
    return psycopg.connect(DATABASE_URL, autocommit=True)


def _q_table(table: str) -> str:
    # Safe identifier interpolation after validation
    s = _schema()
    t = _validate_ident(table)
    return f'"{s}"."{t}"'

def _parse_date(value: Optional[str]) -> Optional[date]:
    if value is None or value == "":
        return None
    # Accept YYYY-MM-DD
    return date.fromisoformat(value)

def _parse_ts(value: str) -> str:
    """
    Keep it simple:
    - Postgres happily accepts ISO timestamps as strings
    - e.g. '2026-01-25T10:30:00-06:00' or '2026-01-25 10:30:00'
    """
    if not value or not value.strip():
        raise ValueError("timestamp is required")
    return value.strip()


# -------------------- Basic health / discovery --------------------

@mcp.tool()
def db_health() -> str:
    """Check DB connectivity and schema visibility."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("select 1;")
        cur.fetchone()
        # confirm schema exists
        cur.execute("select exists(select 1 from information_schema.schemata where schema_name=%s);", (_schema(),))
        ok = cur.fetchone()[0]
    return "OK" if ok else f"Connected, but schema '{_schema()}' not found"


@mcp.tool()
def list_tables() -> List[str]:
    """List tables in the configured schema (DB_SCHEMA)."""
    s = _schema()
    q = """
    select table_name
    from information_schema.tables
    where table_schema=%s and table_type='BASE TABLE'
    order by table_name;
    """
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(q, (s,))
        return [r[0] for r in cur.fetchall()]


# -------------------- Patients --------------------

@mcp.tool()
def search_patients(
    name: Optional[str] = None,
    mrn: Optional[str] = None,
    limit: int = 20,
) -> List[Dict[str, Any]]:
    """
    Search patients by name (first/last) and/or MRN.
    """
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    clauses = []
    params: List[Any] = []

    if mrn:
        clauses.append("mrn = %s")
        params.append(mrn)

    if name:
        clauses.append("(first_name ILIKE %s OR last_name ILIKE %s)")
        like = f"%{name}%"
        params.extend([like, like])

    where = (" where " + " and ".join(clauses)) if clauses else ""
    q = f"""
    select patient_id, mrn, first_name, last_name, dob, sex, phone, email, status, created_at
    from {_q_table("patients")}
    {where}
    order by last_name, first_name
    limit %s
    """
    params.append(limit)

    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, params)
        return cur.fetchall()


@mcp.tool()
def get_patient(patient_id: int) -> Dict[str, Any]:
    """Get a patient plus primary fields."""
    q = f"""
    select *
    from {_q_table("patients")}
    where patient_id = %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id,))
        row = cur.fetchone()
    return row or {"error": "patient not found"}


@mcp.tool()
def get_patient_contacts(patient_id: int) -> List[Dict[str, Any]]:
    """Get a patient’s contacts (guardian/spouse/caregiver)."""
    q = f"""
    select contact_id, relationship, full_name, phone, email, is_primary, created_at
    from {_q_table("patient_contacts")}
    where patient_id = %s
    order by is_primary desc, created_at desc
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id,))
        return cur.fetchall()


# -------------------- Appointments / Providers --------------------

@mcp.tool()
def upcoming_appointments_for_patient(patient_id: int, days: int = 30, limit: int = 50) -> List[Dict[str, Any]]:
    """Upcoming appointments for a patient."""
    if days < 1 or days > 365:
        raise ValueError("days must be between 1 and 365")
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    q = f"""
    select
      a.appointment_id,
      a.starts_at,
      a.ends_at,
      a.status,
      a.reason,
      a.location,
      a.case_id,
      p.provider_id,
      p.first_name as provider_first_name,
      p.last_name as provider_last_name,
      d.name as department_name
    from {_q_table("appointments")} a
    left join {_q_table("providers")} p on p.provider_id = a.provider_id
    left join {_q_table("departments")} d on d.department_id = a.department_id
    where a.patient_id = %s
      and a.starts_at >= now()
      and a.starts_at < (now() + (%s || ' days')::interval)
    order by a.starts_at asc
    limit %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id, days, limit))
        return cur.fetchall()


@mcp.tool()
def upcoming_appointments_for_provider(provider_id: int, days: int = 7, limit: int = 100) -> List[Dict[str, Any]]:
    """Upcoming appointments for a provider."""
    if days < 1 or days > 365:
        raise ValueError("days must be between 1 and 365")
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    q = f"""
    select
      a.appointment_id,
      a.starts_at,
      a.ends_at,
      a.status,
      a.reason,
      a.location,
      a.patient_id,
      pt.first_name as patient_first_name,
      pt.last_name as patient_last_name,
      d.name as department_name
    from {_q_table("appointments")} a
    left join {_q_table("patients")} pt on pt.patient_id = a.patient_id
    left join {_q_table("departments")} d on d.department_id = a.department_id
    where a.provider_id = %s
      and a.starts_at >= now()
      and a.starts_at < (now() + (%s || ' days')::interval)
    order by a.starts_at asc
    limit %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (provider_id, days, limit))
        return cur.fetchall()


# -------------------- Case timeline (notes, tasks, communications, encounters) --------------------

@mcp.tool()
def patient_case_timeline(patient_id: int, limit_per_type: int = 25) -> Dict[str, Any]:
    """
    Return a compact timeline snapshot across:
    - cases
    - encounters
    - notes
    - tasks
    - communications
    """
    if limit_per_type < 1 or limit_per_type > 200:
        raise ValueError("limit_per_type must be between 1 and 200")

    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        # cases
        cur.execute(
            f"""
            select case_id, status, priority, chief_complaint, diagnosis, opened_at, closed_at, provider_id, department_id
            from {_q_table("cases")}
            where patient_id = %s
            order by opened_at desc nulls last
            limit %s
            """,
            (patient_id, limit_per_type),
        )
        cases = cur.fetchall()

        # encounters
        cur.execute(
            f"""
            select encounter_id, case_id, started_at, ended_at, encounter_type, location, status
            from {_q_table("encounters")}
            where patient_id = %s
            order by started_at desc nulls last
            limit %s
            """,
            (patient_id, limit_per_type),
        )
        encounters = cur.fetchall()

        # notes
        cur.execute(
            f"""
            select note_id, case_id, appointment_id, created_at, note_type, title
            from {_q_table("notes")}
            where patient_id = %s
            order by created_at desc
            limit %s
            """,
            (patient_id, limit_per_type),
        )
        notes = cur.fetchall()

        # tasks
        cur.execute(
            f"""
            select task_id, case_id, due_at, status, priority, title, assigned_provider_id, created_at
            from {_q_table("tasks")}
            where patient_id = %s
            order by created_at desc
            limit %s
            """,
            (patient_id, limit_per_type),
        )
        tasks = cur.fetchall()

        # communications
        cur.execute(
            f"""
            select communication_id, case_id, appointment_id, created_at, channel, direction, subject, status
            from {_q_table("communications")}
            where patient_id = %s
            order by created_at desc
            limit %s
            """,
            (patient_id, limit_per_type),
        )
        communications = cur.fetchall()

    return {
        "patient_id": patient_id,
        "cases": cases,
        "encounters": encounters,
        "notes": notes,
        "tasks": tasks,
        "communications": communications,
    }


# -------------------- Billing (invoices/payments/claims) --------------------

@mcp.tool()
def outstanding_invoices(patient_id: int, limit: int = 50) -> List[Dict[str, Any]]:
    """Invoices for a patient that are not fully paid."""
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    q = f"""
    select
      i.invoice_id,
      i.status,
      i.issued_at,
      i.due_at,
      i.total_amount,
      coalesce(paid.paid_amount, 0) as paid_amount,
      (i.total_amount - coalesce(paid.paid_amount, 0)) as balance
    from {_q_table("invoices")} i
    left join (
      select invoice_id, sum(amount) as paid_amount
      from {_q_table("payments")}
      group by invoice_id
    ) paid on paid.invoice_id = i.invoice_id
    where i.patient_id = %s
      and (i.total_amount - coalesce(paid.paid_amount, 0)) > 0
    order by i.due_at asc nulls last, i.issued_at desc
    limit %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id, limit))
        return cur.fetchall()


@mcp.tool()
def claim_status_for_patient(patient_id: int, limit: int = 50) -> List[Dict[str, Any]]:
    """Recent claims and their statuses for a patient."""
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    q = f"""
    select
      c.claim_id,
      c.status,
      c.submitted_at,
      c.updated_at,
      c.payer_id,
      py.name as payer_name,
      c.total_claim_amount
    from {_q_table("claims")} c
    left join {_q_table("payers")} py on py.payer_id = c.payer_id
    where c.patient_id = %s
    order by c.updated_at desc nulls last, c.submitted_at desc nulls last
    limit %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id, limit))
        return cur.fetchall()


# -------------------- Pharmacy / allergies --------------------

@mcp.tool()
def allergies_for_patient(patient_id: int) -> List[Dict[str, Any]]:
    """Allergies for a patient."""
    q = f"""
    select allergy_id, allergen, reaction, severity, noted_at, status
    from {_q_table("allergies")}
    where patient_id = %s
    order by noted_at desc nulls last
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id,))
        return cur.fetchall()


@mcp.tool()
def active_prescriptions(patient_id: int, limit: int = 50) -> List[Dict[str, Any]]:
    """Active prescriptions joined with medication names."""
    if limit < 1 or limit > 200:
        raise ValueError("limit must be between 1 and 200")

    q = f"""
    select
      pr.prescription_id,
      pr.status,
      pr.start_date,
      pr.end_date,
      pr.dosage_instructions,
      m.medication_id,
      m.name as medication_name
    from {_q_table("prescriptions")} pr
    left join {_q_table("medications")} m on m.medication_id = pr.medication_id
    where pr.patient_id = %s
      and pr.status = 'active'
    order by pr.start_date desc nulls last
    limit %s
    """
    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(q, (patient_id, limit))
        return cur.fetchall()


# -------------------- CREATE: patients --------------------

@mcp.tool()
def create_patient(
    first_name: str,
    last_name: str,
    mrn: Optional[str] = None,
    dob: Optional[str] = None,          # YYYY-MM-DD
    sex: Optional[str] = None,
    phone: Optional[str] = None,
    email: Optional[str] = None,
    address_line1: Optional[str] = None,
    address_line2: Optional[str] = None,
    city: Optional[str] = None,
    state: Optional[str] = None,
    postal_code: Optional[str] = None,
    country: str = "USA",
    status: str = "active"
) -> Dict[str, Any]:
    """
    Insert a new patient into hospital_crm.patients.
    Returns the created patient record (key fields).
    """
    if not first_name or not first_name.strip():
        raise ValueError("first_name is required")
    if not last_name or not last_name.strip():
        raise ValueError("last_name is required")

    dob_val = _parse_date(dob)

    q = f"""
    INSERT INTO {_q_table("patients")}
      (mrn, first_name, last_name, dob, sex, phone, email,
       address_line1, address_line2, city, state, postal_code, country, status,
       created_at, updated_at)
    VALUES
      (%s, %s, %s, %s, %s, %s, %s,
       %s, %s, %s, %s, %s, %s, %s,
       now(), now())
    RETURNING
      patient_id, mrn, first_name, last_name, dob, sex, phone, email, status, created_at;
    """

    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            q,
            (
                mrn, first_name.strip(), last_name.strip(), dob_val, sex, phone, email,
                address_line1, address_line2, city, state, postal_code, country, status
            ),
        )
        return cur.fetchone()


# -------------------- CREATE: appointments --------------------

@mcp.tool()
def create_appointment(
    patient_id: int,
    starts_at: str,                      # ISO string; required
    ends_at: Optional[str] = None,       # ISO string; optional
    provider_id: Optional[int] = None,
    department_id: Optional[int] = None,
    case_id: Optional[int] = None,
    status: str = "scheduled",
    reason: Optional[str] = None,
    location: Optional[str] = None
) -> Dict[str, Any]:
    """
    Insert a new appointment into hospital_crm.appointments.
    starts_at is required. ends_at optional.
    """
    if not patient_id:
        raise ValueError("patient_id is required")

    starts_at_val = _parse_ts(starts_at)
    ends_at_val = _parse_ts(ends_at) if ends_at else None

    q = f"""
    INSERT INTO {_q_table("appointments")}
      (patient_id, provider_id, department_id, case_id,
       starts_at, ends_at, status, reason, location, created_at)
    VALUES
      (%s, %s, %s, %s,
       %s, %s, %s, %s, %s, now())
    RETURNING
      appointment_id, patient_id, provider_id, department_id, case_id,
      starts_at, ends_at, status, reason, location, created_at;
    """

    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            q,
            (
                patient_id, provider_id, department_id, case_id,
                starts_at_val, ends_at_val, status, reason, location
            ),
        )
        return cur.fetchone()


# -------------------- CREATE: notes --------------------

@mcp.tool()
def create_note(
    patient_id: int,
    body: str,
    note_type: str = "general",
    case_id: Optional[int] = None,
    appointment_id: Optional[int] = None,
    author_provider_id: Optional[int] = None
) -> Dict[str, Any]:
    """
    Insert a new note into hospital_crm.notes.
    patient_id and body are required.
    """
    if not patient_id:
        raise ValueError("patient_id is required")
    if not body or not body.strip():
        raise ValueError("body is required")

    q = f"""
    INSERT INTO {_q_table("notes")}
      (patient_id, case_id, appointment_id, author_provider_id,
       note_type, body, created_at)
    VALUES
      (%s, %s, %s, %s,
       %s, %s, now())
    RETURNING
      note_id, patient_id, case_id, appointment_id, author_provider_id,
      note_type, created_at;
    """

    with get_conn() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            q,
            (patient_id, case_id, appointment_id, author_provider_id, note_type, body.strip()),
        )
        return cur.fetchone()

# -------------------- Resource: quick summary --------------------

@mcp.resource("hospitalcrm://summary")
def hospital_summary() -> str:
    """Simple resource summary for the agent."""
    return (
        f"Hospital CRM MCP connected to schema '{_schema()}'. "
        f"Time: {datetime.now().isoformat()}. "
        "Use tools: search_patients, get_patient, get_patient_contacts, "
        "upcoming_appointments_for_patient, upcoming_appointments_for_provider, "
        "patient_case_timeline, outstanding_invoices, claim_status_for_patient, "
        "allergies_for_patient, active_prescriptions."
    )
