# Supabase

The production database is managed with versioned migrations. Production project: `cartes-soiree`.

Hardening applied on 2026-09-17 includes:
- target score validation and correct 3/5/7/10 persistence;
- server-side authorization for advancing rounds;
- no privilege based on a player's display name;
- throttled `last_seen` writes;
- create/join abuse throttling using a one-way server-peppered client fingerprint;
- safer player departure handling during active rounds;
- discard blocked after submission;
- winner must still be active when selected;
- internal helper RPCs remain unavailable to browser roles;
- future public-schema privileges are opt-in.

The live database remains the source of truth for the older bootstrap/seed migrations created before this repository started versioning SQL. New database changes must be committed here at the same time they are applied.
