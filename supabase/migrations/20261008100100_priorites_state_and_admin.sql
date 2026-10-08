-- Priorités : l'état lit les cartes dans le paquet complet ; l'admin gère un troisième catalogue.

-- ---------- État ----------
create or replace function public.get_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'mode',r.mode,'turns',r.judge_turns,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'phase_at',r.phase_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
 'me',json_build_object('id',me.id,'name',me.name,'ready',me.ready,'next_ack',me.next_ack_round,'continue_requested',me.continue_requested,'can_discard',r.status='answering' and r.reader_id<>me.id and me.discard_round<>r.round and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=me.id)),
 'question',(select q.text from public.questions q where q.id=r.question_id),
 'blanks',coalesce((select q.blanks from public.questions q where q.id=r.question_id),1),
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'judge_count',p.judge_count,
    'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id),
    'ranked',exists(select 1 from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=p.id)) order by p.seat),'[]'::json)
   from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
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
    where s.room_id=r.id and s.round=r.round) else '[]'::json end,
 'rank_cards',case when r.mode='priorites' and r.status in('ranking','reveal','finished') then
   (select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'kind',a.kind) order by x.i),'[]'::json)
    from unnest(r.rank_cards) with ordinality as x(aid,i) join public._rank_pool(true) a on a.id=x.aid) else '[]'::json end,
 'my_ranking',(select k.cards from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=me.id),
 'rankings',case when r.mode='priorites' and r.status in('reveal','finished') then
   (select coalesce(json_agg(json_build_object('player_id',k.player_id,'cards',k.cards,'points',k.points)),'[]'::json)
    from public.rankings k where k.room_id=r.id and k.round=r.round) else '[]'::json end);
end $function$;

-- ---------- Admin : troisième catalogue « Priorités » ----------
create or replace function public.admin_add_card(p_password text, p_kind text, p_text text)
 returns json language plpgsql security definer set search_path to '' as $function$
declare t text;
begin
  if not public._is_admin(p_password) then
    raise exception 'Mot de passe incorrect.';
  end if;
  if p_kind = 'q' then
    return public.add_question(p_text, 'admin');
  end if;
  if p_kind = 'a' then
    return public.add_answer(p_text, 'admin');
  end if;
  if p_kind = 'p' then
    t := public._clean_card('a', p_text);
    if exists (select 1 from public.priority_cards c where lower(c.text) = lower(t) and c.deleted_at is null) then
      raise exception 'Cette carte existe déjà.';
    end if;
    insert into public.priority_cards(text, theme, added_by) values (t, 'perso', 'admin')
      on conflict (lower(text)) do update set deleted_at = null, added_by = 'admin';
    return json_build_object('text', t, 'total', (select count(*) from public.priority_cards where deleted_at is null));
  end if;
  raise exception 'Type de carte inconnu.';
end
$function$;

create or replace function public.admin_list_cards(p_password text, p_kind text, p_search text default '', p_offset integer default 0)
 returns json language plpgsql security definer set search_path to '' as $function$
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
  elsif p_kind = 'p' then
    return json_build_object(
      'total', (select count(*) from public.priority_cards c where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'theme',x.theme) order by x.created_at desc, x.id desc),'[]'::json)
                from (select c.id,c.text,c.added_by,c.theme,c.created_at from public.priority_cards c
                      where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)
                      order by c.created_at desc, c.id desc offset greatest(p_offset,0) limit 50) x));
  end if;
  raise exception 'Type de carte inconnu.';
end
$function$;

create or replace function public.admin_delete_card(p_password text, p_kind text, p_id integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare rm uuid;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind='q' then
    update public.questions set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
  elsif p_kind='a' then
    update public.answers set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
    for rm in select distinct room_id from public.hands where answer_id=p_id loop
      delete from public.hands where room_id=rm and answer_id=p_id; perform public._deal(rm); update public.rooms set updated_at=now() where id=rm;
    end loop;
  elsif p_kind='p' then
    update public.priority_cards set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
  else raise exception 'Type de carte inconnu.'; end if;
end $function$;

create or replace function public.admin_update_card(p_password text, p_kind text, p_id integer, p_text text)
 returns json language plpgsql security definer set search_path to '' as $function$
declare t text;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  t:=public._clean_card(case when p_kind='p' then 'a' else p_kind end,p_text);
  if p_kind='q' then
    if exists(select 1 from public.questions q where lower(q.text)=lower(t) and q.id<>p_id) then raise exception 'Une autre question a déjà ce texte.'; end if;
    update public.questions set text=t where id=p_id and deleted_at is null;
  elsif p_kind='a' then
    if exists(select 1 from public.answers a where lower(a.text)=lower(t) and a.id<>p_id) then raise exception 'Une autre réponse a déjà ce texte.'; end if;
    update public.answers set text=t where id=p_id and deleted_at is null;
  elsif p_kind='p' then
    if exists(select 1 from public.priority_cards c where lower(c.text)=lower(t) and c.id<>p_id) then raise exception 'Une autre carte a déjà ce texte.'; end if;
    update public.priority_cards set text=t where id=p_id and deleted_at is null;
  else raise exception 'Type de carte inconnu.'; end if;
  if not found then raise exception 'Carte introuvable.'; end if;
  return json_build_object('id',p_id,'text',t);
end $function$;

create or replace function public.card_counts()
 returns json language sql stable security definer set search_path to '' as $function$
  select json_build_object(
    'questions', (select count(*) from public.questions where deleted_at is null),
    'answers', (select count(*) from public.answers where deleted_at is null),
    'priorites', (select count(*) from public.priority_cards where deleted_at is null))
$function$;

revoke all on function public.get_state(text, uuid) from public, anon, authenticated;
grant execute on function public.get_state(text, uuid) to anon;
revoke all on function public.admin_add_card(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_add_card(text, text, text) to anon;
revoke all on function public.admin_list_cards(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.admin_list_cards(text, text, text, integer) to anon;
revoke all on function public.admin_delete_card(text, text, integer) from public, anon, authenticated;
grant execute on function public.admin_delete_card(text, text, integer) to anon;
revoke all on function public.admin_update_card(text, text, integer, text) from public, anon, authenticated;
grant execute on function public.admin_update_card(text, text, integer, text) to anon;
revoke all on function public.card_counts() from public, anon, authenticated;
grant execute on function public.card_counts() to anon;
