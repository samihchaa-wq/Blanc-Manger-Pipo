-- Petit bac : une réponse peut faire 120 caractères (40 auparavant).
create or replace function public.bac_save(p_code text, p_token uuid, p_answers text[], p_done boolean default false)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; a text[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'writing' then raise exception 'Le temps est écoulé.'; end if;
  if cardinality(coalesce(p_answers, '{}')) > 6 then raise exception 'Six réponses au maximum.'; end if;
  select array_agg(left(btrim(regexp_replace(coalesce(p_answers[i], ''), '\s+', ' ', 'g')), 120) order by i)
    into a from generate_series(1, 6) i;

  -- une grille rendue ne bouge plus
  insert into public.bac_answers as b (room_id, round, player_id, answers, done)
  values (r.id, r.round, me.id, a, coalesce(p_done, false))
  on conflict (room_id, round, player_id) do update
    set answers = excluded.answers, done = excluded.done
    where not b.done;

  if coalesce(p_done, false) then
    if not exists (
      select 1 from public.players p where p.room_id = r.id and p.active
        and not exists (select 1 from public.bac_answers b
                        where b.room_id = r.id and b.round = r.round and b.player_id = p.id and b.done)
    ) then
      perform public._bac_start_vote(r.id);
    end if;
    update public.rooms set updated_at = now() where id = r.id;
  end if;
end $function$;

revoke all on function public.bac_save(text, uuid, text[], boolean) from public, anon, authenticated;
grant execute on function public.bac_save(text, uuid, text[], boolean) to anon;
