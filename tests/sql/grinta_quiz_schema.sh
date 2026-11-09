#!/usr/bin/env bash
# Isolated PostgreSQL rehearsal for the one-night AS Grinta quiz.
# Replays the three event migrations and executes rollback-only QA tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=as_grinta_quiz_qa
if [ -n "${PSQL:-}" ]; then
  run() { $PSQL "$@"; }
else
  C="${1:?PostgreSQL Docker container ID required}"
  run() { docker exec -i "$C" psql -U postgres "$@"; }
fi
sql() { run -d "$DB" -v ON_ERROR_STOP=1 -q "$@"; }
run -d postgres -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
sql < tests/sql/supabase_env.sql
sql < supabase/migrations/20261122120000_as_grinta_quiz_2026.sql
sql < supabase/migrations/20261122130000_as_grinta_quiz_late_entry_guard.sql
sql < supabase/migrations/20261122140000_as_grinta_quiz_preflight_guard.sql
sql < tests/sql/grinta_admin_plus_stub.sql
sql < supabase/migrations/20261122160000_grinta_quiz_admin_plus_entry.sql
sql < supabase/tests/qa_as_grinta_admin_plus_entry.sql
sql < supabase/tests/qa_as_grinta_quiz_2026.sql
echo "ASGQ_QA: scenario transactionnel OK (deux mi-temps, sécurité et podium)."
