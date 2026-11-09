-- AS Grinta : le QCM du Soulieteur mène à un événement unique.
-- Utilise exactement le vérificateur Admin+ existant, sans copier le secret
-- dans le navigateur et sans donner accès au catalogue de quiz.
-- Le code d'invitation de l'ancienne entrée cesse d'être exposé en RPC publique.
create or replace function public.asgq_join_admin_plus(p_password text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  invitation_code text;
begin
  -- Le contrôle de mot de passe est effectué côté serveur, avec l'anti-bruteforce Admin+.
  if not public._is_admin_plus(p_password) then
    raise exception 'Mot de passe Admin+ incorrect.';
  end if;
  -- Le secret technique n'est jamais renvoyé au téléphone.
  select plaintext_code into invitation_code from asgq_private.invitation where event_id = 1;
  if invitation_code is null then
    raise exception 'Événement AS Grinta indisponible.';
  end if;
  return public.asgq_join(invitation_code, p_name, null);
end
$fn$;

revoke execute on function public.asgq_join_admin_plus(text,text) from public, anon, authenticated;
grant execute on function public.asgq_join_admin_plus(text,text) to anon, authenticated;

-- L'ancienne porte d'entrée par code technique n'est plus publique.
-- La reprise de session se fait via asgq_state(token) comme avant.
revoke execute on function public.asgq_join(text,text,uuid) from public, anon, authenticated;
