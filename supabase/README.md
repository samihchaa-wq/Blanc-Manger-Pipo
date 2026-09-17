# Supabase — Blanc Manger Pipo

Production project: `cartes-soiree` (`yqfewxadpyulgxehhpcu`).

## Security model

- The browser uses only the Supabase publishable key.
- Public tables have RLS enabled and no direct `anon`/`authenticated` table grants.
- The game is exposed through explicitly granted RPC functions.
- Internal helper functions are not executable by `anon` or `authenticated`.
- `SECURITY DEFINER` functions use an empty `search_path` and schema-qualified object references.
- The application is intentionally anonymous; gameplay/admin RPCs are not granted to the `authenticated` role.
- Creation/join abuse controls store only a salted/peppered one-way client fingerprint, never the raw client IP.

## Secrets

Never commit `app_settings.admin_hash`, the anti-abuse `rate_pepper`, a service-role/secret key, database password, or any Supabase access token.

For a fresh environment, create the admin password directly in that environment after applying the schema, for example from a trusted SQL session:

```sql
insert into public.app_settings(key, value)
values ('admin_hash', extensions.crypt('<ADMIN_PASSWORD>', extensions.gen_salt('bf', 10)))
on conflict (key) do update set value = excluded.value;
```

Do not replace `<ADMIN_PASSWORD>` inside a committed file.

## Migration history strategy

The production database was created before migrations were committed to this public repository. At least one historical migration contained environment-specific admin credential material, so the raw historical migration stream must not be copied here.

`supabase/migrations/20260917111656_game_schema_and_rpcs.sql` is therefore a **sanitized squashed baseline** of the current schema and RPC surface. It contains no admin hash and generates a fresh anti-abuse pepper at install time.

Every later production migration version that already exists remotely is represented by a deliberate no-op marker. This keeps local and remote migration version numbers aligned while avoiding publication of historical sensitive values or replaying changes already folded into the baseline. New migrations created after this baseline must contain their real forward SQL normally.

`supabase/seed.sql` contains only the active card catalogue (135 questions and 352 answers as of 2026-09-17). It intentionally excludes rooms, players, submissions, tokens and all `app_settings` values.

Current production migration tail:

- `20260917132852_production_hardening_and_game_fixes`
- `20260917133009_winner_integrity_and_privileged_path_hardening`
- `20260917133016_restore_admin_function_resolution` (transient repair, superseded)
- `20260917133047_repair_admin_search_path_hardening`
- `20260917133523_harden_remaining_security_definers`

## Change workflow

For future database changes:

1. Create a new migration rather than editing the squashed baseline.
2. Apply it to the intended Supabase project.
3. Run transactional game-flow tests so test rooms/data are rolled back.
4. Run Supabase security and performance advisors.
5. Commit the migration in the same PR as any client change that depends on it.

The current advisor warning `RLS enabled with no policy` is expected for this architecture because direct table grants are removed. Anonymous `SECURITY DEFINER` warnings are also expected only for the explicitly exposed browser RPC surface; each such function must still validate its player token/admin credential and operation-specific authorization internally.
