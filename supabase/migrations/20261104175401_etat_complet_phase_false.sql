-- punish_state renvoie "phase": false (et non null) hors saisie des punitions :
-- la relecture de l'état après la fermeture de la saisie doit aussi se faire
-- dans ce cas, sinon une partie qui vient d'être lancée était encore vue au
-- salon (et le client annonçait à tort « Un joueur est parti »).
-- Vérifiée en production dans une transaction annulée : saisie ouverte,
-- envoi de l'hôte, départ du dernier attendu -> statut « ranking », pun null.
create or replace function public.get_full_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s json; w json := null; pu json := null; st text;
begin
  s := public.get_state(p_code, p_token);
  st := s->'room'->>'status';

  if st in ('lobby', 'finished') then
    begin
      pu := public.punish_state(p_code, p_token);
    exception when others then
      pu := null;
    end;
    -- phase absente, null ou false : la saisie n'est pas (ou plus) ouverte
    if st = 'lobby' and coalesce(pu->>'phase', '') in ('', 'false') then
      s := public.get_state(p_code, p_token);
      st := s->'room'->>'status';
      if st not in ('lobby', 'finished') then pu := null; end if;
    end if;
  end if;

  if s->'room'->>'mode' = 'white' and st <> 'lobby' then
    w := public.white_state(p_code, p_token);
  end if;

  return json_build_object('state', s, 'white', w, 'pun', pu);
end $fn$;

revoke execute on function public.get_full_state(text, uuid) from public;
grant execute on function public.get_full_state(text, uuid) to anon, authenticated;
