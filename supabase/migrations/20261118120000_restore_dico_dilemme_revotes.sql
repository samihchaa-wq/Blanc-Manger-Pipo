-- Corrige une régression UX introduite par la migration du 8 novembre :
-- les interfaces Dico et Dilemme permettent de modifier un vote pendant
-- que d'autres joueurs n'ont pas encore répondu. Le serveur doit respecter
-- cette règle jusqu'à la révélation, jamais après.
-- Les validations de cible, de doublons et le verrou du salon sont conservés.
begin;

CREATE OR REPLACE FUNCTION public.dico_vote(p_code text, p_token uuid, p_def uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; d public.dico_defs;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dico' or r.status <> 'dico_vote' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if r.reader_id = me.id then raise exception 'Le meneur ne vote pas.'; end if;
  select * into d from public.dico_defs where id = p_def and room_id = r.id and round = r.round;
  if d.id is null then raise exception 'Définition inconnue.'; end if;
  if d.player_id is not distinct from me.id then raise exception 'Tu ne peux pas voter pour ta propre définition.'; end if;
  insert into public.dico_votes(room_id, round, voter_id, def_id) values (r.id, r.round, me.id, d.id)
    on conflict (room_id, round, voter_id) do update set def_id = excluded.def_id;
  perform public._dico_advance(r.id);
end $function$;

CREATE OR REPLACE FUNCTION public.dilemme_vote(p_code text, p_token uuid, p_buts uuid[], p_yes boolean[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; attendus integer; recus integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dilemme' or r.status <> 'dilemme_vote' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if (select count(distinct x) from unnest(p_buts) as x) <> coalesce(cardinality(p_buts), 0) then
    raise exception 'Une proposition est présente plusieurs fois.';
  end if;
  if coalesce(cardinality(p_buts), 0) <> coalesce(cardinality(p_yes), 0) then raise exception 'Votes incomplets.'; end if;
  if exists (select 1 from unnest(p_yes) y where y is null) then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  if exists (select 1 from unnest(p_buts) x left join public.dilemme_buts b on b.id = x and b.room_id = r.id and b.round = r.round
             where b.id is null) then raise exception 'Proposition inconnue.'; end if;
  if exists (select 1 from public.dilemme_buts b where b.id = any(p_buts) and b.player_id = me.id) then
    raise exception 'Tu ne votes pas pour ta propre proposition.'; end if;
  select count(*) into attendus from public.dilemme_buts b join public.players a on a.id = b.player_id and a.active
    where b.room_id = r.id and b.round = r.round and b.player_id <> me.id;
  select count(distinct x) into recus from unnest(p_buts) x
    join public.dilemme_buts b on b.id = x join public.players a on a.id = b.player_id and a.active;
  if recus < attendus then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  -- Modification autorisée uniquement avant que tout le monde ait fini de voter.
  -- Remplacement atomique et sérialisé par le verrou FOR UPDATE du salon.
  delete from public.dilemme_votes where room_id = r.id and round = r.round and voter_id = me.id;
  insert into public.dilemme_votes(room_id, round, voter_id, but_id, yes)
  select distinct on (x.b) r.id, r.round, me.id, x.b, x.y from unnest(p_buts, p_yes) as x(b, y);
  perform public._dilemme_advance(r.id);
end $function$;

commit;
