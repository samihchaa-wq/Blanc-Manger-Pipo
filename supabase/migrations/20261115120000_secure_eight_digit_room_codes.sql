-- Les nouveaux salons reçoivent des codes à 8 chiffres imprévisibles.
-- Les anciens codes à 4 chiffres ne changent pas : aucun salon en cours cassé.
-- On utilise un UUID cryptographiquement aléatoire ; le rejet du débordement
-- supprime le biais dû au modulo 100 000 000 (2^32 / 100M = 42 + reste).
begin;

create or replace function public._new_code()
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  code_candidate text;
  raw_random bigint;
  attempt integer;
begin
  for attempt in 1..64 loop
    raw_random := ('x' || substr(replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint;

    -- 42 tranches complètes de 100 millions pour un tirage uniforme.
    if raw_random >= 4200000000 then continue; end if;
    code_candidate := pg_catalog.lpad((raw_random % 100000000)::text, 8, '0');

    if not exists(select 1 from public.rooms where code = code_candidate) then
      return code_candidate;
    end if;
  end loop;
  raise exception 'Impossible de générer un code de partie. Réessaie.';
end
$function$;

-- Seules les fonctions du backend doivent pouvoir générer un code.
revoke all on function public._new_code() from public, anon, authenticated;

commit;
