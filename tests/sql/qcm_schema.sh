#!/usr/bin/env bash
# QCM de bout en bout sur un vrai PostgreSQL. Dans une base neuve : rôles et
# extensions de Supabase, toutes les migrations du dépôt dans l'ordre, les
# fonctions dont l'historique du dépôt diverge de la production, la migration
# du QCM, puis son scénario et ceux des jeux existants (tous annulés à la fin).
#   CI     : bash tests/sql/qcm_schema.sh <id du conteneur postgres>
#   local  : PSQL="psql -h <socket> -p <port> -U postgres" bash tests/sql/qcm_schema.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=qcm_qa
if [ -n "${PSQL:-}" ]; then run() { $PSQL "$@"; }
else C="${1:?id du conteneur postgres}"; run() { docker exec -i "$C" psql -U postgres "$@"; }; fi
sql() { run -d "$DB" -q -v ON_ERROR_STOP=1 "$@"; }

run -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
sql < tests/sql/supabase_env.sql
for f in supabase/migrations/*.sql; do
  case "$(basename "$f")" in
    # Jamais appliquée en production (création de salon d'une ancienne époque).
    20261031150000_petit_bac_manches_reglables.sql) continue;;
    20261121120000_qcm.sql) continue;;
  esac
  sql < "$f" > /dev/null 2>&1 || { echo "Échec du rejeu : $f"; sql < "$f" 2>&1 | grep -m3 ERROR; exit 1; }
done
sql < supabase/seed.sql > /dev/null
sql < tests/sql/prod_overrides.sql
sql < supabase/migrations/20261121120000_qcm.sql > /dev/null
echo "Migration du QCM appliquée ; elle peut être rejouée :"
sql < supabase/migrations/20261121120000_qcm.sql 2>/dev/null | tail -n 3
sql < supabase/tests/qa_qcm_scenario.sql 2>&1 | grep -E 'QCM_QA'
# Les autres jeux n'ont pas bougé : leurs scénarios multijoueurs passent toujours.
for t in qa_multiplayer_core_modes qa_multiplayer_bac_mimes qa_multiplayer_dico_dilemme qa_multiplayer_white \
         qa_multiplayer_resilience qa_multiplayer_timeouts qa_multiplayer_capacity security_rpc_permissions_scenario; do
  sql < "supabase/tests/$t.sql" > /dev/null 2>&1 || { echo "Régression : $t"; sql < "supabase/tests/$t.sql" 2>&1 | grep -m3 ERROR; exit 1; }
  echo "OK $t"
done
