-- Dilemme : deux modes de partie, au choix de l'hôte dans le salon.
--   « 50/50 »    : chacun vise toujours 50 % de Oui (à un nombre impair de
--                  votants, la moitié tombe entre deux : les deux comptent juste,
--                  le barème retire déjà l'écart minimal atteignable).
--   « Aléatoire » : cible tirée entre 1 et « votants − 1 » Oui (comportement actuel).
--
-- Ajoute rooms.dilemme_variant, la RPC set_dilemme_variant, et remplace
-- _dilemme_set_start (tirage selon le mode) et get_state (room.dilemme_variant).

-- À coller tel quel dans l'éditeur SQL de Supabase : une seule transaction,
-- inscrite dans l'historique supabase_migrations.
begin;

alter table public.rooms add column if not exists dilemme_variant text not null default 'aleatoire';
alter table public.rooms drop constraint if exists rooms_dilemme_variant_check;
alter table public.rooms add constraint rooms_dilemme_variant_check check (dilemme_variant in ('moitie','aleatoire'));

create or replace function public.set_dilemme_variant(p_code text, p_token uuid, p_variant text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le mode.'; end if;
  if r.status <> 'lobby' then raise exception 'Le mode se choisit depuis le salon.'; end if;
  if r.mode <> 'dilemme' then raise exception 'Ce réglage est propre au Dilemme.'; end if;
  if p_variant is null or p_variant not in ('moitie','aleatoire') then raise exception 'Mode inconnu.'; end if;
  update public.rooms set dilemme_variant = p_variant, updated_at = now() where id = r.id;
end $fn$;

-- Le meneur a posé le début : chaque joueur actif reçoit sa cible secrète.
create or replace function public._dilemme_set_start(p_room uuid, p_start text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; n integer;
  s text := left(regexp_replace(trim(coalesce(p_start, '')), '\s+', ' ', 'g'), 140);
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'dilemme_pick' then raise exception 'Le dilemme est déjà posé.'; end if;
  -- « mais » final et points de suspension : l'appli les ajoute elle-même
  s := trim(regexp_replace(s, '[\s,.…]*(mais)?[\s,.…]*$', '', 'i'));
  if length(s) < 5 then raise exception 'Écris le début du dilemme.'; end if;
  delete from public.dilemme_cibles where room_id = r.id;
  -- votants = joueurs actifs sauf l'auteur
  select count(*) - 1 into n from public.players where room_id = r.id and active;
  if r.dilemme_variant = 'moitie' then
    -- 50/50 : 50 % pour tous ; target_yes = moitié arrondie en dessous (l'appli
    -- affiche « 1 ou 2 Oui sur 3 » quand les votants sont impairs)
    insert into public.dilemme_cibles(room_id, round, player_id, target, target_yes, voters)
    select r.id, r.round, p.id, 50, greatest(n, 0) / 2, n
      from public.players p where p.room_id = r.id and p.active;
  else
    -- Aléatoire : entre 1 et votants − 1 Oui, jamais un pourcentage impossible
    insert into public.dilemme_cibles(room_id, round, player_id, target, target_yes, voters)
    select r.id, r.round, p.id, round(100.0 * k / greatest(n, 1))::integer, k, n
      from (select p.id, case when n >= 2 then 1 + floor(random() * (n - 1))::integer else n end as k
              from public.players p where p.room_id = r.id and p.active) p;
  end if;
  update public.rooms set dilemme_start = s, status = 'dilemme_write',
    phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

create or replace function public.get_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; base jsonb; extra jsonb := '{}'::jsonb; fin boolean;
begin
  base := public._get_state_base(p_code, p_token)::jsonb;
  me := public._player(p_code, p_token);
  select * into r from public.rooms where id = me.room_id;
  base := jsonb_set(base, '{room,time_mode}', to_jsonb(r.time_mode));
  base := jsonb_set(base, '{room,mime_index}', to_jsonb(r.mime_index));
  base := jsonb_set(base, '{room,mime_started_at}', coalesce(to_jsonb(r.mime_started_at), 'null'::jsonb));
  base := jsonb_set(base, '{room,phase_seconds}', coalesce(to_jsonb(public._time_phase_seconds(r)), 'null'::jsonb));
  base := jsonb_set(base, '{room,phase_deadline}', coalesce(to_jsonb(
    case when r.status = 'mime_play' then
      case when r.mime_index between 1 and (select count(*) from public.mime_parts where room_id=r.id and round=r.round)
        and r.mime_started_at is not null and public._time_phase_seconds(r) is not null
        then r.mime_started_at + make_interval(secs => public._time_phase_seconds(r)) end
    else
      case when public._time_phase_seconds(r) is not null
        then r.phase_at + make_interval(secs => public._time_phase_seconds(r)) end
    end), 'null'::jsonb));
  base := jsonb_set(base, '{room,wave_variant}', to_jsonb(r.wave_variant));
  base := jsonb_set(base, '{room,dilemme_variant}', to_jsonb(r.dilemme_variant));
  if base->'wave' is not null and jsonb_typeof(base->'wave') = 'object' then
    base := jsonb_set(base, '{wave}', (base->'wave') || jsonb_build_object(
      'variant', r.wave_variant, 'theme', r.wave_theme, 'asker_id', r.wave_asker));
  end if;
  if r.mode = 'mimes' and r.status in ('mime_play','reveal','finished') and r.mime_card is not null then
    extra := jsonb_build_object('mime', jsonb_build_object(
      'action', (select c.action from public.mime_cards c where c.id = r.mime_card),
      'low', (select c.low_text from public.mime_cards c where c.id = r.mime_card),
      'high', (select c.high_text from public.mime_cards c where c.id = r.mime_card),
      'mine', (select m.intensity from public.mime_parts m where m.room_id = r.id and m.round = r.round and m.player_id = me.id),
      -- ordre de passage : les sièges à partir du juge (le juge en tête, sans intensité)
      'parts', (select coalesce(jsonb_agg(jsonb_build_object('player_id', m.player_id,
          'intensity', case when r.status in ('reveal','finished') then m.intensity end,
          'guess', case when r.status in ('reveal','finished') then m.guess end,
          'points', case when r.status in ('reveal','finished') then m.points end)
          order by (p.seat - coalesce(jp.seat, 0) + 10000) % 10000), '[]'::jsonb)
        from public.mime_parts m
        join public.players p on p.id = m.player_id and p.active
        left join public.players jp on jp.id = r.reader_id
        where m.room_id = r.id and m.round = r.round)));
  end if;
  if r.mode = 'dico' and r.status in ('dico_pick','dico_write','dico_vote','reveal','finished') and r.round > 0 then
    fin := r.status in ('reveal','finished');
    extra := extra || jsonb_build_object('dico', jsonb_build_object(
      'word', r.dico_word, 'nature', r.dico_nature,
      'definition', case when fin or r.reader_id = me.id then r.dico_def end,
      'mine', (select d.text from public.dico_defs d where d.room_id = r.id and d.round = r.round and d.player_id = me.id),
      'written', (select coalesce(jsonb_agg(d.player_id), '[]'::jsonb) from public.dico_defs d
                   join public.players p on p.id = d.player_id and p.active
                   where d.room_id = r.id and d.round = r.round and not d.is_true),
      'voted', (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dico_votes v
                 join public.players p on p.id = v.voter_id and p.active
                 where v.room_id = r.id and v.round = r.round),
      'my_vote', (select v.def_id from public.dico_votes v where v.room_id = r.id and v.round = r.round and v.voter_id = me.id),
      'defs', case when r.status in ('dico_vote','reveal','finished') then
        (select coalesce(jsonb_agg(jsonb_build_object(
            'id', d.id, 'text', d.text, 'mine', d.player_id = me.id,
            'is_true', case when fin then d.is_true end,
            'author_id', case when fin then d.player_id end,
            'voters', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dico_votes v
                                           where v.def_id = d.id) end)
          order by d.sort_key), '[]'::jsonb)
         from public.dico_defs d left join public.players p on p.id = d.player_id
         where d.room_id = r.id and d.round = r.round and (d.player_id is null or p.active)) end,
      'points', case when fin then
        (select coalesce(jsonb_agg(jsonb_build_object('player_id', x.player_id, 'points', x.points)), '[]'::jsonb)
         from public.dico_points x where x.room_id = r.id and x.round = r.round) end));
  end if;
  if r.mode = 'dilemme' and r.status in ('dilemme_pick','dilemme_write','dilemme_vote','reveal','finished') and r.round > 0 then
    fin := r.status in ('reveal','finished');
    extra := extra || jsonb_build_object('dilemme', jsonb_build_object(
      'start', r.dilemme_start,
      -- sa propre cible, connue de lui seul jusqu'à la révélation
      'my_target', (select jsonb_build_object('pct', t.target, 'yes', t.target_yes, 'voters', t.voters)
                     from public.dilemme_cibles t where t.room_id = r.id and t.round = r.round and t.player_id = me.id),
      'mine', (select b.text from public.dilemme_buts b where b.room_id = r.id and b.round = r.round and b.player_id = me.id),
      'written', (select coalesce(jsonb_agg(b.player_id), '[]'::jsonb) from public.dilemme_buts b
                   join public.players p on p.id = b.player_id and p.active
                   where b.room_id = r.id and b.round = r.round),
      'voted', case when r.status = 'dilemme_vote' then to_jsonb(public._dilemme_voters_done(r.id, r.round)) else '[]'::jsonb end,
      'buts', case when r.status in ('dilemme_vote','reveal','finished') then
        (select coalesce(jsonb_agg(jsonb_build_object(
            'id', b.id, 'text', b.text, 'mine', b.player_id = me.id,
            'my_vote', (select v.yes from public.dilemme_votes v where v.but_id = b.id and v.voter_id = me.id),
            'author_id', case when fin then b.player_id end,
            'target', case when fin then (select jsonb_build_object('pct', t.target, 'yes', t.target_yes, 'voters', t.voters)
                        from public.dilemme_cibles t
                        where t.room_id = r.id and t.round = r.round and t.player_id = b.player_id) end,
            'yes', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dilemme_votes v
                     join public.players q on q.id = v.voter_id and q.active where v.but_id = b.id and v.yes) end,
            'no', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dilemme_votes v
                    join public.players q on q.id = v.voter_id and q.active where v.but_id = b.id and not v.yes) end,
            'points', case when fin then (select x.points from public.dilemme_points x
                        where x.room_id = r.id and x.round = r.round and x.player_id = b.player_id) end)
          order by b.sort_key), '[]'::jsonb)
         from public.dilemme_buts b join public.players p on p.id = b.player_id and p.active
         where b.room_id = r.id and b.round = r.round) end,
      'points', case when fin then
        (select coalesce(jsonb_agg(jsonb_build_object('player_id', x.player_id, 'points', x.points)), '[]'::jsonb)
         from public.dilemme_points x where x.room_id = r.id and x.round = r.round) end));
  end if;
  return (base || extra)::json;
end $fn$;

revoke execute on function public._dilemme_set_start(uuid,text) from public, anon, authenticated;
revoke execute on function public.set_dilemme_variant(text,uuid,text) from public;
grant execute on function public.set_dilemme_variant(text,uuid,text) to anon, authenticated;

do $hist$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261110120000') then
      insert into supabase_migrations.schema_migrations(version, name) values ('20261110120000', 'dilemme_modes');
    end if;
  end if;
end $hist$;

commit;

select 'Dilemme : modes 50/50 et Aléatoire.' as resultat;
