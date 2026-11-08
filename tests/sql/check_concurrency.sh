#!/usr/bin/env bash
# Véritables sessions PostgreSQL indépendantes : même joueur qui revote et
# joueurs distincts votant exactement au même moment, avec FOR UPDATE réel.
# Les fonctions Dico/Dilemme sont celles des migrations de production.
# Les fonctions d'avancement sont des stubs CI : ce test prouve l'atomicité des
# votes, pas le calcul de score ni la montée en charge de Supabase.
set -euo pipefail
CID="${1:?ID du conteneur PostgreSQL manquant}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

psql_ci() {
  docker exec "$CID" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

for wave in 1 2 3 4; do
  jobs=()
  queries=()
  if ((wave % 2)); then
    DA="'40000000-0000-4000-8000-000000000001'"
    DB="'40000000-0000-4000-8000-000000000002'"
    YES="ARRAY[true,true]"
  else
    DA="'40000000-0000-4000-8000-000000000003'"
    DB="'40000000-0000-4000-8000-000000000001'"
    YES="ARRAY[false,false]"
  fi
  queries+=("select public.dico_vote('88000001','30000000-0000-4000-8000-000000000002',$DA)")
  queries+=("select public.dico_vote('88000001','30000000-0000-4000-8000-000000000003',$DB)")
  queries+=("select public.dico_vote('88000001','30000000-0000-4000-8000-000000000002',$DA)")
  queries+=("select public.dilemme_vote('88000002','30000000-0000-4000-8000-000000000005',ARRAY['50000000-0000-4000-8000-000000000001'::uuid,'50000000-0000-4000-8000-000000000003'::uuid],$YES)")
  queries+=("select public.dilemme_vote('88000002','30000000-0000-4000-8000-000000000006',ARRAY['50000000-0000-4000-8000-000000000001'::uuid,'50000000-0000-4000-8000-000000000002'::uuid],$YES)")
  queries+=("select public.dilemme_vote('88000002','30000000-0000-4000-8000-000000000005',ARRAY['50000000-0000-4000-8000-000000000001'::uuid,'50000000-0000-4000-8000-000000000003'::uuid],$YES)")

  for idx in "${!queries[@]}"; do
    (
      psql_ci -q -c "begin; ${queries[$idx]}; select pg_sleep(0.12); commit;" \
        >"$TMP/wave${wave}_${idx}.log" 2>&1
    ) &
    jobs+=("$!")
  done
  failed=0
  for jid in "${jobs[@]}"; do wait "$jid" || failed=1; done
  if ((failed)); then
    cat "$TMP"/wave"$wave"_*.log
    echo "ECHEC : une ou plusieurs RPC simultanées ont été refusées"
    exit 1
  fi
  echo "Vague $wave/4 : 6 connexions PostgreSQL parallèles terminées"
done

psql_ci -q <<'SQL'
do $verify$
declare n integer;
begin
  select count(*) into n from public.dico_votes
   where room_id='10000000-0000-4000-8000-000000000001';
  if n<>2 then raise exception 'Dico : % votes au lieu de 2',n; end if;
  if exists(select 1 from public.dico_votes where room_id='10000000-0000-4000-8000-000000000001'
    group by voter_id having count(*)<>1) then
    raise exception 'Dico : votes simultanés dupliqués';
  end if;
  select count(*) into n from public.dilemme_votes
   where room_id='10000000-0000-4000-8000-000000000002';
  if n<>4 then raise exception 'Dilemme : % réponses au lieu de 4',n; end if;
  if exists(select 1 from public.dilemme_votes
    where room_id='10000000-0000-4000-8000-000000000002'
    group by voter_id having count(*)<>2 or count(distinct yes)<>1) then
    raise exception 'Dilemme : un revote concurrent a fusionné deux réponses';
  end if;
  if (select count(*) from public.rooms
       where code in('88000001','88000002') and status in('dico_vote','dilemme_vote'))<>2 then
    raise exception 'Les deux salons de test ont été altérés';
  end if;
end $verify$;
SQL

echo "POSTGRESQL OK : 24 appels concurrents sur deux salons, sans doublon ni mélange."
