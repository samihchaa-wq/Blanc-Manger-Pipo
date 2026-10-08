-- Priorités : envoi d'un classement (une seule fois, les 5 cartes, chacune une fois).

create or replace function public.submit_ranking(p_code text, p_token uuid, p_cards integer[])
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'ranking' then raise exception 'Ce n’est pas le moment de classer.'; end if;
  if p_cards is null or cardinality(p_cards) <> cardinality(r.rank_cards)
     or (select count(distinct x) from unnest(p_cards) x) <> cardinality(r.rank_cards)
     or not (p_cards <@ r.rank_cards) then
    raise exception 'Classe les 5 cartes, chacune une seule fois.';
  end if;
  insert into public.rankings(room_id, round, player_id, cards)
  values (r.id, r.round, me.id, p_cards) on conflict do nothing;
  if not found then raise exception 'Ton classement est déjà envoyé.'; end if;
  perform public._maybe_score(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

revoke all on function public.submit_ranking(text, uuid, integer[]) from public, anon, authenticated;
grant execute on function public.submit_ranking(text, uuid, integer[]) to anon;
