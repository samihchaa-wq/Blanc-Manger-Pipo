-- Une seule lecture d'état par rafraîchissement.
--
-- Le client appelait jusqu'à trois RPC à chaque relecture : get_state, puis
-- white_state (Mr White en partie), puis punish_state (salon et fin de partie),
-- et relisait get_state quand la saisie des punitions venait de se fermer.
-- Chaque appel est une requête journalisée côté Supabase, multipliée par le
-- nombre de joueurs et d'actions. get_full_state enchaîne les mêmes fonctions
-- côté serveur, dans le même ordre, et renvoie tout en une réponse :
--   { "state": <get_state>, "white": <white_state | null>, "pun": <punish_state | null> }
--
-- Migration additive : les trois RPC restent en place pour les clients pas
-- encore mis à jour, et le nouveau client retombe sur eux si cette fonction
-- n'existe pas encore.

create or replace function public.get_full_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s json; w json := null; pu json := null; st text;
begin
  s := public.get_state(p_code, p_token);
  st := s->'room'->>'status';

  -- Les punitions ne servent qu'au salon et à l'écran de fin. punish_state
  -- peut lancer la partie (dernier attendu parti) : on relit alors l'état pour
  -- renvoyer le statut à jour. Une erreur de punish_state ne doit pas priver
  -- le joueur de l'état du jeu (le client l'ignorait déjà).
  if st in ('lobby', 'finished') then
    begin
      pu := public.punish_state(p_code, p_token);
    exception when others then
      pu := null;
    end;
    if st = 'lobby' and (pu is null or pu->>'phase' is null) then
      s := public.get_state(p_code, p_token);
      st := s->'room'->>'status';
      if st not in ('lobby', 'finished') then pu := null; end if;
    end if;
  end if;

  -- Rôles et mots secrets de Mr White : white_state ne renvoie que ceux du joueur.
  if s->'room'->>'mode' = 'white' and st <> 'lobby' then
    w := public.white_state(p_code, p_token);
  end if;

  return json_build_object('state', s, 'white', w, 'pun', pu);
end $fn$;

revoke execute on function public.get_full_state(text, uuid) from public;
grant execute on function public.get_full_state(text, uuid) to anon, authenticated;
