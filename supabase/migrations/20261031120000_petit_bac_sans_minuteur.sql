-- Petit bac : aucune notion de temps.
-- reap_idle (minuteur des phases) ne touche plus aux salles de Petit bac :
-- l'écriture, les votes et l'écran de résultat attendent les joueurs.
-- Le passage à la manche suivante se fait par next_round (un accusé par joueur).
-- Les autres modes gardent exactement leur comportement.
alter function public.reap_idle(text, uuid) rename to _reap_idle_timed;
revoke all on function public._reap_idle_timed(text, uuid) from public, anon, authenticated;

create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; m text;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select mode into m from public.rooms where id = me.room_id;
  if m = 'bac' then return; end if;
  perform public._reap_idle_timed(p_code, p_token);
end $function$;

revoke all on function public.reap_idle(text, uuid) from public, anon, authenticated;
grant execute on function public.reap_idle(text, uuid) to anon;
