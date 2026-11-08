-- Scénario SQL de compatibilité à exécuter sur une base temporaire.
begin;

select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.202"}',true);

do $test$
declare
  candidate text;
  seen text[] := '{}';
  older json;
  newer json;
  i integer;
begin
  for i in 1..150 loop
    candidate := public._new_code();
    if candidate !~ '^[0-9]{8}$' then
      raise exception 'Code non conforme : %', candidate;
    end if;
    if candidate = any(seen) then
      raise exception 'Collision non prévue entre 150 codes aléatoires';
    end if;
    seen := array_append(seen, candidate);
  end loop;

  if pg_catalog.has_function_privilege('anon', 'public._new_code()', 'EXECUTE') then
    raise exception 'Le générateur privé est accessible anonymement';
  end if;

  -- Ancien salon à 4 chiffres. Le jeu continue sans perte de compatibilité.
  older := public.create_room('Ancien hôte', 1, 'phrases', 1);
  if older->>'code' <> '1234' then
    raise exception 'Le scénario de compatibilité requiert le stub ancien salon';
  end if;
  if (public.join_room('1234','Ancien invité')->>'token') is null then
    raise exception 'Invitation à 4 chiffres devenue invalide';
  end if;

  -- Nouveau code, inséré dans la même table de salons.
  candidate := public._new_code();
  insert into public.rooms(code, status, mode) values (candidate, 'lobby', 'phrases');
  newer := public.join_room(candidate,'Nouvel invité');
  if newer->>'token' is null or newer->>'code' <> candidate then
    raise exception 'Invitation à 8 chiffres devenue invalide : %', newer;
  end if;
end $test$;

rollback;
