# Hospital CRM MCP Server (Claude Desktop + Local Postgres)

A **simple Custom MCP Server** that lets a Claude Desktop client query and create basic hospital CRM data (patients, appointments, notes, billing snapshots, etc.) stored in a **local PostgreSQL database**.

This repo uses `FastMCP` with the server name **Hospital_CRM**. :contentReference[oaicite:0]{index=0}

---

## Use case

You want an LLM client (Claude Desktop) to safely perform **read + limited write actions** against a local hospital database:

- Find patients by name/MRN
- Pull patient details + contacts
- View upcoming appointments (patient/provider)
- Get a compact “case timeline” snapshot (cases, encounters, notes, tasks, communications)
- View billing/claims snapshot (outstanding invoices, claim statuses)
- View allergies + active prescriptions
- Create new **patients**, **appointments**, and **notes**

---

## High-level architecture

- **Claude Desktop (client)** calls MCP tools exposed by this server
- **MCP Server (Python)** connects to **PostgreSQL** using `DATABASE_URL`
- All queries run under a configurable schema (default `hospital_crm`) via `DB_SCHEMA` :contentReference[oaicite:1]{index=1}

---

## Requirements

### System
- Python **3.10+** :contentReference[oaicite:2]{index=2}
- PostgreSQL (local install or Docker)
- A database + schema containing the expected hospital tables (see “Database setup”)

### Python dependencies
Defined in `pyproject.toml`: :contentReference[oaicite:3]{index=3}
- `mcp[cli]>=1.26.0`
- `psycopg[binary]>=3.2.0`
- `pydantic[email]>=2.12.5`
- `python-dotenv>=1.2.1`

---

## Repo contents (key files)

- `main.py` — MCP server implementation exposing tools and one resource :contentReference[oaicite:4]{index=4}
- `pyproject.toml` — dependencies and Python version requirement :contentReference[oaicite:5]{index=5}
- `uv.lock` — pinned dependency resolution (for reproducible installs)

---

## Replicating on another machine (quick checklist)

Install Python 3.10+ and uv

Install/start PostgreSQL

Create DB + schema + tables (matching the server’s queries)

Clone/copy this repo

uv sync

Set DATABASE_URL and (optionally) DB_SCHEMA

uv run python main.py

Add server to Claude Desktop MCP config and test with db_health

## Environment variables

Set these before running the server:


### `DATABASE_URL` (required)
Connection string for Postgres. The server will fail fast if not set and even provides an example format: :contentReference[oaicite:6]{index=6}

Example:
```bash
export DATABASE_URL="postgresql://postgres:<password>@localhost:5432/<dbSchema>"


