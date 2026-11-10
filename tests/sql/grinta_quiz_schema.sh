#!/usr/bin/env bash
# Isolated PostgreSQL rehearsal for the one-night AS Grinta quiz.
# Replays all event migrations, including reveal-only participant outcomes, and runs rollback-only QA tests.
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
sql < supabase/migrations/20261122170000_grinta_quiz_create_and_join.sql
sql < supabase/migrations/20261122171000_grinta_quiz_shared_wifi_limits.sql
sql < supabase/tests/qa_as_grinta_admin_plus_entry.sql
sql < supabase/migrations/20261122180000_as_grinta_real_bot_rehearsal.sql
sql < supabase/migrations/20261122190000_as_grinta_manual_lobby_20_provisional.sql
sql < supabase/migrations/20261122191000_asgq_remove_bot_before_kickoff.sql
sql < supabase/migrations/20261122192000_asgq_reuse_bot_numbers.sql
sql < supabase/migrations/20261122200000_asgq_host_manual_control.sql
sql < supabase/migrations/20261123010000_asgq_reveal_player_outcomes.sql
sql < supabase/migrations/20261123020000_asgq_waiting_names_and_room_mode.sql
sql < supabase/migrations/20261123030000_asgq_host_session_recovery.sql
sql < supabase/migrations/20261123040000_asgq_player_session_handoff.sql
sql < supabase/tests/qa_as_grinta_host_recovery.sql
sql < supabase/tests/qa_as_grinta_player_handoff.sql
sql < supabase/tests/qa_as_grinta_quiz_2026.sql
sql < supabase/tests/qa_as_grinta_real_bots.sql

# End-to-end test of the actual private question-pack SQL against an official
# event that already has its (single) creator. The database is disposable CI.
IMPORT_QA_DIR=$(mktemp -d)
trap 'rm -rf "$IMPORT_QA_DIR"' EXIT
node --input-type=module - "$IMPORT_QA_DIR/questions.json" <<'NODE'
import fs from 'node:fs';
const q=(half,i)=>({
  texte:'Question CI de la mi-temps '+half+' numéro '+(i+1)+' ?',
  choix:['Première option','Deuxième option','Troisième option','Quatrième option'],
  bonne_reponse:i%4,
  points:1,
  explication:'Donnée de vérification non officielle.'
});
fs.writeFileSync(process.argv[2],JSON.stringify({
  as_grinta:Array.from({length:10},(_,i)=>q(1,i)),
  football_general:Array.from({length:10},(_,i)=>q(2,i))
}));
NODE
node tools/asgq-question-pack.mjs "$IMPORT_QA_DIR/questions.json" "$IMPORT_QA_DIR/import.sql"
sql <<'SQL'
DO $qa$ BEGIN
  PERFORM public.asgq_create('CI-TEST-ONLY-PASSWORD','Animateur');
  IF (SELECT count(*) FROM asgq_private.players)<>1 THEN
    RAISE EXCEPTION 'IMPORT_QA: creator not registered';
  END IF;
END $qa$;
SQL
sql < "$IMPORT_QA_DIR/import.sql"
sql <<'SQL'
DO $qa$ BEGIN
  IF (SELECT count(*) FROM asgq_private.questions)<>20 OR
      NOT asgq_private.ready_for_kickoff() OR
      (SELECT armed FROM asgq_private.event WHERE id=1) THEN
    RAISE EXCEPTION 'IMPORT_QA: the valid host-only import failed or armed event';
  END IF;
  PERFORM public.asgq_join_room(
    (SELECT room_code FROM asgq_private.event WHERE id=1),'Invité');
END $qa$;
SQL
if sql < "$IMPORT_QA_DIR/import.sql"; then
  echo 'IMPORT_QA: unsafe reimport with an invited player unexpectedly succeeded' >&2
  exit 1
fi
sql <<'SQL'
DO $qa$ BEGIN
  IF (SELECT count(*) FROM asgq_private.questions)<>20 OR
      (SELECT count(*) FROM asgq_private.players)<>2 OR
      (SELECT armed FROM asgq_private.event WHERE id=1) OR
      (SELECT phase FROM asgq_private.event WHERE id=1)<>'lobby' THEN
    RAISE EXCEPTION 'IMPORT_QA: rejected import modified live game state';
  END IF;
END $qa$;
SQL
echo 'IMPORT_QA: host-only import OK; invited-player reimport denied; event left unarmed.'
echo "ASGQ_QA: scenario transactionnel OK (deux mi-temps, sécurité et podium)."
