-- À appliquer après publication de l'interface qui propose le choix du juge.
-- Les manches en cours restent inchangées; seules les nouvelles préparent un défi.
CREATE OR REPLACE FUNCTION public._custom_round_enabled()
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO '' AS $fn$
  SELECT true
$fn$;
REVOKE ALL ON FUNCTION public._custom_round_enabled() FROM PUBLIC, anon, authenticated;
