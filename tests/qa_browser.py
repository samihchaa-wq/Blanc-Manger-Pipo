#!/usr/bin/env python3
"""Tests E2E de l'interface réelle dans Chromium, backend Supabase remplacé par un mock.

Le serveur HTTP livre le vrai index et les vrais scripts/styles. Seul le SDK Supabase
est intercepté : ces tests ne sont PAS des tests d'intégration réseau réelle.
"""
import contextlib
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import pathlib
import threading
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "test-results" / "browser"
OUT.mkdir(parents=True, exist_ok=True)

class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

MOCK_SDK = r"""
window.__qaCalls = [];
window.supabase = {
  createClient: () => ({
    rpc: async (name, args) => {
      window.__qaCalls.push({name, args});
      if (name === 'get_full_state') {
        return {data:{state:JSON.parse(JSON.stringify(window.__qaState)),
                      white:window.__qaWhite || null,pun:null},error:null};
      }
      if (name === 'create_room') return {data:{code:'00123456',token:'host-token'},error:null};
      if (name === 'join_room') {
        return args.p_code === '00123456'
          ? {data:{code:'00123456',token:'guest-token'},error:null}
          : {data:{error:'Code incorrect ou salon introuvable.',error_code:'JOIN_REJECTED'},error:null};
      }
      return {data:null,error:null};
    },
    channel: () => ({
      state:'joined',
      on(){return this},
      subscribe(cb){setTimeout(() => cb('SUBSCRIBED'), 0);return this},
      send(){return Promise.resolve()},
    }),
    removeChannel(){return Promise.resolve()}
  })
};
"""

GAMES = ["phrases", "priorites", "ondes", "bac", "white", "mimes", "dico", "dilemme"]
SIZES = [320, 360, 375, 390, 430]
SAMPLE_NAMES = ["Aïcha", "Bastien", "Camille", "Dylan"]

def fixture(game, role="host", n=3, phase="lobby"):
    if game == "bac":
        n=2
    players = [{
        "id": "p"+str(i), "name":SAMPLE_NAMES[i % 4], "seat":i,
        "score":0,"active":True,"is_bot":False,"next_ack":None,
        "continue_requested":False
    } for i in range(n)]
    me_id = "p0" if role == "host" else "p1"
    r = {
        "id":"room-qa", "code":"00123456", "host_id":"p0",
        "reader_id":"p0", "status":phase, "mode":game,
        "round":1,"target":3,"turns":2,"time_mode":"unlimited",
        "phase_deadline":None,"phase_seconds":0,
        "white_cycle":1, "white_note":None, "winner_id":None,
        "rank_cards":[1,2,3,4,5], "wave_variant":"normal",
        "dilemme_variant":"aleatoire","phrases_variant":"normal",
        "bac_categories":["Animaux","Villes","Pays","Métiers","Objets","Noms"],
        "bac_letter":"P","bac_step":0,
    }
    s={"room":r, "players":players,
       "me":{"id":me_id, "next_ack":None,"continue_requested":False,"score":0},
       "question":"Pourquoi ?","submissions":[]}
    white=None
    if game=="white":
        alliance=phase=="reveal"
        roles=[
            {"player_id":"p0","out":False,"voted":False,"role":"civil" if alliance else None},
            {"player_id":"p1","out":False,"voted":False,"role":"undercover" if alliance else None},
            {"player_id":"p2","out":False,"voted":False,"role":"white" if alliance else None},
        ]
        white={
            "phase":phase,"roles":roles,"cycle":1,"starter_id":"p0",
            "role":None,"word":"MOT-PRIVÉ","note":None,"voted":False,
            "eliminated":False,"impostors_remaining":1,
            "last_eliminated":None,"winner":"alliance" if alliance else None,
            "civil_word":"MOT-CIVIL" if alliance else None,
            "undercover_word":"MOT-IMPOSTEUR" if alliance else None,
        }
    if game=="dico":
        s["dico"]={"word":"pomme","definition":None,"written":["p1","p2"],
                   "mine":None,"my_vote":None,"voted":[],
                   "defs":[{"id":"d1","text":"Fruit du pommier","mine":False},
                           {"id":"d2","text":"Animal volant","mine":True},
                           {"id":"d3","text":"Petit récipient","mine":False}]}
    if game=="dilemme":
        s["dilemme"]={"start":"Tu es riche","mine":"tu perds tes chaussettes",
                      "written":["p0","p1","p2"],"voted":[],
                      "my_target":{"voters":2,"yes":1,"pct":50},
                      "buts":[{"id":"b1","text":"tu cours partout","mine":False,"my_vote":None},
                              {"id":"b2","text":"tu fais la sieste","mine":True,"my_vote":None},
                              {"id":"b3","text":"tu bois de l'eau","mine":False,"my_vote":None}]}
    return s, white

def open_page(browser, base, game=None, role="host", n=3, phase="lobby",
              width=375, height=812, invite=False):
    context=browser.new_context(viewport={"width":width,"height":height},
                                device_scale_factor=1,
                                reduced_motion="reduce")
    page=context.new_page()
    errors=[]
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    if game:
        state,white=fixture(game,role,n,phase)
        page.add_init_script("localStorage.setItem('pdcat',"
                             + json.dumps(json.dumps({"code":"00123456",
                                                      "token": "host-token" if role=="host" else "guest-token"}))
                             + ");")
        page.add_init_script("window.__qaState = "+json.dumps(state,ensure_ascii=False)+";"
                             "window.__qaWhite = "+json.dumps(white,ensure_ascii=False)+";")
    url=base+("/?code=00123456" if invite else "/")
    page.goto(url,wait_until="load",timeout=20000)
    if game:
        page.wait_for_function("() => document.querySelector('.lobbytop') || "
                               "document.querySelector('.bigstate') || "
                               "document.querySelector('.role')", timeout=10000)
    else:
        page.locator("#pane-join" if invite else "#pane-create").wait_for(timeout=10000)
    return context,page,errors

def no_horizontal_overflow(page, label):
    x=page.evaluate("""() => ({
      viewport:document.documentElement.clientWidth,
      scroll:document.documentElement.scrollWidth,
      body:document.body.scrollWidth,
      window:innerWidth
    })""")
    if x["scroll"] > x["viewport"]+2:
        name=label.replace("/","-").replace(" ","-")
        page.screenshot(path=str(OUT/(name+".png")),full_page=True)
        raise AssertionError(f"{label}: dépassement horizontal {x}")

def no_errors(page, errors, label):
    if errors:
        page.screenshot(path=str(OUT/(label.replace("/","-")+".png")),full_page=True)
        raise AssertionError(f"{label}: erreur JS : {errors[:3]}")

def run(browser, base):
    checks=0
    # Accueil : cinq tailles réelles, saisie/onglets, et lien à huit chiffres.
    for width in SIZES:
        ctx,page,errors=open_page(browser,base,width=width)
        try:
            assert page.locator(".seg.games button").count()==8
            page.locator('[data-act="tab"][data-tab="join"]').click()
            assert page.locator("#pane-join").is_visible()
            page.locator("#j-code").fill("00123456")
            assert page.locator("#j-code").input_value()=="00123456"
            no_horizontal_overflow(page,f"accueil-{width}")
            no_errors(page,errors,f"accueil-{width}")
            checks+=1
        finally:ctx.close()

    # Sur tous les jeux, affichage vrai CSS et DOM du salon (hôte et invité).
    for game in GAMES:
        for width in [320,375,430]:
            ctx,page,errors=open_page(browser,base,game=game,width=width)
            try:
                assert page.locator(".bigcode .ch").count()==8
                assert page.locator(".bigcode").inner_text().replace("\n","").replace(" ","")=="00123456"
                assert page.locator("h2.sec").first.inner_text().startswith("Joueurs")
                assert page.locator('[data-act="start"]').is_visible()
                assert page.locator('[data-act="start"]').is_enabled()
                no_horizontal_overflow(page,f"salon-{game}-{width}")
                no_errors(page,errors,f"salon-{game}-{width}")
                checks+=1
            finally:ctx.close()

        ctx,page,errors=open_page(browser,base,game=game,role="guest")
        try:
            assert page.locator('[data-act="start"]').count()==0
            assert page.locator('[data-act="game-pick"]').count()==0
            no_horizontal_overflow(page,f"invite-{game}")
            no_errors(page,errors,f"invite-{game}")
            checks+=1
        finally:ctx.close()

    # Deux joueurs ne suffisent pas pour Mr White, confirmation du choix produit.
    ctx,page,errors=open_page(browser,base,game="white",n=2)
    try:
        assert page.locator('[data-act="start"]').is_disabled()
        assert "Il manque 1 joueur" in page.locator('[data-act="start"]').inner_text()
        no_errors(page,errors,"white-2")
        checks+=1
    finally:ctx.close()

    # Invitation avec zéros initiaux : la saisie et le RPC conservent le code complet.
    ctx,page,errors=open_page(browser,base,invite=True)
    try:
        assert page.locator("#pane-join").is_visible()
        assert page.locator("#j-code").input_value()=="00123456"
        page.locator("#j-name").fill("QA Invitée")
        page.locator('[data-act="join"]').click()
        page.wait_for_function("() => document.querySelector('.lobbytop')",timeout=10000)
        calls=page.evaluate("window.__qaCalls.filter(x => x.name==='join_room')")
        assert len(calls)==1 and calls[0]["args"]["p_code"]=="00123456",calls
        assert page.locator(".bigcode .ch").count()==8
        no_errors(page,errors,"invitation")
        checks+=1
    finally:ctx.close()

    # Code erroné : on reste à l'accueil, message reçu, aucune fausse connexion.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('[data-act="tab"][data-tab="join"]').click()
        page.locator("#j-code").fill("99999999")
        page.locator("#j-name").fill("QA Invité")
        page.locator('[data-act="join"]').click()
        page.wait_for_function("() => document.querySelector('#toast.on')",timeout=5000)
        assert "Code incorrect" in page.locator("#toast").inner_text()
        assert page.locator(".lobbytop").count()==0
        no_errors(page,errors,"code-invalide")
        checks+=1
    finally:ctx.close()

    # Mr White : la co-victoire doit être visible dans le VRAI écran de résultat.
    ctx,page,errors=open_page(browser,base,game="white",phase="reveal")
    try:
        assert page.locator(".role").filter(has_text="gagné ensemble").count()==1
        names=page.locator(".role").filter(has_text="gagné ensemble").inner_text()
        assert "Bastien" in names and "Camille" in names,names
        assert "Imposteur" in names and "Mr White" in names,names
        no_horizontal_overflow(page,"white-victoire")
        no_errors(page,errors,"white-victoire")
        checks+=1
    finally:ctx.close()

    # Les écrans de scrutin doivent présenter les vrais choix accessibles.
    for game,phase,button in [
        ("white","white_vote","white-vote"),
        ("dico","dico_vote","dico-vote"),
        ("dilemme","dilemme_vote","dil-yn"),
    ]:
        ctx,page,errors=open_page(browser,base,game=game,role="guest",phase=phase)
        try:
            assert page.locator('[data-act="'+button+'"]').count()>0,(game,page.locator("main").inner_text())
            no_horizontal_overflow(page,game+"-vote")
            no_errors(page,errors,game+"-vote")
            checks+=1
        finally:ctx.close()

    # Gestion de la PWA en vraie page Chromium : retour depuis hors ligne.
    ctx,page,errors=open_page(browser,base,game="phrases")
    try:
        page.context.set_offline(True)
        page.wait_for_timeout(100)
        assert "Connexion perdue" in page.locator("#toast").inner_text()
        page.context.set_offline(False)
        page.wait_for_timeout(300)
        assert page.locator(".bigcode .ch").count()==8
        no_errors(page,errors,"offline-online")
        checks+=1
    finally:ctx.close()
    print(f"CHROMIUM QA OK : {checks} parcours navigateur, 8 jeux, 5 tailles, rôles, invitation, vote, panne réseau.")

def main():
    handler=functools.partial(QuietHandler,directory=str(ROOT))
    server=ThreadingHTTPServer(("127.0.0.1",0),handler)
    t=threading.Thread(target=server.serve_forever,daemon=True)
    t.start()
    try:
        with sync_playwright() as p:
            browser=p.chromium.launch(channel="chrome",headless=True,args=["--no-sandbox"])
            try:
                run(browser,f"http://127.0.0.1:{server.server_address[1]}")
            finally: browser.close()
    finally:
        server.shutdown()
        server.server_close()

if __name__=="__main__":main()
