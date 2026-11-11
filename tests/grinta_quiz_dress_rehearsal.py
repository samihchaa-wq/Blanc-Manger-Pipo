#!/usr/bin/env python3
"""Grand Quiz dress rehearsal: 3 independent Chromium devices, mock RPC server.

Runs ONLY against a fresh local in-memory HTTP backend. No production credentials,
Supabase data, official questions, or user accounts are used. The app HTML, JS
and CSS are the actual production files. A separate isolated PostgreSQL suite
tests the real database functions; this script tests the browser workflow.
"""
from __future__ import annotations

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import functools
import json
from pathlib import Path
import threading
import time

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "test-results" / "browser"
OUT.mkdir(parents=True, exist_ok=True)
TOKENS = {"qa-host": ("host", "Alban"),
          "qa-cam": ("cam", "Camille"),
          "qa-nina": ("nina", "Nina")}
ROOM = "00123456"
QUESTION_COUNT = 20

MOCK_SDK = r"""
// A genuine HTTP round-trip to the local mock. This can be interrupted by
// Playwright's offline mode and is shared by three independent browser contexts.
window.supabase = {
  createClient: () => ({
    rpc: async (name, args = {}) => {
      const response = await fetch('/__asgq_dress_rpc', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name, args})
      });
      return await response.json();
    }
  })
};
"""


class DressGame:
    def __init__(self):
        self.lock = threading.RLock()
        self.phase = "lobby"
        self.position = 0
        self.answers = {}
        self.scores = {"cam": 0, "nina": 0}
        self.revealed = set()
        self.calls = []
        self.players = [
            {"id": "host", "name": "Alban", "is_host": True},
            {"id": "cam", "name": "Camille", "is_host": False},
            {"id": "nina", "name": "Nina", "is_host": False},
        ]

    def ranking(self):
        return [
            {"id": item["id"], "name": item["name"],
             "score": self.scores[item["id"]]}
            for item in sorted(self.players[1:],
                key=lambda p: (-self.scores[p["id"]], p["name"]))
        ]

    def state(self, token):
        if token not in TOKENS:
            return {"error": {"message": "Session expirée."}, "data": None}
        player_id, name = TOKENS[token]
        host = player_id == "host"
        question = None
        if self.phase in ("question", "reveal"):
            answers = self.answers.get(self.position, {})
            correct = 0
            responses = [
                {"id": item["id"], "name": item["name"],
                 "status": ("unanswered" if item["id"] not in answers else
                            "correct" if answers[item["id"]] == correct else
                            "incorrect")}
                for item in self.players[1:]
            ] if self.phase == "reveal" else None
            question = {
                "text": f"Question fictive {self.position} : quel choix est le bon ?",
                "choices": [
                    "Réponse correcte de test",
                    "Choix incorrect de test",
                    "Autre choix de test",
                    "Dernière réponse fictive",
                ],
                "correct": correct if self.phase == "reveal" else None,
                "explanation": ("Question fictive : ceci est un test "
                                "de fonctionnement, pas une question officielle.")
                               if self.phase == "reveal" else None,
                "points": 1,
                "my_choice": answers.get(player_id),
                "earned": (1 if answers.get(player_id) == correct else 0)
                          if self.phase == "reveal" and not host else None,
                "answered_count": len(answers),
                "waiting_players": [
                    {"id": p["id"], "name": p["name"]}
                    for p in self.players[1:] if p["id"] not in answers
                ] if self.phase == "question" and host else None,
                "responses": responses,
            }
        return {"error": None, "data": {
            "phase": self.phase,
            "title": "Grand Quiz AS Grinta (répétition isolée)",
            "room_code": ROOM,
            "ready": True,
            "position": self.position,
            "half": 2 if self.position > 10 or self.phase == "halftime" else 1,
            "first_half_count": 10,
            "second_half_count": 10,
            "players": self.players,
            "standings": self.ranking()
                         if self.phase in ("reveal", "halftime", "finished")
                         else None,
            "max_players": 30,
            "me": {"id": player_id, "name": name,
                   "score": self.scores.get(player_id, 0)},
            "is_host": host,
            "question": question,
        }}

    def rpc(self, name, args):
        self.calls.append((name, args))
        token = args.get("p_token")
        if name == "asgq_rehearsal_state":
            return self.state(token)
        if name == "asgq_rehearsal_start":
            if token != "qa-host":
                return {"data": None, "error": {"message": "Animateur uniquement."}}
            if self.phase != "lobby":
                return {"data": None, "error": {"message": "Déjà lancé."}}
            self.phase = "intro"
            return {"data": None, "error": None}
        if name == "asgq_rehearsal_answer":
            if token not in ("qa-cam", "qa-nina") or self.phase != "question":
                return {"data": None, "error": {"message": "Vote impossible."}}
            choice = args.get("p_choice")
            if type(choice) is not int or not (0 <= choice <= 3):
                return {"data": None, "error": {"message": "Choix invalide."}}
            player_id = TOKENS[token][0]
            self.answers.setdefault(self.position, {})[player_id] = choice
            return {"data": None, "error": None}
        if name == "asgq_rehearsal_advance":
            if token != "qa-host":
                return {"data": None, "error": {"message": "Animateur uniquement."}}
            if (args.get("p_expected_phase") != self.phase or
                    args.get("p_expected_position") != self.position):
                return {"data": None, "error": {"message": "Commande périmée."}}
            if self.phase == "intro":
                self.phase, self.position = "question", 1
            elif self.phase == "question":
                if self.position not in self.revealed:
                    for player_id, choice in self.answers.get(self.position, {}).items():
                        self.scores[player_id] += int(choice == 0)
                    self.revealed.add(self.position)
                self.phase = "reveal"
            elif self.phase == "reveal":
                if self.position == 20:
                    self.phase = "finished"
                elif self.position == 10:
                    self.phase = "halftime"
                else:
                    self.position += 1
                    self.phase = "question"
            elif self.phase == "halftime":
                self.position, self.phase = 11, "question"
            else:
                return {"data": None, "error": {"message": "Phase verrouillée."}}
            return {"data": None, "error": None}
        return {"data": None, "error": {"message": f"RPC non prévue : {name}"}}


class DressHandler(SimpleHTTPRequestHandler):
    game = None

    def log_message(self, *_args):
        return

    def do_POST(self):
        if self.path != "/__asgq_dress_rpc":
            self.send_error(404)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 2 or size > 4096:
                raise ValueError("Invalid body size")
            payload = json.loads(self.rfile.read(size).decode("utf-8"))
            with self.game.lock:
                result = self.game.rpc(payload.get("name"), payload.get("args") or {})
            output = json.dumps(result, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()
            self.wfile.write(output)
        except (ValueError, json.JSONDecodeError) as error:
            self.send_error(400, str(error))


def open_device(browser, origin, token, width):
    context = browser.new_context(
        viewport={"width": width, "height": 844},
        reduced_motion="reduce",
        service_workers="block",
    )
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.route("**/vendor/supabase.js",
               lambda route: route.fulfill(status=200,
                   content_type="application/javascript", body=MOCK_SDK))
    page.add_init_script("localStorage.setItem("
        "'asgq-2026-rehearsal-participant'," + json.dumps(token) + ");")
    page.goto(origin + "/grinta-quiz/?repetition=1",
              wait_until="load", timeout=20000)
    page.locator('[data-screen="lobby"]').wait_for(timeout=15000)
    return context, page, errors


def refresh(page):
    page.evaluate("() => fetchState()")


def screen(page, phase):
    refresh(page)
    page.locator(f'[data-screen="{phase}"]').wait_for(timeout=12000)


def check_no_overflow(page, label):
    m = page.evaluate("""() => ({
      viewport: innerWidth,
      documentWidth: document.documentElement.scrollWidth
    })""")
    assert m["documentWidth"] <= m["viewport"] + 2, f"{label}: {m}"


def run():
    game = DressGame()
    DressHandler.game = game
    server = ThreadingHTTPServer(("127.0.0.1", 0),
               functools.partial(DressHandler, directory=str(ROOT)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f"http://127.0.0.1:{server.server_port}"
    devices = []
    try:
        with sync_playwright() as play:
            browser = play.chromium.launch()
            try:
                for token, width in (("qa-host", 390), ("qa-cam", 375),
                                     ("qa-nina", 320)):
                    devices.append(open_device(browser, origin, token, width))
                host_ctx, host, host_errors = devices[0]
                cam_ctx, cam, cam_errors = devices[1]
                nina_ctx, nina, nina_errors = devices[2]

                assert host.locator('[data-start-quiz]').is_enabled()
                assert cam.locator('[data-start-quiz]').count() == 0
                assert nina.locator('[data-start-quiz]').count() == 0
                with game.lock:
                    assert game.phase == "lobby"
                    assert game.scores == {"cam": 0, "nina": 0}

                # The host alone starts. Polling does not transition phases.
                host.locator('[data-start-quiz]').click()
                screen(host, "intro")
                screen(cam, "intro")
                assert cam.locator('[data-next-phase]').count() == 0
                with game.lock:
                    assert game.phase == "intro"
                host.locator('[data-next-phase]').click()
                screen(host, "question")
                screen(cam, "question")
                screen(nina, "question")

                for position in range(1, QUESTION_COUNT + 1):
                    with game.lock:
                        assert game.phase == "question", (game.phase, position)
                        assert game.position == position, (game.position, position)
                    assert int(host.locator('.pos b').first.inner_text()) == position
                    assert cam.locator('[data-next-phase]').count() == 0

                    # Deliberate manual control with unreturned answers.
                    if position == 1:
                        assert host.locator('#answer-counter .waiting-name').all_inner_texts() == [
                            "Camille", "Nina"]
                        host.locator('[data-next-phase]').click()
                        host.locator('[data-confirm-reveal]').wait_for(state="visible")
                        with game.lock:
                            assert game.phase == "question"
                        host.locator('[data-cancel-reveal]').click()
                        host.locator('[data-next-phase]').wait_for(state="visible")

                    # On question 5 the player's phone loses the connection.
                    if position == 5:
                        cam_ctx.set_offline(True)
                        refresh(cam)
                        cam.locator('#network-status').wait_for(state="visible")
                        assert cam.evaluate("() => localStorage.getItem("
                            "'asgq-2026-rehearsal-participant')") == "qa-cam"
                        with game.lock:
                            assert game.phase == "question"
                            assert "cam" not in game.answers.get(position, {})
                        cam_ctx.set_offline(False)
                        refresh(cam)
                        cam.locator('#network-status').wait_for(state="hidden")
                        assert cam.locator('[data-screen="question"]').count() == 1

                    # Reload must recover the exact player identity and score.
                    if position == 8:
                        previous_score = game.scores["cam"]
                        cam.reload(wait_until="load", timeout=20000)
                        screen(cam, "question")
                        assert cam.evaluate("() => localStorage.getItem("
                            "'asgq-2026-rehearsal-participant')") == "qa-cam"
                        assert game.scores["cam"] == previous_score

                    # A changed response replaces the first choice, without
                    # earning any points before the host reveals.
                    if position == 1:
                        cam.locator('[data-answer="1"]').click()
                        cam.locator('[data-answer="0"]').click()
                        with game.lock:
                            assert game.answers[position]["cam"] == 0
                            assert game.scores["cam"] == 0
                    elif position % 2 == 1:
                        cam.locator('[data-answer="0"]').click()
                    else:
                        cam.locator('[data-answer="1"]').click()

                    # Nina intentionally skips each multiple of five.
                    if position % 5 != 0:
                        nina.locator(
                            '[data-answer="0"]' if position % 3 == 0
                            else '[data-answer="1"]').click()

                    refresh(host)
                    if position % 5 == 0:
                        assert host.locator('#answer-counter .waiting-name').all_inner_texts() == [
                            "Nina"]
                        host.locator('[data-next-phase]').click()
                        host.locator('[data-confirm-reveal]').click()
                    else:
                        assert "Tout le monde a répondu" in host.locator(
                            '#answer-counter').inner_text()
                        host.locator('[data-next-phase]').click()
                    screen(host, "reveal")
                    screen(cam, "reveal")
                    screen(nina, "reveal")
                    assert host.locator('.response-breakdown .response-person').count() == 2
                    assert cam.locator('.reveal-explanation').is_visible()
                    assert cam.locator('[data-next-phase]').count() == 0
                    check_no_overflow(cam, f"verdict {position} iPhone 375")
                    check_no_overflow(nina, f"verdict {position} Android 320")

                    with game.lock:
                        assert game.phase == "reveal"
                        assert len(game.revealed) == position
                        # One event, exactly one award per correct participant.
                        assert game.scores["cam"] == (position + 1) // 2
                        expected_nina = sum(
                            1 for n in range(1, position + 1)
                            if n % 5 != 0 and n % 3 == 0)
                        assert game.scores["nina"] == expected_nina

                    # A stale duplicate button/request must not move twice.
                    if position == 1:
                        stale = host.evaluate("""() =>
                            api.rpc('asgq_rehearsal_advance', {
                              p_token:'qa-host',
                              p_expected_phase:'question', p_expected_position:1
                            })""")
                        assert stale["error"] is not None
                        with game.lock:
                            assert game.phase == "reveal"

                    if position == 20:
                        host.locator('[data-next-phase]').click()
                        screen(host, "finished")
                        screen(cam, "finished")
                        screen(nina, "finished")
                        break

                    host.locator('[data-next-phase]').click()
                    if position == 10:
                        screen(host, "halftime")
                        screen(cam, "halftime")
                        with game.lock:
                            assert game.phase == "halftime"
                            assert game.scores["cam"] == 5
                        # The halftime is held until an explicit host click.
                        assert cam.locator('[data-next-phase]').count() == 0
                        host.locator('[data-next-phase]').click()
                    screen(host, "question")
                    screen(cam, "question")
                    screen(nina, "question")

                with game.lock:
                    assert game.phase == "finished"
                    assert game.scores == {"cam": 10, "nina": 5}
                    assert len(game.revealed) == 20
                    assert len(game.answers) == 20
                assert "Camille" in host.locator('.champion-name').inner_text()
                assert "Camille" in cam.locator('.champion-name').inner_text()
                assert host.locator('[data-next-phase]').count() == 0
                for name, page, errors in (
                    ("animateur", host, host_errors),
                    ("Camille", cam, cam_errors),
                    ("Nina", nina, nina_errors),
                ):
                    assert not errors, f"{name}: JavaScript errors {errors}"
                    check_no_overflow(page, name)
                host.screenshot(path=str(OUT / "asgq-dress-01-host-podium.png"),
                                full_page=True)
                cam.screenshot(path=str(OUT / "asgq-dress-02-guest-podium.png"),
                               full_page=True)
                print("ASGQ_DRESS: PASS — 3 independent browser contexts, "
                      "20 questions, 2 halves, 40 results, no early auto-reveal, "
                      "re-vote, offline/online, refresh and persistent scores.")
            finally:
                for ctx, _, _ in devices:
                    ctx.close()
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    run()
