-- Une phrase peut porter deux trous, et le joueur pose alors deux cartes.

-- Deux trous au maximum, au lieu d'un seul.
create or replace function public._clean_card(p_kind text, p_text text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare t text; n int;
begin
  t := regexp_replace(trim(coalesce(p_text, '')), '\s+', ' ', 'g');
  if p_kind = 'q' then
    t := regexp_replace(t, '_{2,}', '____', 'g');
    if length(t) < 5 then raise exception 'La phrase est trop courte.'; end if;
    if length(t) > 150 then raise exception 'La phrase dépasse 150 caractères.'; end if;
    n := (length(t) - length(replace(t, '____', ''))) / 4;
    if n = 0 then raise exception 'Ajoute un trou « ____ » à l''endroit de la réponse.'; end if;
    if n > 2 then raise exception 'Une phrase ne peut pas contenir plus de deux trous.'; end if;
  else
    t := regexp_replace(t, '[.]+$', '');
    if length(t) < 1 then raise exception 'La réponse est vide.'; end if;
    if length(t) > 80 then raise exception 'La réponse dépasse 80 caractères.'; end if;
    if position('____' in t) > 0 then raise exception 'Une réponse ne contient pas de trou.'; end if;
  end if;
  return t;
end
$$;
revoke all on function public._clean_card(text, text) from public, anon, authenticated;

alter table public.questions add column if not exists blanks integer
  generated always as ((length(text) - length(replace(text, '____', ''))) / 4) stored;

-- La seconde carte d'une réponse à deux trous. Nulle sur une phrase à un trou.
alter table public.submissions add column if not exists answer_id2 integer references public.answers(id);
alter table public.submissions drop constraint if exists submissions_distinct_answers;
alter table public.submissions add constraint submissions_distinct_answers
  check (answer_id2 is null or answer_id2 <> answer_id);
create index if not exists submissions_answer2_idx on public.submissions(answer_id2);

-- Le nombre de cartes attendues est celui des trous de la phrase, jamais un
-- choix du client : deux cartes sur une phrase à un trou en gaspilleraient une.
create or replace function public.submit_answer(p_code text, p_token uuid, p_answer_id integer, p_answer_id2 integer default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare me public.players; r public.rooms; n int;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'answering' then raise exception 'Les réponses sont fermées pour ce tour.'; end if;
  if r.reader_id = me.id then raise exception 'Tu lis la question ce tour-ci.'; end if;
  if exists(select 1 from public.submissions where room_id = r.id and round = r.round and player_id = me.id)
    then raise exception 'Tu as déjà joué une carte.'; end if;

  select blanks into n from public.questions where id = r.question_id;
  n := coalesce(n, 1);
  if n = 1 and p_answer_id2 is not null then raise exception 'Cette phrase n''a qu''un trou.'; end if;
  if n = 2 and p_answer_id2 is null then raise exception 'Cette phrase a deux trous : choisis deux cartes.'; end if;
  if p_answer_id2 = p_answer_id then raise exception 'Choisis deux cartes différentes.'; end if;

  if not exists(select 1 from public.hands where player_id = me.id and answer_id = p_answer_id)
    then raise exception 'Cette carte n''est pas dans ta main.'; end if;
  if p_answer_id2 is not null
     and not exists(select 1 from public.hands where player_id = me.id and answer_id = p_answer_id2)
    then raise exception 'Cette carte n''est pas dans ta main.'; end if;

  insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
  values (r.id, r.round, me.id, p_answer_id, p_answer_id2);
  delete from public.hands where player_id = me.id and answer_id in (p_answer_id, p_answer_id2);

  perform public._deal(r.id);
  perform public._maybe_judge(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end
$$;
grant execute on function public.submit_answer(text,uuid,integer,integer) to anon, authenticated;

-- L'ancienne signature à trois arguments reste, en simple relais. La supprimer
-- casserait net les pages déjà ouvertes au moment de la migration, qui
-- appellent encore submit_answer sans le second trou.
create or replace function public.submit_answer(p_code text, p_token uuid, p_answer_id integer)
returns void
language sql
security invoker
set search_path = ''
as $$ select public.submit_answer(p_code, p_token, p_answer_id, null::integer) $$;
grant execute on function public.submit_answer(text,uuid,integer) to anon, authenticated;

-- Les bots posent autant de cartes que la phrase a de trous.
create or replace function public.bot_step(p_code text, p_token uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;

  if r.status = 'question_select' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      select x into qid from unnest(r.question_choices) x order by random() limit 1;
      update public.rooms set question_id = qid, used_questions = used_questions || qid,
        question_choices = '{}', status = 'answering', updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'answering' then
    select blanks into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    for b in select * from public.players where room_id = r.id and active and is_bot and id <> r.reader_id
             and not exists(select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = players.id) loop
      aid := null; aid2 := null;
      select h.answer_id into aid from public.hands h where h.player_id = b.id order by random() limit 1;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h where h.player_id = b.id and h.answer_id <> aid order by random() limit 1;
      end if;
      -- Une phrase à deux trous et une main d'une seule carte : le bot passe
      -- son tour plutôt que d'insérer une réponse incomplète.
      if aid is not null and (n = 1 or aid2 is not null) then
        insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
        values (r.id, r.round, b.id, aid, aid2) on conflict do nothing;
        delete from public.hands where player_id = b.id and answer_id in (aid, aid2);
      end if;
    end loop;
    perform public._deal(r.id);
    perform public._maybe_judge(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'judging' and exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
    select s.id, s.player_id into sid, b.id from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by random() limit 1;
    if sid is not null then
      update public.players set score = score + 1 where id = b.id returning * into b;
      update public.rooms set status = case when b.score >= r.target_score then 'finished' else 'reveal' end,
        winner_id = b.id, winning_submission_id = sid, updated_at = now() where id = r.id;
    end if;
  end if;
end
$$;
grant execute on function public.bot_step(text,uuid) to anon, authenticated;

-- Un départ en cours de manche rendait les cartes jouées : la seconde aussi.
create or replace function public._return_submissions(p_room uuid, p_round integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.hands(player_id, answer_id, room_id)
  select s.player_id, a, p_room
  from public.submissions s
  join public.players p on p.id = s.player_id and p.active
  cross join lateral unnest(array_remove(array[s.answer_id, s.answer_id2], null)) a
  where s.room_id = p_room and s.round = p_round
  on conflict do nothing;
  delete from public.submissions where room_id = p_room and round = p_round;
end
$$;
revoke all on function public._return_submissions(uuid, integer) from public, anon, authenticated;

create or replace function public._remove_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare pl public.players; r public.rooms; nr uuid;
begin
  select * into pl from public.players where id = p_player;
  if pl.id is null or not pl.active then return; end if;

  select * into r from public.rooms where id = pl.room_id for update;

  update public.players set active = false where id = p_player;
  delete from public.hands where player_id = p_player;

  if r.host_id = p_player then
    update public.rooms
    set host_id = (select id from public.players where room_id = r.id and active order by seat limit 1)
    where id = r.id;
  end if;

  if r.status in ('question_select', 'answering', 'judging', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < 3 then
      if r.status not in ('question_select', 'reveal') then
        perform public._return_submissions(r.id, r.round);
      end if;
      update public.rooms set status = 'lobby', updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      nr := public._random_reader(r.id, p_player);
      if r.status not in ('question_select', 'reveal') then
        perform public._return_submissions(r.id, r.round);
      end if;
      perform public._begin_round(r.id, nr, case when r.status = 'question_select' then r.round else r.round + 1 end);

    elsif r.status in ('answering', 'judging') then
      delete from public.submissions where room_id = r.id and round = r.round and player_id = p_player;
      if r.status = 'judging'
         and not exists (select 1 from public.submissions where room_id = r.id and round = r.round) then
        update public.rooms set status = 'answering', updated_at = now() where id = r.id;
      elsif r.status = 'answering' then
        perform public._maybe_judge(r.id);
      end if;
    end if;
  end if;

  update public.rooms set updated_at = now() where id = r.id;
end
$$;
revoke all on function public._remove_player(uuid) from public, anon, authenticated;

-- Le client a besoin du nombre de trous pour savoir combien de cartes demander,
-- et du texte des deux cartes pour reconstituer la phrase.
create or replace function public.get_state(p_code text,p_token uuid)
returns json language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
 'me',json_build_object('id',me.id,'name',me.name,'ready',me.ready,'next_ack',me.next_ack_round,'continue_requested',me.continue_requested,'can_discard',r.status='answering' and r.reader_id<>me.id and me.discard_round<>r.round and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=me.id)),
 'question',(select q.text from public.questions q where q.id=r.question_id),
 'blanks',coalesce((select q.blanks from public.questions q where q.id=r.question_id),1),
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id)) order by p.seat),'[]'::json) from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
 'hand',(select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'form',a.form) order by a.text),'[]'::json) from public.hands h join public.answers a on a.id=h.answer_id where h.player_id=me.id),
 'my_cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
             from public.submissions s
             cross join lateral unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
             join public.answers a on a.id=x.aid
             where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'submissions',case when r.status in('reveal','finished') or (r.status='judging' and r.reader_id=me.id) then
   (select coalesce(json_agg(json_build_object('id',s.id,'author',case when r.status in('reveal','finished') then p.name end,
      'cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
               from unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
               join public.answers a on a.id=x.aid)) order by s.sort_key),'[]'::json)
    from public.submissions s join public.players p on p.id=s.player_id
    where s.room_id=r.id and s.round=r.round) else '[]'::json end);
end $$;
grant execute on function public.get_state(text,uuid) to anon;

-- Le catalogue des phrases affiche le nombre de trous.
create or replace function public.admin_list_cards(p_password text, p_kind text, p_search text default '', p_offset integer default 0)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare s text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    return json_build_object(
      'total', (select count(*) from public.questions q where q.deleted_at is null and lower(q.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'blanks',x.blanks) order by x.created_at desc, x.id desc),'[]'::json)
                from (select q.id,q.text,q.added_by,q.blanks,q.created_at from public.questions q
                      where q.deleted_at is null and lower(q.text) like s
                      order by q.created_at desc, q.id desc offset greatest(p_offset,0) limit 50) x));
  elsif p_kind = 'a' then
    return json_build_object(
      'total', (select count(*) from public.answers a where a.deleted_at is null and lower(a.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'form',x.form) order by x.created_at desc, x.id desc),'[]'::json)
                from (select a.id,a.text,a.added_by,a.form,a.created_at from public.answers a
                      where a.deleted_at is null and lower(a.text) like s
                      order by a.created_at desc, a.id desc offset greatest(p_offset,0) limit 50) x));
  end if;
  raise exception 'Type de carte inconnu.';
end
$$;
grant execute on function public.admin_list_cards(text,text,text,integer) to anon;
