-- Priorités : tirage des 5 cartes de la manche, au moins 2 verbes et 2 noms quand c'est possible.

create or replace function public._draw_rank_cards(p_room uuid)
 returns integer[] language plpgsql security definer set search_path to '' as $function$
declare picked integer[];
begin
  if (select count(*) from public.answers a
      where a.deleted_at is null
        and not exists (select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)) < 5 then
    delete from public.used_answers where room_id = p_room;
  end if;

  with dispo as (
    select a.id, row_number() over (partition by a.form order by random()) as rk
    from public.answers a
    where a.deleted_at is null
      and not exists (select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)
  )
  select array_agg(x.id order by random()) into picked
  from (select d.id from dispo d order by (d.rk <= 2) desc, random() limit 5) x;

  insert into public.used_answers(room_id, answer_id)
  select p_room, unnest(picked) on conflict do nothing;
  return picked;
end $function$;

revoke all on function public._draw_rank_cards(uuid) from public, anon, authenticated;
