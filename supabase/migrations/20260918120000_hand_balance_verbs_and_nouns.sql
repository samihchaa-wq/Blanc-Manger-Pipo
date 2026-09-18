-- Une main mélangeait les formes au hasard : on pouvait tirer six groupes
-- nominaux d'affilée et se retrouver sans rien à jouer sur « on a arrêté de
-- ____ », ou l'inverse sur « Le livreur a laissé ____ devant la porte ».
-- Chaque réponse porte désormais sa forme, et _deal garantit 3 verbes et
-- 3 groupes nominaux par main.

-- Classement automatique d'une réponse.
--
-- L'ordre des règles compte. Un déterminant en tête l'emporte sur la
-- terminaison, sinon « La mère d'un pote » passerait pour un infinitif à cause
-- du « -re » de « mère ». Restent quelques noms propres qui finissent comme un
-- infinitif (« Vladimir Poutine », « Hitler ») : la colonne est modifiable, le
-- classement n'est qu'une valeur par défaut.
create or replace function public._card_form(p_text text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  with w as (
    select lower(pg_catalog.regexp_replace(coalesce(p_text,''), '^([^ ’'']+).*$', '\1')) as mot,
           lower(pg_catalog.regexp_replace(coalesce(p_text,''), '^([^ ’'']+)[’''].*$', '\1')) as elid
  )
  select case
    -- pronominal ou négation : « Se palucher », « S'envoyer en l'air », « Ne pas avoir 500 anecdotes »
    when mot in ('se','ne','pas') or elid in ('s','n') then 'v'
    -- déterminant en tête : groupe nominal
    when mot in ('un','une','des','le','la','les','du','de','mon','ma','mes','ton','ta','tes',
                 'son','sa','ses','notre','nos','votre','vos','leur','leurs',
                 'ce','cet','cette','ces','deux','trois','quatre','moi','toi','lui')
      or elid in ('l','d','c','j','m','t','qu') then 'n'
    -- terminaison d'infinitif
    when mot ~ '(er|ir|re|oir)$' then 'v'
    else 'n' end
  from w
$fn$;
revoke all on function public._card_form(text) from public, anon, authenticated;

alter table public.answers add column if not exists form text;
update public.answers set form = public._card_form(text) where form is null;

-- Les noms propres que la terminaison trompe.
update public.answers set form = 'n'
where form = 'v' and lower(text) in ('vladimir poutine','upamecanoir','hitler','adolf hitler','ben laden');

alter table public.answers alter column form set not null;
alter table public.answers drop constraint if exists answers_form_check;
alter table public.answers add constraint answers_form_check check (form in ('v','n'));
create index if not exists answers_form_idx on public.answers(form) where deleted_at is null;

-- À l'insertion seulement : une forme corrigée à la main n'est jamais réécrite.
create or replace function public._answers_set_form()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.form is null then new.form := public._card_form(new.text); end if;
  return new;
end
$$;
revoke all on function public._answers_set_form() from public, anon, authenticated;

drop trigger if exists answers_set_form on public.answers;
create trigger answers_set_form before insert on public.answers
for each row execute function public._answers_set_form();

-- La distribution vise (hand_size+1)/2 verbes et hand_size/2 groupes nominaux,
-- soit 3 et 3 pour une main de 6.
create or replace function public._deal(p_room uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare pl record; hs int; f text; want int; need int; avail int; reste int;
begin
  select hand_size into hs from public.rooms where id = p_room;
  for pl in select id from public.players where room_id = p_room and active order by seat loop

    foreach f in array array['v','n'] loop
      want := case when f = 'v' then (hs + 1) / 2 else hs / 2 end;
      select want - count(*) into need
        from public.hands h join public.answers a on a.id = h.answer_id
        where h.player_id = pl.id and a.form = f;

      if need > 0 then
        select count(*) into avail from public.answers a
          where a.deleted_at is null and a.form = f
            and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id);

        -- Vivier épuisé : on recycle les réponses de CETTE forme qui ne sont
        -- dans aucune main. Recycler tout le catalogue rendrait aussitôt
        -- rejouables des cartes de l'autre forme encore disponibles.
        if avail < need then
          delete from public.used_answers u
          using public.answers a
          where u.answer_id = a.id and a.form = f and u.room_id = p_room
            and not exists(select 1 from public.hands h where h.room_id = p_room and h.answer_id = u.answer_id);
        end if;

        insert into public.hands(player_id, answer_id, room_id)
        select pl.id, a.id, p_room from public.answers a
          where a.deleted_at is null and a.form = f
            and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)
          order by random() limit need;
      end if;
    end loop;

    -- Filet de sécurité : si une forme manque dans tout le catalogue, la main
    -- se complète avec l'autre plutôt que de rester incomplète.
    select hs - count(*) into reste from public.hands where player_id = pl.id;
    if reste > 0 then
      insert into public.hands(player_id, answer_id, room_id)
      select pl.id, a.id, p_room from public.answers a
        where a.deleted_at is null
          and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)
          and not exists(select 1 from public.hands h where h.player_id = pl.id and h.answer_id = a.id)
        order by random() limit reste;
    end if;

    insert into public.used_answers(room_id, answer_id)
    select p_room, h.answer_id from public.hands h where h.player_id = pl.id
    on conflict do nothing;
  end loop;
end
$$;
revoke all on function public._deal(uuid) from public, anon, authenticated;

-- Le catalogue affiche la forme et permet de la corriger.
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
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by) order by x.created_at desc, x.id desc),'[]'::json)
                from (select q.id,q.text,q.added_by,q.created_at from public.questions q
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

create or replace function public.admin_set_card_form(p_password text, p_id integer, p_form text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_form not in ('v','n') then raise exception 'Forme inconnue.'; end if;
  update public.answers set form = p_form where id = p_id and deleted_at is null;
  if not found then raise exception 'Carte introuvable.'; end if;
end
$$;
grant execute on function public.admin_set_card_form(text,integer,text) to anon;

-- La forme part aussi au client : sans elle, impossible de savoir si l'on peut
-- abaisser l'initiale d'une réponse insérée en milieu de phrase. « Un Ricard
-- tiède » le permet, « Hitler » non, et les deux commencent par une majuscule.
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
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id)) order by p.seat),'[]'::json) from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
 'hand',(select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'form',a.form) order by a.text),'[]'::json) from public.hands h join public.answers a on a.id=h.answer_id where h.player_id=me.id),
 'my_submission',(select a.text from public.submissions s join public.answers a on a.id=s.answer_id where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'my_submission_form',(select a.form from public.submissions s join public.answers a on a.id=s.answer_id where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'submissions',case when r.status in('reveal','finished') or (r.status='judging' and r.reader_id=me.id) then (select coalesce(json_agg(json_build_object('id',s.id,'text',a.text,'form',a.form,'author',case when r.status in('reveal','finished') then p.name end) order by s.sort_key),'[]'::json) from public.submissions s join public.answers a on a.id=s.answer_id join public.players p on p.id=s.player_id where s.room_id=r.id and s.round=r.round) else '[]'::json end);
end $$;
grant execute on function public.get_state(text,uuid) to anon;
