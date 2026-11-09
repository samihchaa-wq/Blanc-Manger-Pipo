-- On-night quiz remains protected: only the separate rehearsal schema is changed.
-- True multiplayer test: host adds bots individually and presses Lancer, like other Soulieteur games.
alter table asgq_rehearsal_private.event
  add column if not exists host_token_hash text,
  add column if not exists manual_started boolean not null default false;

create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_rehearsal_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  -- Disarm/correct the event without a countdown accidentally surviving.
  if ev.phase = 'lobby' and ev.starts_at is not null
     and (not ev.armed or not asgq_rehearsal_private.ready_for_kickoff()) then
    update asgq_rehearsal_private.event set starts_at=null, phase_started_at=null where id=1;
    select * into ev from asgq_rehearsal_private.event where id=1;
  end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_rehearsal_private.players;
    if player_total >= ev.min_players and ev.manual_started and ev.created and ev.armed and asgq_rehearsal_private.ready_for_kickoff() then
      update asgq_rehearsal_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_rehearsal_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    -- Bots are REAL server participants. Their answers use the same table,
    -- deadlines, scoring transition and leaderboard as human answers.
    if ev.phase = 'question' and ev.phase_started_at is not null then
      select * into question_row from asgq_rehearsal_private.questions
        where position = ev.current_position;
      if question_row.id is not null then
        insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
        select p.id, question_row.id,
          case when mod(question_row.position * 17 + p.bot_order * 7, 10) < 6
               then question_row.correct_index
               else mod(question_row.correct_index + 1 +
                        mod(p.bot_order,cardinality(question_row.choices)-1),
                        cardinality(question_row.choices))
          end,
          ev.phase_started_at + make_interval(secs => 2 + mod(p.bot_order * 3, 21))
        from asgq_rehearsal_private.players p
        where p.bot_order is not null
          and ev.phase_started_at + make_interval(secs => 2 + mod(p.bot_order * 3, 21))
            <= least(clock_timestamp(),ev.phase_until)
        on conflict (player_id,question_id) do nothing;
      end if;
    end if;
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_rehearsal_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_rehearsal_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_rehearsal_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_rehearsal_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_rehearsal_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_rehearsal_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_rehearsal_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_rehearsal_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_rehearsal_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_rehearsal_private.event where id=1;
  end loop;
end $fn$;

create or replace function public.asgq_rehearsal_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  my_answer asgq_rehearsal_private.answers%rowtype;
  show_result boolean;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  perform asgq_rehearsal_private.tick();
  select * into ev from asgq_rehearsal_private.event where id=1;
  select count(*) into n from asgq_rehearsal_private.questions;
  select count(*) into first_half from asgq_rehearsal_private.questions where half=1;
  select count(*) into second_half from asgq_rehearsal_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'is_bot',(p.bot_order is not null)) order by p.joined_at), '[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', asgq_rehearsal_private.ready_for_kickoff(), 'room_code', ev.room_code, 'is_host', (ev.host_token_hash=player_row.token_hash), 'max_players', ev.max_players, 'title', ev.title, 'now',clock_timestamp(),
    'starts_at',ev.starts_at,'phase_started_at',ev.phase_started_at,'phase_until',ev.phase_until,
    'position',ordinal, 'total',n, 'first_half_count',first_half, 'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people, 'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,
      'score',(select score from asgq_rehearsal_private.players where id=player_row.id)),
    'question', case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when show_result then q.correct_index else null end,
        'explanation',case when show_result then q.explanation else null end,
        'my_choice',my_answer.choice,'earned',case when show_result then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

-- A re-created rehearsal begins with just its host, not an automatic countdown.
create or replace function public.asgq_rehearsal_create(
 p_password text, p_name text, p_bots integer default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  invite_secret text;
  joined jsonb;
  public_code text;
  i integer;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe Admin+ incorrect.'; end if;
  if p_bots is null or p_bots < 0 or p_bots > 20 then raise exception 'Nombre de bots non autorisé.'; end if;
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if not found then raise exception 'Répétition indisponible.'; end if;
  if ev.phase not in ('lobby','finished') then raise exception 'Une répétition est en cours.'; end if;
  delete from asgq_rehearsal_private.players where event_id=1;
  delete from asgq_rehearsal_private.join_attempts where client_hash is not null;
  public_code := asgq_rehearsal_private.new_room_code();
  update asgq_rehearsal_private.event
    set created=true,armed=true,room_code=public_code,
        phase='lobby',phase_started_at=null,phase_until=null,starts_at=null,
        current_position=0,manual_started=false,host_token_hash=null,
        intro_seconds=7, question_seconds=25, reveal_seconds=9, halftime_seconds=40
    where id=1;
  select plaintext_code into invite_secret from asgq_rehearsal_private.invitation where event_id=1;
  if invite_secret is null then raise exception 'Partie indisponible.'; end if;
  joined := public.asgq_rehearsal_join(invite_secret,p_name,null);
  update asgq_rehearsal_private.event set host_token_hash =
    pg_catalog.encode(extensions.digest('asgq-token:'||(joined->>'token'),'sha256'),'hex')
    where id=1;
  for i in 1..p_bots loop
    insert into asgq_rehearsal_private.players(event_id,name,token_hash,bot_order)
    values (1,'Bot '||pg_catalog.lpad(i::text,2,'0'),
      pg_catalog.encode(extensions.digest('asgq-rehearsal-bot:'||pg_catalog.gen_random_uuid()::text,'sha256'),'hex'),i);
  end loop;
  return joined || pg_catalog.jsonb_build_object('code',public_code);
end $fn$;

create or replace function public.asgq_rehearsal_add_bot(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  player_row asgq_rehearsal_private.players%rowtype;
  next_number integer;
  bot_name text;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null or ev.host_token_hash is distinct from player_row.token_hash
    then raise exception 'Seul le créateur peut ajouter des bots.'; end if;
  if ev.phase<>'lobby' or ev.manual_started then raise exception 'La partie a déjà commencé.'; end if;
  if (select count(*) from asgq_rehearsal_private.players)>=ev.max_players
    then raise exception 'Le salon est complet.'; end if;
  select coalesce(max(bot_order),0)+1 into next_number
    from asgq_rehearsal_private.players where bot_order is not null;
  if next_number>20 then raise exception 'Maximum 20 bots pour cette répétition.'; end if;
  bot_name := 'Bot '||pg_catalog.lpad(next_number::text,2,'0');
  if exists(select 1 from asgq_rehearsal_private.players where lower(name)=lower(bot_name))
    then raise exception 'Ce nom de bot est déjà utilisé.'; end if;
  insert into asgq_rehearsal_private.players(event_id,name,token_hash,bot_order)
    values(1,bot_name,
      pg_catalog.encode(extensions.digest('asgq-rehearsal-bot:'||pg_catalog.gen_random_uuid()::text,'sha256'),'hex'),
      next_number);
  return pg_catalog.jsonb_build_object('name',bot_name,'bots',next_number);
end $fn$;

create or replace function public.asgq_rehearsal_start(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  player_row asgq_rehearsal_private.players%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null or ev.host_token_hash is distinct from player_row.token_hash
    then raise exception 'Seul le créateur peut lancer la partie.'; end if;
  if ev.phase<>'lobby' or ev.manual_started then raise exception 'La partie a déjà commencé.'; end if;
  if (select count(*) from asgq_rehearsal_private.players)<2
    then raise exception 'Ajoute au moins un bot ou un autre joueur.'; end if;
  if not asgq_rehearsal_private.ready_for_kickoff()
    then raise exception 'Les deux mi-temps ne sont pas prêtes.'; end if;
  update asgq_rehearsal_private.event set manual_started=true
    where id=1;
  perform asgq_rehearsal_private.tick();
end $fn$;

revoke execute on function public.asgq_rehearsal_add_bot(uuid) from public,anon,authenticated;
revoke execute on function public.asgq_rehearsal_start(uuid) from public,anon,authenticated;
grant execute on function public.asgq_rehearsal_add_bot(uuid) to anon,authenticated;
grant execute on function public.asgq_rehearsal_start(uuid) to anon,authenticated;

-- 20 provisional questions, split 10 + 10. No official quiz changes.
delete from asgq_rehearsal_private.questions where position between 1 and 20;
insert into asgq_rehearsal_private.questions(position,half,prompt,choices,correct_index,points,explanation) values
(1,1,'Quel pays a remporté la Coupe du Monde 2018 ?',ARRAY['Allemagne','France','Argentine','Croatie']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(2,1,'Quel est le sport pratiqué par l’AS Grinta ?',ARRAY['Basket','Football','Rugby','Handball']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(3,1,'Quel mot désigne la liste des joueurs alignés pour un match ?',ARRAY['Composition','Mercato','Classement','Transfert']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(4,1,'Quelle couleur évoque le maillot de la France ?',ARRAY['Bleu','Vert','Orange','Violet']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(5,1,'Sur quelle appli se déroule ce questionnaire ?',ARRAY['Le Soulieteur','Instagram','Spotify','Google Maps']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(6,1,'Combien de mi-temps sont prévues pour le quiz ?',ARRAY['Une','Deux','Trois','Quatre']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(7,1,'Quel objet donne le coup d’envoi d’un match ?',ARRAY['Un ballon','Un drapeau','Un chronomètre','Un sifflet']::text[],3,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(8,1,'Quel mot désigne les joueurs remplaçants ?',ARRAY['Les arbitres','Le banc','Les tribunes','La pelouse']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(9,1,'Quel terme désigne un match entre coéquipiers ?',ARRAY['Un derby interne','Une finale','Un mercato','Une prolongation']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(10,1,'Quel écran permettra de connaître le gagnant du quiz ?',ARRAY['Le podium','Les réglages','Les contacts','Les transferts']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(11,2,'Combien de joueurs par équipe débutent un match de football à onze ?',ARRAY['9','10','11','12']::text[],2,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(12,2,'Quelle couleur de carton correspond à une expulsion ?',ARRAY['Rouge','Jaune','Bleu','Blanc']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(13,2,'Quelle durée a une mi-temps de football réglementaire ?',ARRAY['30 minutes','40 minutes','45 minutes','50 minutes']::text[],2,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(14,2,'Que récompense un penalty ?',ARRAY['Un corner','Une touche','Une faute dans la surface','Un hors-jeu']::text[],2,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(15,2,'Comment s’appelle le tournoi mondial des équipes nationales ?',ARRAY['Coupe du Monde','Ligue 1','Ligue Europa','Coupe de France']::text[],0,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(16,2,'Combien de points vaut une victoire en championnat classique ?',ARRAY['Un','Deux','Trois','Quatre']::text[],2,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(17,2,'Que signifie VAR ?',ARRAY['Vidéo arbitrale de référence','Assistance vidéo à l’arbitrage','Victoire après recours','Vérification avant remise']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(18,2,'À quel endroit tire-t-on un corner ?',ARRAY['Au point central','Depuis l’arc de coin','Depuis le rond central','Au point de penalty']::text[],1,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(19,2,'Quel joueur peut prendre le ballon à la main dans sa surface ?',ARRAY['Le capitaine','Le défenseur','Le gardien','L’attaquant']::text[],2,1,'Question provisoire : contenu à personnaliser avant la soirée.'),
(20,2,'Dans quel pays se joue la Premier League ?',ARRAY['Espagne','Allemagne','Italie','Angleterre']::text[],3,1,'Question provisoire : contenu à personnaliser avant la soirée.');
