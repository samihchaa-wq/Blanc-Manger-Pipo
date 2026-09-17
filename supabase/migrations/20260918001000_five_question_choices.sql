-- Le lecteur choisissait parmi 4 cartes à trou, on passe à 5.
-- Note : _question_choices n'existait dans aucune migration du dépôt, elle
-- n'avait été appliquée que sur la base. Cette version repart de celle qui
-- tournait en production.
create or replace function public._question_choices(p_room uuid)
returns integer[]
language plpgsql
security definer
set search_path = ''
as $$
declare ids integer[]; used integer[];
begin
  select used_questions into used from public.rooms where id=p_room;
  select coalesce(array_agg(id),'{}') into ids from (select id from public.questions where deleted_at is null and not(id=any(used)) order by random() limit 5) q;
  if cardinality(ids)<5 then
    select coalesce(array_agg(id),'{}') into ids from (select id from public.questions where deleted_at is null order by random() limit 5) q;
  end if;
  if cardinality(ids)<1 then raise exception 'Aucune carte à trou disponible.'; end if;
  return ids;
end $$;
