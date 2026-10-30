-- Priorités : l'écran du classement reste 2 min (les autres modes gardent 5 s).
create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; pl record; n integer; aid integer; aid2 integer; sid uuid; delai interval;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.id is null then return; end if;
  delai := case when r.status = 'reveal' then (case when r.mode = 'priorites' then interval '120 seconds' else interval '5 seconds' end)
                when r.status = 'writing' then interval '123 seconds'
                else interval '120 seconds' end;
  if now() - r.phase_at < delai then return; end if;

  if r.status = 'question_select' then
    -- la première carte proposée, dans l'ordre où le lecteur les voit
    if cardinality(r.question_choices) > 0 then
      perform public.select_question(r.code, (select token from public.players where id = r.reader_id),
                                     r.question_choices[1]);
    end if;

  elsif r.status = 'answering' then
    select coalesce(blanks, 1) into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    -- les premières cartes de la main, dans l'ordre où elle s'affiche
    for pl in
      select p.id, p.token from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = p.id)
      order by p.seat
    loop
      select h.answer_id into aid from public.hands h join public.answers a on a.id = h.answer_id
        where h.player_id = pl.id order by a.text, a.id limit 1;
      aid2 := null;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h join public.answers a on a.id = h.answer_id
          where h.player_id = pl.id and h.answer_id <> aid order by a.text, a.id limit 1;
      end if;
      if aid is not null and (n = 1 or aid2 is not null) then
        perform public.submit_answer(r.code, pl.token, aid, aid2);
      end if;
    end loop;

  elsif r.status = 'judging' then
    -- la première réponse lue par le lecteur gagne le point
    select s.id into sid from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by s.sort_key limit 1;
    if sid is not null then
      perform public.pick_winner(r.code, (select token from public.players where id = r.reader_id), sid);
    end if;

  elsif r.status = 'ranking' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active
        and not exists (select 1 from public.rankings k where k.room_id = r.id and k.round = r.round and k.player_id = p.id)
      order by p.seat
    loop
      perform public.submit_ranking(r.code, pl.token,
        (select array_agg(x order by random()) from unnest(r.rank_cards) x));
    end loop;

  elsif r.status = 'clue' then
    perform public.submit_clue(r.code, (select token from public.players where id = r.reader_id), 'Sans texte');

  elsif r.status = 'guessing' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.wave_guesses g where g.room_id = r.id and g.round = r.round and g.player_id = p.id)
      order by p.seat
    loop
      perform public.submit_guess(r.code, pl.token, 50);
    end loop;

  elsif r.status = 'naming' then
    if exists (select 1 from public.players where id = r.reader_id and active) then
      perform public.bac_category(r.code, (select token from public.players where id = r.reader_id),
                                  public._bac_default_category(r.id));
    end if;

  elsif r.status = 'writing' then
    perform public._bac_start_vote(r.id);

  elsif r.status = 'voting' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active
        and exists (select 1 from public.bac_answers b
                    join public.players o on o.id = b.player_id and o.active
                    where b.room_id = r.id and b.round = r.round and b.player_id <> p.id
                      and b.points[r.bac_step + 1] is null)
      order by p.seat
    loop
      perform public.bac_vote(r.code, pl.token, 2);
    end loop;

  elsif r.status = 'reveal' then
    perform public._begin_round(r.id, public._next_reader(r.id, r.reader_id), r.round + 1);
  end if;
end $function$;

revoke all on function public.reap_idle(text, uuid) from public, anon, authenticated;
grant execute on function public.reap_idle(text, uuid) to anon;
