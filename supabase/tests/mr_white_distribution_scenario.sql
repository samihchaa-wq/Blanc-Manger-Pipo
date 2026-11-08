-- Test d'intégration à lancer dans une base Supabase de test après migrations.
-- Toute la partie est annulée en fin de transaction : aucune salle n'est conservée.
begin;

do $test$
declare
  nb integer; joueurs integer; autres integer; salon json; code_salon text;
  token_hote uuid; id_salon uuid; attendu integer;
begin
  for joueurs in 3..9 loop
    salon := public.create_room('Hote Test', 1, 'white', 1);
    code_salon := salon->>'code';
    token_hote := (salon->>'token')::uuid;
    for nb in 2..joueurs loop
      perform public.join_room(code_salon, 'Test ' || nb);
    end loop;
    select id into id_salon from public.rooms where code=code_salon;
    perform public.lancer_partie(code_salon, token_hote);
    attendu := case when joueurs >= 6 then 2 else 1 end;
    select count(*) into autres from public.white_roles
     where room_id=id_salon and round=1 and role in ('undercover','white');
    if autres <> attendu then
      raise exception 'Mr White : % joueurs, % imposteurs au lieu de %', joueurs, autres, attendu;
    end if;
  end loop;
end $test$;

rollback;
