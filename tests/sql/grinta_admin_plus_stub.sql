-- Isolated CI only: fake Admin+ verifier; never uses or exposes the real password.
create or replace function public._is_admin_plus(p_password text)
returns boolean language sql stable set search_path = '' as $fn$
  select p_password = 'CI-TEST-ONLY-PASSWORD';
$fn$;
revoke execute on function public._is_admin_plus(text) from public, anon, authenticated;
