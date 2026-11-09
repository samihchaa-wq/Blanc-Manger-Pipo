# Grand Quiz AS Grinta 2026 — V1

A **single-use**, smartphone-only quiz. No show control panel, no separate spectator screen, no quiz catalogue or question editor. Built as a separate `/grinta-quiz/` page of the Soulieteur repository and a separate `asgq_private` database schema to avoid changes to the existing games.

## Session

1. A guest opens `/grinta-quiz/` and provides the code shown at the event + a nickname.
2. After the second guest joins, a 2-minute automatic lobby countdown starts.
3. A 7-second kickoff intro plays, then the first half begins.
4. The server advances every 25-second question to a 9-second answer reveal and awards points exactly once.
5. At the boundary between half 1 and half 2, a 40-second halftime/rankings screen appears.
6. The second half finishes with a scoreboard and podium. Every phone independently polls the same server state.

The backend computes deadlines from **database time**. Every status read advances the event under a row lock, so no phone acts as a master. The final code and future questions are never shipped in the frontend; answer keys and question database are in a non-exposed schema with RLS enabled.

## Files

- `index.html`: standalone entry point and branded shell.
- `style.css`: lightweight AS Grinta navy-and-gold mobile visual system.
- `app.js`: session/resume, polling, display, answer selection and timer.
- `../supabase/migrations/20261122120000_as_grinta_quiz_2026.sql`: isolated data model and public authenticated RPCs.

The page uses the *publishable* Supabase key and the already-installed `../vendor/supabase.js`. It does not import or modify `js/core.js`, `js/jeux/qcm.js`, or the Soulieteur's tables.

## Before the event

The SQL migration seeds **four clearly marked technical placeholders only** (two per half) and generates a random one-night entry code. Replace these test questions with 10–20 real questions per half **before** using the real invitation code. Never put the code in this repository or any browser asset. An authorized maintainer retrieves the generated code with the Supabase SQL editor:

```sql
select plaintext_code from asgq_private.invitation where event_id = 1;
```

To load the final 2 halves, replace the placeholder rows from a restricted SQL editor while the event is still in `lobby`, maintaining an increasing `position` and consistent halves; the first 10–20 positions should have `half = 1`, followed by 10–20 with `half = 2`.

There is **no restart / reset control in the player UI**. Test with a transactional database rollback or a separate test environment before announcing the real code; after a full rehearsal, reset the event and test participants in a restricted SQL session. Do not reset an active real game.

## Checks before release

- Several devices join the same room and receive the same phase countdown.
- Incorrect event code cannot join; upcoming questions and correct answers are not available from network responses.
- A selected answer can change while the question is open, but cannot change after the deadline.
- Disconnect and reconnect preserve the same token and score.
- With an existing answer, late/duplicate polls never award points twice.
- After the last first-half question the halftime screen appears, then the next half, then the final podium.
- Test with 15–30 simultaneous phones, iOS Safari and Android Chrome, including background/foreground restoration.

**Current status:** V1 scaffold, no real questions and no live event verification yet. Avoid distributing the invitation code until the full end-to-end test has passed.