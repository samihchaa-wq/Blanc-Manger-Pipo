-- Vérifie les permissions de jeu et le caractère définitif des votes.
-- Test transactionnel : aucune partie créée ne survit au ROLLBACK.
begin;

do $audit$
declare
  h json; a json; b json;
  code_salon text; host_token uuid; alice_token uuid;
  host_id uuid; alice_id uuid; bob_id uuid; bot_id uuid; room_id uuid;
  dico_bob uuid; dico_host uuid;
  dilemme_host uuid; dilemme_bob uuid; dilemme_bot uuid;
  before_count integer; after_count integer;
  stored_vote uuid;
begin
  h := public.create_room('Hôte de test', 5, 'phrases', 1);
  code_salon := h->>'code';
  host_token := (h->>'token')::uuid;
  host_id := (h->>'player_id')::uuid;
  a := public.join_room(code_salon, 'Alice de test');
  b := public.join_room(code_salon, 'Bob de test');
  alice_token := (a->>'token')::uuid;
  alice_id := (a->>'player_id')::uuid;
  bob_id := (b->>'player_id')::uuid;
  select id into room_id from public.rooms where code=code_salon;

  insert into public.players(room_id,name,seat,is_bot,ready)
  values(room_id,'Bot temporaire',3,true,true)
  returning id into bot_id;

  -- L'hôte peut utiliser son outil de test ; un invité n'a pas ce droit.
  perform public.bot_step(code_salon,host_token);
  begin
    perform public.bot_step(code_salon,alice_token);
    raise exception 'SECURITY_TEST_FAILURE: invité autorisé à piloter les bots';
  exception when others then
    if sqlerrm like 'SECURITY_TEST_FAILURE:%' then raise; end if;
    if sqlerrm not like '%Seul l%hôte pilote les bots%' then
      raise exception 'Erreur inattendue pour bot_step : %',sqlerrm;
    end if;
  end;

  -- Test du Dico : le premier vote devient définitif.
  update public.rooms set mode='dico',status='dico_vote',round=1,reader_id=host_id
  where id=room_id;
  insert into public.dico_defs(room_id,round,player_id,text)
  values(room_id,1,bob_id,'Une définition de Bob')
  returning id into dico_bob;
  insert into public.dico_defs(room_id,round,player_id,text)
  values(room_id,1,host_id,'Une autre définition')
  returning id into dico_host;

  perform public.dico_vote(code_salon,alice_token,dico_bob);
  begin
    perform public.dico_vote(code_salon,alice_token,dico_host);
    raise exception 'SECURITY_TEST_FAILURE: changement de vote au Dico accepté';
  exception when others then
    if sqlerrm like 'SECURITY_TEST_FAILURE:%' then raise; end if;
    if sqlerrm not like '%déjà enregistré%' then
      raise exception 'Erreur inattendue pour Dico : %',sqlerrm;
    end if;
  end;
  select def_id into stored_vote from public.dico_votes
  where room_id=room_id and round=1 and voter_id=alice_id;
  if stored_vote is distinct from dico_bob then
    raise exception 'Le vote Dico initial a été modifié';
  end if;

  -- Test Dilemme : rejet des doublons, aucun changement d'un vote déjà transmis.
  update public.rooms set mode='dilemme',status='dilemme_vote'
  where id=room_id;
  insert into public.dilemme_buts(room_id,round,player_id,text)
    values(room_id,1,host_id,'Défi hôte') returning id into dilemme_host;
  insert into public.dilemme_buts(room_id,round,player_id,text)
    values(room_id,1,bob_id,'Défi Bob') returning id into dilemme_bob;
  insert into public.dilemme_buts(room_id,round,player_id,text)
    values(room_id,1,bot_id,'Défi bot') returning id into dilemme_bot;

  begin
    perform public.dilemme_vote(code_salon,alice_token,
      array[dilemme_host,dilemme_host,dilemme_bot],array[true,false,true]);
    raise exception 'SECURITY_TEST_FAILURE: cibles Dilemme dupliquées acceptées';
  exception when others then
    if sqlerrm like 'SECURITY_TEST_FAILURE:%' then raise; end if;
    if sqlerrm not like '%présente plusieurs fois%' then
      raise exception 'Erreur inattendue pour doublon : %',sqlerrm;
    end if;
  end;

  perform public.dilemme_vote(code_salon,alice_token,
    array[dilemme_host,dilemme_bob,dilemme_bot],array[true,false,true]);
  select count(*) into before_count from public.dilemme_votes
  where room_id=room_id and round=1 and voter_id=alice_id;
  if before_count<>3 then raise exception 'Vote Dilemme valide incomplet : %',before_count; end if;

  begin
    perform public.dilemme_vote(code_salon,alice_token,
      array[dilemme_host,dilemme_bob,dilemme_bot],array[false,true,false]);
    raise exception 'SECURITY_TEST_FAILURE: modification du vote Dilemme autorisée';
  exception when others then
    if sqlerrm like 'SECURITY_TEST_FAILURE:%' then raise; end if;
    if sqlerrm not like '%déjà enregistré%' then
      raise exception 'Erreur inattendue pour revote : %',sqlerrm;
    end if;
  end;
  select count(*) into after_count from public.dilemme_votes
  where room_id=room_id and round=1 and voter_id=alice_id and yes=true;
  if after_count<>2 then raise exception 'Les réponses du Dilemme ont changé'; end if;
end $audit$;

rollback;
