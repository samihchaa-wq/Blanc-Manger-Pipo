-- Mr White : règle validée, victoire commune quand Imposteur + Mr White
-- sont encore vivants et que les Civils ne sont plus majoritaires.
-- Cas non régressifs : victoire Imposteur seul, White seul, Civils, prolongation.
-- Les salons, votes et scores sont intégralement annulés à la fin.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.228"}',true);

do $qa_white_alliance$
declare
  scenario text;
  h json; j json; code_salon text; v_room_id uuid; r public.rooms;
  host_token uuid; n integer; nc integer; ni integer; winner_expected text;
  current_winner text; current_note text; st json; white_points integer;
  undercover_points integer; civil_points integer;
begin
  foreach scenario in array array[
    'alliance_one_civil',
    'alliance_parity',
    'undercover_only',
    'white_only',
    'civils',
    'continue'
  ] loop
    h:=public.create_room('QA victoire mixte',1,'white',1);
    code_salon:=h->>'code';
    host_token:=(h->>'token')::uuid;
    for n in 2..6 loop
      j:=public.join_room(code_salon,'QA partenaire ' || n);
      if j->>'token' is null then raise exception '% : joueur % non ajouté',scenario,n; end if;
    end loop;
    perform public.lancer_partie(code_salon,host_token);
    select * into r from public.rooms where code=code_salon;
    v_room_id:=r.id;
    if r.status<>'white_clue' then raise exception '% : mauvaise phase de départ %',scenario,r.status; end if;

    -- Fixer un tirage déterministe : siège 2 Imposteur, siège 3 Mr White.
    -- Les quatre autres sont Civils. Seulement dans la transaction de QA.
    update public.white_roles wr set role=case pp.pos
      when 2 then 'undercover'
      when 3 then 'white'
      else 'civil' end, eliminated=false, eliminated_cycle=null
    from (select id,row_number() over(order by seat) pos from public.players where room_id=v_room_id) pp
    where wr.player_id=pp.id and wr.room_id=v_room_id and wr.round=r.round;

    update public.white_roles wr set eliminated=true,eliminated_cycle=1
    from (select id,row_number() over(order by seat) pos from public.players where room_id=v_room_id) pp
    where wr.player_id=pp.id and wr.room_id=v_room_id and wr.round=r.round
      and (
        (scenario='alliance_one_civil' and pp.pos in(4,5,6))
        or (scenario='alliance_parity' and pp.pos in(5,6))
        or (scenario='undercover_only' and pp.pos in(3,4,5,6))
        or (scenario='white_only' and pp.pos in(2,4,5,6))
        or (scenario='civils' and pp.pos in(2,3))
        or (scenario='continue' and pp.pos=6)
      );

    select count(*) filter(where wr.role='civil'),count(*) filter(where wr.role<>'civil')
      into nc,ni from public.white_roles wr
      where wr.room_id=v_room_id and wr.round=r.round and not wr.eliminated;

    perform public._white_check_end(v_room_id);
    select * into r from public.rooms where id=v_room_id;
    select winner into current_winner from public.white_rounds
      where room_id=v_room_id and round=r.round;

    winner_expected:=case scenario
      when 'alliance_one_civil' then 'alliance'
      when 'alliance_parity' then 'alliance'
      when 'undercover_only' then 'imposteurs'
      when 'white_only' then 'white'
      when 'civils' then 'civils'
      else null
    end;

    if current_winner is distinct from winner_expected then
      raise exception '% : résultat %, attendu %, civils %, adversaires %',
        scenario,current_winner,winner_expected,nc,ni;
    end if;
    if r.status is distinct from
       (case when scenario='continue' then 'white_elimination' else 'reveal' end) then
      raise exception '% : mauvaise phase de sortie %',scenario,r.status;
    end if;

    if scenario in ('alliance_one_civil','alliance_parity') then
      if position('White' in coalesce(r.white_note,''))=0 or
         position('Imposteur' in coalesce(r.white_note,''))=0 then
        raise exception '% : l’annonce ne mentionne pas les deux gagnants',scenario;
      end if;
      st:=public.white_state(code_salon,host_token);
      if st->>'winner'<>'alliance' then
        raise exception '% : le client ne reçoit pas le gagnant commun',scenario;
      end if;
      select pp.score into white_points from public.players pp join public.white_roles wr on wr.player_id=pp.id
        where wr.room_id=v_room_id and wr.round=r.round and wr.role='white';
      select pp.score into undercover_points from public.players pp join public.white_roles wr on wr.player_id=pp.id
        where wr.room_id=v_room_id and wr.round=r.round and wr.role='undercover';
      select coalesce(sum(pp.score),0) into civil_points from public.players pp join public.white_roles wr on wr.player_id=pp.id
        where wr.room_id=v_room_id and wr.round=r.round and wr.role='civil';
      if scenario='alliance_one_civil' and (white_points<>6 or undercover_points<>3 or civil_points<>0) then
        raise exception '% : barème modifié (White %, Imposteur %, Civils %)',
          scenario,white_points,undercover_points,civil_points;
      end if;
      if scenario='alliance_parity' and (white_points<>4 or undercover_points<>2 or civil_points<>0) then
        raise exception '% : barème 2 vs 2 erroné (White %, Imposteur %, Civils %)',
          scenario,white_points,undercover_points,civil_points;
      end if;
      -- Une deuxième vérification ne doit pas rajouter les points après révélation.
      perform public._white_check_end(v_room_id);
      if (select score from public.players pp join public.white_roles wr on wr.player_id=pp.id
          where wr.room_id=v_room_id and wr.round=r.round and wr.role='white')<>white_points then
        raise exception '% : double score après révélation',scenario;
      end if;
    end if;

    if scenario='white_only' and r.white_note='Mr White a trouvé le mot !' then
      raise exception 'Victoire White par égalité : fausse annonce de mot trouvé';
    end if;
    raise notice 'OK scénario % : civils %, adversaires %, gagnant %',scenario,nc,ni,current_winner;
  end loop;
end $qa_white_alliance$;

rollback;
