-- Les codes de partie ne contiennent plus que des chiffres : le pavé numérique
-- du téléphone suffit à les saisir, et O/0 ou I/1 ne se confondent plus à l'oral.
-- Les parties inactives sont purgées au bout d'un jour : la boucle d'unicité
-- trouve donc toujours un code libre parmi les 10 000 possibles.
create or replace function public._new_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare c text; chars text := '0123456789';
begin
  loop
    c := '';
    for i in 1..4 loop c := c || substr(chars, 1 + floor(random()*length(chars))::int, 1); end loop;
    exit when not exists(select 1 from public.rooms where code=c);
  end loop;
  return c;
end
$$;

revoke all on function public._new_code() from public, anon, authenticated;
