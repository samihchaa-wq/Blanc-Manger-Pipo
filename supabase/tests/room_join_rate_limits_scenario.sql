-- Scénario d'intégration : à lancer sur une base de test APRÈS la migration.
-- Tous les changements (salons, compteurs, joueurs) sont annulés par ROLLBACK.
begin;

-- Empreinte synthétique réservée à la documentation ; aucune IP réelle stockée.
select pg_catalog.set_config(
  'request.headers', '{"x-forwarded-for":"192.0.2.149"}', true
);

do $scenario$
declare
  h json;
  joined json;
  answer json;
  c text;
  bad_code text;
  i integer;
  hsh text;
  requests_count integer;
  failures_count integer;
begin
  hsh := public._client_hash();
  if hsh is null then
    raise exception 'TEST IMPOSSIBLE : la configuration du hash IP manque.';
  end if;

  h := public.create_room('Hote', 1, 'phrases', 1);
  c := h->>'code';
  if c is null then raise exception 'Création du salon impossible'; end if;

  -- Un code valide doit toujours permettre à un nouvel invité de rejoindre.
  joined := public.join_room(c, 'Alice');
  if joined->>'token' is null or joined->>'error' is not null then
    raise exception 'Connexion légitime refusée : %', joined;
  end if;

  select s.code into bad_code
  from (
    select lpad(n::text, 4, '0') code
    from generate_series(0, 9999) n
  ) s
  where not exists (select 1 from public.rooms r where r.code=s.code)
  order by s.code limit 1;

  if bad_code is null then raise exception 'Pas de code libre pour tester'; end if;

  for i in 1..8 loop
    answer := public.join_room(bad_code, 'Visiteur');
    if answer->>'error_code' <> 'JOIN_REJECTED' then
      raise exception 'Refus % incorrect : %', i, answer;
    end if;
  end loop;
  answer := public.join_room(c, 'Bob');
  if answer->>'error_code' <> 'RATE_LIMITED' then
    raise exception 'Un code valable contourne le blocage : %', answer;
  end if;

  select requests, failures into requests_count, failures_count
  from public.room_join_limits where client_hash = hsh;
  if requests_count <> 10 or failures_count <> 8 then
    raise exception 'Compteurs incorrects : % appels, % refus', requests_count, failures_count;
  end if;

  if pg_catalog.has_table_privilege('anon','public.room_join_limits','SELECT') then
    raise exception 'La table des tentatives est lisible anonymement.';
  end if;
end $scenario$;

rollback;
