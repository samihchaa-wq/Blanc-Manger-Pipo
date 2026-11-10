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
// Preserve mock RPC history across the home-to-quiz page navigation.
window.__qaCalls = JSON.parse(sessionStorage.getItem('__qaCalls') || '[]');
window.__qaRehearsalBots = [];
window.__qaRehearsalStarted = false;
window.supabase = {
  createClient: () => ({
    rpc: async (name, args) => {
      window.__qaCalls.push({name, args});
      sessionStorage.setItem('__qaCalls',JSON.stringify(window.__qaCalls));
      if (name === 'get_full_state') {
        return {data:{state:JSON.parse(JSON.stringify(window.__qaState)),
                      white:window.__qaWhite || null,pun:null,
                      qcm:window.__qaState.qcm ? JSON.parse(JSON.stringify(window.__qaState.qcm)) : null},error:null};
      }
      // Official recovery restores the original host; a wrong password changes nothing.
      if (name === 'asgq_recover_host') {
        if (args.p_password !== 'SECRET-TEST')
          return {data:{error:'Mot de passe Admin+ incorrect.'},error:null};
        return {data:{token:'recovered-host-token',name:'Alban',code:'87654321'},error:null};
      }
      if (name === 'asgq_issue_player_handoff') {
        return {data:{name:'Camille',code:'00112233',minutes:10},error:null};
      }
      if (name === 'asgq_claim_player_handoff') {
        if(args.p_room_code==='87654321' && args.p_player_name==='Nina' && args.p_handoff_code==='00112233')
          return {data:{token:'guest-restored-token',name:'Nina',code:'87654321'},error:null};
        return {data:{error:'Code de récupération incorrect ou expiré.'},error:null};
      }
      if (name === 'asgq_state') {
        const guest=args.p_token==='guest-restored-token';
        return {data:{
          phase:'lobby',title:'Grand Quiz AS Grinta',ready:false,room_code:'87654321',
          first_half_count:10,second_half_count:10,position:0,
          players:[{id:'host',name:'Alban',is_host:true},...(guest?[{id:'guest-restored',name:'Nina',is_host:false}]:[])],
          standings:null,max_players:30,
          me:guest?{id:'guest-restored',name:'Nina',score:8}:{id:'host',name:'Alban',score:0},
          is_host:!guest
        },error:null};
      }
      // QCM Grinta: the browser sees the REAL UI; mocked server drives a host lobby.
      if (name === 'asgq_room_mode') {
        return {data:args.p_code === '12345678' ? 'rehearsal'
          : args.p_code === '87654321' ? 'official' : null,error:null};
      }
      if (name === 'asgq_rehearsal_join_room' || name === 'asgq_join_room') {
        if(name === 'asgq_join_room' && args.p_name==='Nina')
          return {data:{error:'Les inscriptions sont closes.'},error:null};
        return {data:{token:'guest-token',code:args.p_code},error:null};
      }
      if (name === 'asgq_rehearsal_create') {
        window.__qaRehearsalBots=[];
        window.__qaRehearsalStarted=false;
        return {data:{token:'host-token',code:'00123456'},error:null};
      }
      if (name === 'asgq_rehearsal_add_bot') {
        const n=window.__qaRehearsalBots.length+1;
        const bot={id:'bot-'+n,name:'Bot '+String(n).padStart(2,'0'),is_bot:true};
        window.__qaRehearsalBots.push(bot);
        return {data:{name:bot.name,bots:n},error:null};
      }
      if (name === 'asgq_rehearsal_remove_bot') {
        window.__qaRehearsalBots=window.__qaRehearsalBots.filter(bot=>bot.id!==args.p_bot_id);
        return {data:{removed:args.p_bot_id},error:null};
      }
      if (name === 'asgq_rehearsal_start') {
        window.__qaRehearsalStarted=true;
        return {data:null,error:null};
      }
      if (name === 'asgq_rehearsal_state') {
        const start=window.__qaRehearsalStarted?new Date(Date.now()+60000).toISOString():null;
        const players=[{id:'host',name:'Alban',is_bot:false},...window.__qaRehearsalBots];
        return {data:{
          phase:'lobby',title:'Grand Quiz AS Grinta',ready:true,room_code:'00123456',
          now:new Date().toISOString(),starts_at:start,phase_started_at:start,phase_until:null,
          players,standings:null,max_players:30,is_host:true,
          me:{id:'host',name:'Alban',score:0}
        },error:null};
      }
      // QCM : création, choix et enregistrement d'un quiz simulés.
      if (name === 'qcm_quiz_create') return {data:{id:'quiz-neuf',key:'ABCD-EFGH-JKMN',title:args.p_title,questions:[]},error:null};
      if (name === 'qcm_select') return {data:{id:'quiz-neuf',title:'Mon quiz',count:0},error:null};
      if (name === 'qcm_quiz_get') return {data:{id:'quiz-1',key:args.p_key,title:'Fin de saison',
        questions:[{text:'Qui a marqué le plus de buts ?',choices:['Karim','Théo'],correct:1,points:1,note:null}]},error:null};
      if (name === 'qcm_quiz_save') return {data:{id:'quiz-neuf',key:args.p_key,title:args.p_title,questions:args.p_questions},error:null};
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
    # Données représentatives des phases, pour piloter les VRAIS boutons.
    if game=="phrases":
        s["question"]="Ce soir, je pense à ____."
        s["question_choices"]=[{"id":i,"text":"Je rêve de ____."} for i in range(1,6)]
        s["blanks"]=1
        s["my_cards"]=[]
        s["me"]["can_discard"]=False
        s["hand"]=[{"id":i,"text":"un pantalon rouge"} for i in range(1,8)]
        for p in players:p["submitted"]=False
    if game=="priorites":
        s["rank_cards"]=[{"id":i,"text":"Carte numéro "+str(i)} for i in range(1,6)]
        s["my_ranking"]=None
        for p in players:p["ranked"]=False
    if game=="ondes":
        s["wave"]={"left":"Très mauvais","right":"Très bon","clue":"Une soirée agréable",
                   "target":None,"my_guess":None,"guesses":[]}
        for p in players:p["guessed"]=False
    if game=="bac":
        s["bac"]={"categories":["Animaux","Villes","Pays","Métiers","Objets","Prénoms"],
                   "letter":"P","done":False,"mine":[""]*6}
        for p in players:p["bac_done"]=False
    if game=="mimes":
        s["mime"]={"action":"Courir après un bus","low":"très lentement",
                   "high":"très vite","mine":8,
                   "parts":[{"player_id":"p1","intensity":8},
                            {"player_id":"p2","intensity":4}]}
        r["mime_index"]=0
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
    if game=="qcm":
        # L'hôte (p0) anime : lui seul voit la bonne réponse avant la révélation.
        fin=phase in ("reveal","finished")
        s["qcm"]={"variant":"classique","quiz":{"title":"Fin de saison","count":3,
                                                "id":"quiz-1" if role=="host" else None}}
        if phase!="lobby":
            s["qcm"].update({"position":1,"total":3,"text":"Qui a marqué le plus de buts cette saison ?",
                "choices":["Karim","Yanis","Théo","Malik"],"points":2,
                "correct":2 if (role=="host" or fin) else None,
                "note":"Théo : 14 buts !" if (role=="host" or fin) else None,
                "my_choice":None,"answered":["p2"],
                "answers":[{"player_id":"p1","choice":2,"points":3,"bonus":True},
                           {"player_id":"p2","choice":0,"points":0,"bonus":False}] if fin else None})
        if phase=="finished":
            players[0]["score"]=0; players[1]["score"]=7; players[2]["score"]=4
            r["winner_id"]="p1"
    return s, white

def open_page(browser, base, game=None, role="host", n=3, phase="lobby",
              width=375, height=812, invite=False):
    context=browser.new_context(viewport={"width":width,"height":height},
                                device_scale_factor=1,
                                reduced_motion="reduce",
                                service_workers="block")
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
    else:
        # Un visiteur arrive sans session, puis entre dans un salon simulé.
        # Le mock doit donc aussi avoir un état auquel le connecter.
        state,white=fixture("phrases",role="guest",n=3)
        page.add_init_script("window.__qaState = "+json.dumps(state,ensure_ascii=False)+";"
                             "window.__qaWhite = "+json.dumps(white,ensure_ascii=False)+";")
    url=base+("/?code=00123456" if invite else "/")
    page.goto(url,wait_until="load",timeout=20000)
    if game:
        page.wait_for_function("() => document.querySelector('.lobbytop') || "
                               "document.querySelector('.bigstate') || "
                               "document.querySelector('.role') || "
                               "document.querySelector('.bachead')", timeout=10000)
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
            assert page.locator(".seg.games button").count()==len(GAMES)+1
            # Les barres mobiles font varier la hauteur accordée à l'accueil.
            # Les images des jeux restent exactement de même taille en y revenant.
            def icon_sizes():
                return page.eval_on_selector_all(
                    ".seg.games img",
                    "(els) => els.map(el => parseFloat(getComputedStyle(el).width))"
                )
            original=icon_sizes()
            assert len(original)==len(GAMES)+1 and max(original)-min(original)<0.1, "Colonnes d'icônes de tailles inégales"
            # Les illustrations doivent être à nu : aucun cartouche papier, padding,
            # bordure ou ombre, même pour le jeu sélectionné.
            def tiles():
                return page.eval_on_selector_all(".seg.games button", """els => els.map(el => {
                    const s=getComputedStyle(el), b=el.getBoundingClientRect();
                    return {x:b.x,y:b.y,w:b.width,h:b.height,transform:s.transform,
                            border:s.borderTopWidth,padding:s.paddingTop,
                            background:s.backgroundColor,shadow:s.boxShadow}
                })""")
            def clean(icons):
                for icon in icons:
                    assert icon["transform"]=="none", icon
                    assert icon["border"]=="0px", icon
                    assert icon["padding"]=="0px", icon
                    assert icon["shadow"]=="none", icon
                    assert icon["background"] in ("rgba(0, 0, 0, 0)", "transparent"), icon
            before=tiles()
            clean(before)
            for home_height in ["550px", "1100px"]:
                page.evaluate("(h) => document.documentElement.style.setProperty('--home-h',h)",home_height)
                assert icon_sizes()==original, f"Vignettes instables avec --home-h={home_height}"
            page.evaluate("document.documentElement.style.removeProperty('--home-h')")
            page.locator('[data-act="mode"][data-v="mimes"]').click()
            assert icon_sizes()==original, "Changer de jeu ne doit pas redimensionner les icônes"
            # Vérifier chaque jeu, y compris les descriptions les plus longues :
            # aucun changement de hauteur du descriptif ne doit déplacer la grille.
            for mode in (g for g in GAMES if g != 'qcm'):
                page.locator(f'[data-act="mode"][data-v="{mode}"]').click()
                after=tiles()
                clean(after)
                for prev,cur in zip(before,after):
                    for prop in ("x","y","w","h"):
                        assert abs(prev[prop]-cur[prop])<0.2, (
                            f"Vignette déplacée/agrandie après sélection de {mode} : "
                            f"{prop}, {prev} -> {cur}")
                assert page.locator(f'.seg.games button.on[data-v="{mode}"]').count()==1
                assert page.locator('.seg.games button[aria-pressed="true"]').count()==1
            page.locator('[data-act="mode"][data-v="mimes"]').click()
            page.reload(wait_until="load")
            page.evaluate("document.fonts.ready")
            page.wait_for_function("""expected => {
              const actual=[...document.querySelectorAll('.seg.games img')]
                .map(el=>parseFloat(getComputedStyle(el).width));
              return actual.length===expected.length &&
                actual.every((size,i)=>Math.abs(size-expected[i])<0.2);
            }""",arg=original,timeout=7000)
            page.locator('[data-act="tab"][data-tab="join"]').click()
            assert page.locator("#pane-join").is_visible()
            page.locator("#j-code").fill("00123456")
            assert page.locator("#j-code").input_value()=="00123456"
            no_horizontal_overflow(page,f"accueil-{width}")
            no_errors(page,errors,f"accueil-{width}")
            checks+=1
        finally:ctx.close()

    # Le QCM est un jeu de test complet : la vignette reste un choix
    # de jeu comme les autres : elle n'ouvre pas encore de nouvelle page.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('#c-name').fill('Alban')
        page.locator('[data-act="mode"][data-v="qcm"]').click()
        assert page.url==base+'/', "La vignette QCM ne doit jamais ouvrir le quiz"
        assert page.locator('#c-mode').input_value()=='qcm'
        assert page.locator('.seg.games button.on[data-v="qcm"]').count()==1
        assert 'QCM' in page.locator('#c-pitch').inner_text()
        assert page.locator('[data-act="create"]').is_visible()
        # Ce n'est que l'appui sur « Créer la partie » qui ouvre l'écran Grinta.
        page.locator('[data-act="create"]').click()
        page.wait_for_url("**/grinta-quiz/?repetition=1&action=create",timeout=10000)
        assert page.locator('#player-name').input_value()=='Alban'
        assert page.locator('#admin-password[type="password"]').count()==1
        assert page.locator('#room-code').count()==0
        assert "ADMIN+" in page.locator("main").inner_text()
        assert page.locator('[data-entry-mode]').count()==0, "Plus d'option Rejoindre sur l'écran AS Grinta"
        assert page.get_by_text("Entre dans l’émission").count()==0, "L'ancienne phrase doit disparaître"
        assert page.locator('[data-act="qcm-new"]').count()==0
        page.locator('a.brand-back').click()
        page.wait_for_url(base+'/',timeout=10000)
        assert page.locator('#c-mode').input_value()=='qcm'
        assert page.locator('.seg.games button.on[data-v="qcm"]').count()==1

        # Guests enter exclusively through the original Soulieteur join pane.
        page.locator('[data-act="tab"][data-tab="join"]').click()
        page.locator('#j-name').fill('Alban')
        page.locator('#j-code').fill('12345678')
        page.locator('[data-act="join"]').click()
        page.wait_for_url("**/grinta-quiz/?repetition=1",timeout=10000)
        assert page.evaluate("() => localStorage.getItem('asgq-2026-rehearsal-participant')")=="guest-token", "Code du Soulieteur non rattaché au quiz"
        assert page.locator('#room-code').count()==0, "Pas de deuxième écran de saisie du code"
        assert page.locator('[data-entry-mode]').count()==0, "Pas de mode Rejoindre dans le quiz"
        no_errors(page,errors,"qcm-acces-as-grinta")
        checks+=1
    finally:ctx.close()

    # Une question Grinta doit être une vraie séquence de plateau, pas quatre boutons génériques.
    # Test visuel sur 320 et 390 px ; aucun chronomètre et aucune obstruction des réponses.
    ctx=browser.new_context(viewport={"width":390,"height":844},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e:errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/?repetition=1",wait_until="load",timeout=20000)
        sample={
            "position":3,"half":1,"first_half_count":10,"second_half_count":10,
            "is_host":False,"me":{"id":"guest","name":"Camille","score":3},
            "players":[{"id":"host","name":"Alban","is_host":True},
                       {"id":"guest","name":"Camille","is_host":False}],
            "question":{"text":"Quel joueur a marqué le but décisif lors du dernier match ?",
                        "choices":["L'attaquant de pointe","Le gardien","Le défenseur central","Le milieu de terrain"],
                        "correct":0,"my_choice":2,"earned":0}
        }
        for width in (320,390):
            page.set_viewport_size({"width":width,"height":750})
            page.evaluate("(s) => renderQuestion(s)",sample)
            assert page.locator('.question-card-top').is_visible(), "Carte question sans identité club"
            assert page.locator('.question-card-index').inner_text()=="Q03", "Numéro de question de type émission manquant"
            assert page.locator('.show-progress-dot').count()==20, "Le parcours des 20 questions doit être représenté par 20 points"
            assert page.locator('.show-progress-dot.passed').count()==3, "La progression ne correspond pas à la question affichée"
            assert page.locator('.question-card .show-emblem').is_visible(), "Emblème de football décoratif absent"
            if width==390:page.screenshot(path=str(OUT/'asgq-show-03-question.png'),full_page=True)
            assert page.locator('.choices > button.choice').count()==4, "Les quatre réponses doivent rester disponibles"
            assert page.locator('button.choice.selected[data-answer="2"]').count()==1, "Sélection du joueur non identifiable"
            assert page.locator('button.choice[aria-pressed="true"]').count()==1, "État sélectionné incorrect"
            assert page.locator('[data-next-phase]').count()==0, "Un invité ne doit pas voir les commandes de l'animateur"
            assert page.locator('.big-timer, .timer-line').count()==0, "Aucun chronomètre autorisé"
            assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth+2"), "Question débordante sur mobile"
            geometry=page.evaluate("""() => {
              const card=document.querySelector('.question-card').getBoundingClientRect();
              const answer=document.querySelector('.choices').getBoundingClientRect();
              const buttons=[...document.querySelectorAll('.choices .choice')].map(el=>{
                const r=el.getBoundingClientRect();
                return {left:r.left,right:r.right,width:r.width};
              });
              return {cardBottom:card.bottom,choicesTop:answer.top,buttons};
            }""")
            assert geometry['choicesTop']>=geometry['cardBottom']-1, f"Les réponses chevauchent la question : {geometry}"
            assert all(x['left']>=0 and x['right']<=width+2 and x['width']>=width*.70
                       for x in geometry['buttons']), f"Réponses coupées ou trop étroites : {geometry}"
        # Long real-world text must scroll vertically rather than be cropped horizontally.
        page.set_viewport_size({"width":320,"height":690})
        sample["question"]["text"]="Dans la finale du championnat, quel joueur de l'équipe a marqué le but décisif après une action collective particulièrement longue et un centre venu du côté droit ?"
        sample["question"]["choices"][2]="Le défenseur central ayant disputé son vingt-cinquième match de la saison"
        page.evaluate("(s) => renderQuestion(s)",sample)
        assert page.evaluate("() => document.documentElement.scrollWidth<=innerWidth+2"), "Le texte long ne doit pas provoquer de débordement"
        assert page.locator('.choices > button.choice').count()==4, "Les choix longs restent disponibles"
        sample["question"]["text"]="Quel joueur a marqué le but décisif lors du dernier match ?"
        sample["question"]["choices"][2]="Le défenseur central"
        page.set_viewport_size({"width":390,"height":844})
        sample["is_host"]=True
        sample["question"]["my_choice"]=None
        page.evaluate("(s) => renderQuestion(s)",sample)
        assert page.locator('[data-next-phase]').is_visible(), "Le maître du jeu a perdu son bouton de révélation"
        assert page.locator('.choice.readonly').count()==4, "Le maître du jeu ne doit pas répondre"
        # The host receives exact server-computed pending names, without guessing from scores.
        sample["question"]["waiting_players"]=[
            {"id":"guest","name":"Camille"},{"id":"g2","name":"Nina"},{"id":"g3","name":"Sam"}
        ]
        page.evaluate("(s) => renderQuestion(s)",sample)
        assert page.locator('#answer-counter .waiting-title').inner_text()=="On attend :", "Le compteur 0/3 doit devenir « On attend : »"
        assert page.locator('#answer-counter .waiting-name').all_inner_texts()==["Camille","Nina","Sam"], "Les noms des joueurs doivent apparaître"
        assert page.locator('#answer-counter').get_attribute('aria-live')=="polite", "État d'attente non accessible"
        sample["question"]["waiting_players"]=[{"id":"g3","name":"Sam"}]
        page.evaluate("(s) => renderQuestion(s)",sample)
        assert page.locator('#answer-counter .waiting-name').all_inner_texts()==["Sam"], "Les joueurs ayant répondu doivent disparaître de l'attente"
        sample["question"]["waiting_players"]=[]
        page.evaluate("(s) => renderQuestion(s)",sample)
        assert page.locator('#answer-counter').inner_text()=="Tout le monde a répondu !", "Message de fin d'attente absent"
        assert page.locator('[data-next-phase]').is_visible(), "Révélation toujours sous contrôle de l'animateur"
        assert page.evaluate("() => document.documentElement.scrollWidth<=innerWidth+2"), "Les noms ne doivent pas provoquer de défilement horizontal"


        sample["is_host"]=False
        sample["question"]["my_choice"]=0
        sample["standings"]=[{"id":"guest","name":"Camille","score":4}]
        page.evaluate("(s) => renderReveal(s)",sample)
        assert page.locator('.answer-reveal-label').is_visible(), "Révélation non mise en scène"
        assert page.locator('.answer-reveal strong').inner_text()=="L'attaquant de pointe", "Texte de bonne réponse modifié"
        assert page.locator('.small-list .rank-no').first.inner_text()=="01", "Classement façon panneau de score absent"
        assert page.locator('.answer-reveal-tick').is_visible(), "Bonne réponse sans pictogramme"
        assert page.locator('.reveal-question p').inner_text()==sample['question']['text'], "Le verdict doit rappeler la question"
        sample["question"]["explanation"]="La bonne réponse se vérifie après la révélation."
        sample["question"]["my_choice"]=2  # Wrong answer: test the personal correction.
        page.evaluate("(s) => renderReveal(s)",sample)
        assert page.locator('.reveal-explanation').is_visible(), "L'explication vérifiée doit apparaître sur le verdict"
        assert page.locator('.personal-answer strong').inner_text()=="Le défenseur central", "La mauvaise réponse personnelle doit être rappelée"
        sample["question"]["my_choice"]=0
        # Le classement cumulatif ne doit pas servir à deviner les résultats de la manche.
        assert page.locator('.response-breakdown').count()==0, "Ne rien inventer si le serveur ne fournit pas la liste"
        sample["question"]["responses"]=[
            {"id":"guest","name":"Camille","status":"correct"},
            {"id":"g2","name":"Sam","status":"incorrect"},
            {"id":"g3","name":"Nina","status":"unanswered"}
        ]
        page.evaluate("(s) => renderReveal(s)",sample)
        assert page.locator('.response-group--correct .response-person').all_inner_texts()==["Camille"], "Joueurs ayant bien répondu incorrects"
        assert page.locator('.response-group--incorrect .response-person').all_inner_texts()==["Sam"], "Joueurs ayant mal répondu incorrects"
        assert page.locator('.response-group--unanswered .response-person').all_inner_texts()==["Nina"], "Joueurs sans réponse absents"
        assert page.evaluate("() => getComputedStyle(document.querySelector('.response-groups')).gridTemplateColumns.split(' ').length===1"), "Sur iPhone, les catégories du verdict doivent rester lisibles en pleine largeur"
        page.screenshot(path=str(OUT/'asgq-show-04-verdict.png'),full_page=True)
        assert [v.strip() for v in page.locator('.response-group-count').all_inner_texts()]==["1","1","1"]
        assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth+2"), "Les noms débordent de l'écran"
        assert page.locator('.small-list .rank-no').first.inner_text()=="01", "Classement initial altéré"
        sample["is_host"]=True
        page.evaluate("(s) => renderReveal(s)",sample)
        assert page.locator('[data-next-phase]').is_visible(), "Le maître du jeu doit pouvoir avancer"
        assert page.locator('.response-breakdown .response-person').count()==3, "Le maître du jeu doit voir tous les résultats"
        no_errors(page,errors,"qcm-plateau-as-grinta")
        checks+=1
    finally:ctx.close()

    # Les 12 expressions réelles doivent être montrées sur les bons écrans,
    # pas uniquement référencées par des chemins de fichiers.
    ctx=browser.new_context(viewport={"width":390,"height":844},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e:errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/?repetition=1",wait_until="load",timeout=20000)
        assert page.locator('.stage-welcome img.presenter-photo').get_attribute('src')=='./presenters/thumbs.png', "Accueil création : expression accueillante"
        assert page.locator('.stage-welcome .entry-title').inner_text().replace('\n',' ').startswith('PRÊT POUR'), "Titre de la maquette d'accueil absent"
        assert page.evaluate("() => getComputedStyle(document.querySelector('#join-button')).borderRadius === '999px'"), "Bouton doré de la maquette absent"
        page.screenshot(path=str(OUT/'asgq-show-01-accueil.png'),full_page=True)
        assert page.locator('[data-entry-mode]').count()==0, "Le quiz ne propose plus un second mode Rejoindre"
        assert page.get_by_text("Entre dans l’émission").count()==0, "Le sous-titre inutile a été retiré"

        for position, choice, expected in [
            (1,0,'amazed'),(2,0,'thumbs'),(3,0,'laughter'),
            (1,1,'facepalm'),(2,1,'skeptical'),
            (1,None,'surprised'),(2,None,'confused')
        ]:
            page.evaluate("""(params) => {
              const s={
                phase:'reveal',is_host:false,position:params.position,half:1,
                first_half_count:10,second_half_count:10,
                me:{id:'guest',name:'Camille',score:2},
                players:[{id:'host',name:'Alban',is_host:true},{id:'guest',name:'Camille',is_host:false}],
                standings:[{id:'guest',name:'Camille',score:2}],
                question:{text:'Question exemple',choices:['Oui','Non','Peut-être','Jamais'],
                          correct:0,my_choice:params.choice,earned:params.choice===0?1:0}
              };
              renderReveal(s);
            }""",{"position":position,"choice":choice})
            picture=page.locator('.stage-reveal img.presenter-photo')
            assert picture.get_attribute('src')=='./presenters/'+expected+'.png', f"Expression incohérente pour position {position}, réponse {choice} : {expected}"
            page.wait_for_function("""() => {
              const photo=document.querySelector('.stage-reveal img.presenter-photo');
              return photo && photo.complete && photo.naturalWidth===1024 && photo.naturalHeight===1536;
            }""")

        page.evaluate("""() => renderHalftime({
          is_host:false,me:{id:'guest',name:'Camille'},
          standings:[{id:'guest',name:'Camille',score:5}]
        })""")
        assert page.locator('.stage-halftime img.presenter-photo').get_attribute('src')=='./presenters/thinking.png', "Mi-temps : réflexion, pas déception"
        assert page.locator('.halftime-board-title').inner_text().startswith('APRÈS'), "Résumé mi-temps absent"
        assert page.locator('.halftime-stat-title').inner_text()=='LE CHIFFRE DE LA PREMIÈRE MI-TEMPS', "Encart statistique absent"
        page.screenshot(path=str(OUT/'asgq-show-05-mi-temps.png'),full_page=True)

        page.evaluate("""() => renderFinished({
          is_host:false,me:{id:'guest',name:'Camille'},
          standings:[{id:'guest',name:'Camille',score:10}]
        })""")
        assert page.locator('.stage-podium img.presenter-photo').get_attribute('src')=='./presenters/trophy.png', "Podium : le trophée du champion"
        assert page.locator('.stage-podium h2').inner_text()=='CHAMPION DU QUIZ', "Le titre de finale ne correspond pas à la maquette"
        assert page.locator('.pod .pod-crown').count()==1, "La couronne du gagnant doit être affichée"
        assert page.locator('.champion-name').is_visible(), "Le nom du champion doit être mis en valeur"
        assert page.locator('.champion-name').inner_text().casefold()=="camille", "Le nom du vrai champion doit être affiché"
        page.screenshot(path=str(OUT/'asgq-show-06-podium.png'),full_page=True)
        page.evaluate("""() => renderFinished({
          is_host:false,me:{id:'p4',name:'Alex'},
          standings:[
            {id:'p1',name:'Camille',score:12},
            {id:'p2',name:'Nina',score:12},
            {id:'p3',name:'Sam',score:10},
            {id:'p4',name:'Alex',score:10}
          ]
        })""")
        assert page.locator('.stage-podium h2').inner_text()=="CHAMPIONS DU QUIZ", "Une égalité doit être annoncée au pluriel"
        assert "camille" in page.locator('.champion-name').inner_text().casefold() and "nina" in page.locator('.champion-name').inner_text().casefold(), "Tous les champions à égalité doivent être annoncés"
        assert page.locator('.pod .step').all_inner_texts()==["1","1","3"], "Le podium doit respecter les ex æquo 1, 1, 3"
        assert page.locator('.small-list .rank-no').first.inner_text()=="3e", "Le rang d'une égalité hors podium doit rester partagé"
        page.screenshot(path=str(OUT/'asgq-show-06b-ex-aequo.png'),full_page=True)

        # Many-person lobby moves the roster to a full-width panel.
        page.evaluate("""() => renderLobby({
          me:{id:'host'},is_host:true,room_code:'00123456',ready:true,max_players:30,
          players:[{id:'host',name:'Alban',is_host:true},...Array.from({length:20},(_,i)=>({
            id:'p'+i,name:'Participant '+(i+1),is_host:false
          }))]
        })""")
        assert page.locator('.lobby-roster-panel').is_visible(), "Grand vestiaire non adapté aux 20 joueurs"
        assert page.locator('.lobby-roster-panel .roster li').count()==21, "Un participant disparaît du vestiaire"
        assert "JOUEURS (20)" in page.locator('.lobby-roster-panel').inner_text(), "L'animateur ne doit pas compter parmi les joueurs"
        assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth+2"), "Le vestiaire large déborde de l'écran"

        page.evaluate("() => renderLostSession()")
        assert page.locator('.lost-session .recovery-link').is_visible(), "Une session perdue ne doit pas proposer le formulaire Admin+ à l'invité"
        assert page.locator('#admin-password').count()==0, "La récupération d'un invité ne doit pas demander Admin+"
        page.evaluate("() => showNetworkProblem(true)")
        assert page.locator('#network-status').is_visible(), "L'état de connexion interrompue doit rester visible"
        page.evaluate("() => showNetworkProblem(false)")
        assert page.locator('#network-status').is_hidden(), "Le bandeau doit disparaître après reconnexion"
        no_errors(page,errors,"qcm-expressions-coherentes")
        checks+=1
    finally:ctx.close()

    # Partie complète de test : création Admin+, puis bots ajoutés dans le salon.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('#c-name').fill('Alban')
        page.locator('[data-act="mode"][data-v="qcm"]').click()
        page.locator('[data-act="create"]').click()
        page.wait_for_url("**/grinta-quiz/?repetition=1&action=create",timeout=10000)
        assert page.locator('.crest-authentic img').is_visible(), "Écusson officiel AS Grinta absent"
        assert page.locator('.stage-welcome .presenter-photo').is_visible(), "Animateur d’accueil absent"
        assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth + 2"), "Débordement horizontal sur mobile"
        assert page.evaluate("() => document.querySelector('.brand-back').getBoundingClientRect().top >= 0"), "Sortie du quiz inaccessible"
        assert page.locator(".rehearsal-banner").count()==1
        assert page.locator('#bots-count').count()==0
        assert 'CRÉER LA PARTIE' in page.locator('#join-form').inner_text()
        page.locator('#player-name').fill('Alban')
        page.locator('#admin-password').fill('SECRET-TEST')
        page.locator('#join-button').click()
        page.wait_for_function("() => window.__qaCalls?.some(c=>c.name==='asgq_rehearsal_create') === true")
        args=page.evaluate("() => window.__qaCalls.find(c=>c.name==='asgq_rehearsal_create').args")
        assert args=={"p_bots":0,"p_password":"SECRET-TEST","p_name":"Alban"},args
        page.locator('[data-add-bot]').wait_for(state='visible')
        assert page.locator('.stage-lobby .presenter-confident .presenter-photo').is_visible(), "L'animateur du vestiaire est absent"
        presenter_layout=page.evaluate("""() => {
          const portrait=document.querySelector('.stage-lobby .presenter-photo').getBoundingClientRect();
          const title=document.querySelector('.stage-lobby .stage-copy').getBoundingClientRect();
          const panel=document.querySelector('.lobby-panel').getBoundingClientRect();
          return {width:portrait.width,height:portrait.height,left:portrait.left,right:portrait.right,
                  titleLeft:title.left,bottom:portrait.bottom,panelTop:panel.top};
        }""")
        page.wait_for_function("() => { const img=document.querySelector('.stage-lobby img.presenter-photo'); return img && img.complete && img.naturalWidth===1024 && img.naturalHeight===1536; }")
        assert page.locator('.stage-lobby img[src="./presenters/arms.png"]').is_visible(), "Photo source haute définition non chargée"
        assert presenter_layout['width']>=180 and presenter_layout['height']>=260, f"Animateur de la maquette encore trop petit : {presenter_layout}"
        assert presenter_layout['left'] < presenter_layout['titleLeft']+10, f"Animateur absent de la gauche du vestiaire : {presenter_layout}"
        assert page.evaluate("() => getComputedStyle(document.querySelector('.stage-lobby .presenter-shot')).pointerEvents === 'none'"), "Photo ne doit jamais bloquer les boutons"
        assert page.evaluate("""() => {
          const r=document.querySelector('.lobby-panel').getBoundingClientRect();
          const b=document.querySelector('.invite-button').getBoundingClientRect();
          return r.left>10 && b.right<=r.right+2;
        }"""), "Le code de salle et le bouton Inviter doivent rester lisibles et à l'intérieur du panneau"
        page.screenshot(path=str(OUT/'asgq-show-02-vestiaire.png'),full_page=True)
        assert page.locator('.roster .avatar').count()==0, "Les joueurs ne doivent plus avoir d'icône ronde"
        assert page.locator('main a.quiet-link').count()==0, "Le lien RETOUR AUX JEUX ne doit plus être affiché"
        assert page.locator('a.brand-back').is_visible(), "La croix de sortie doit rester accessible"
        assert page.evaluate("() => getComputedStyle(document.querySelector('.brand')).backgroundColor === 'rgba(0, 0, 0, 0)'"), "Le bandeau supérieur ne doit plus avoir de couleur différente"
        assert page.locator('[data-start-quiz]').is_disabled()
        page.locator('[data-add-bot]').click()
        page.locator('[data-remove-bot]').first.wait_for(state='visible')
        assert page.locator('.roster .host-label, .roster .bot-label').count()==0, "Ne pas afficher les badges maître du jeu ou bot"
        page.locator('[data-add-bot]').click()
        page.wait_for_function("() => document.querySelectorAll('[data-remove-bot]').length===2")
        page.locator('[data-remove-bot]').last.click()
        page.wait_for_function("() => document.querySelectorAll('[data-remove-bot]').length===1")
        assert page.locator('[data-start-quiz]').is_enabled()
        page.locator('[data-start-quiz]').click()
        page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='asgq_rehearsal_start')")
        assert page.locator('a.brand-back[href="../"]').is_visible()
        # Même pendant les répétitions, la sortie reste disponible.
        assert page.locator('a.brand-back[href="../"]').is_visible()
        page.locator('a.brand-back').click()
        page.wait_for_url(base+'/',timeout=10000)
        assert page.locator('#pane-create').is_visible()
        no_errors(page,errors,"qcm-repetition-bots-creer")
        checks+=1
    finally:ctx.close()

    # Les invités du quiz utilisent l'onglet Rejoindre du Soulieteur.
    # Aucune redemande de code ni de mot de passe Admin+ dans le Grand Quiz.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('[data-act="tab"][data-tab="join"]').click()
        page.locator('#j-name').fill('Camille')
        page.locator('#j-code').fill('12345678')
        page.locator('[data-act="join"]').click()
        page.wait_for_url("**/grinta-quiz/?repetition=1",timeout=10000)
        assert page.evaluate("() => localStorage.getItem('asgq-2026-rehearsal-participant')")=="guest-token", "Le joueur doit rejoindre le quiz depuis l'accueil Soulieteur"
        assert page.locator('#admin-password').count()==0, "Le mot de passe Admin+ n'est pas pour les joueurs"
        assert page.locator('#room-code').count()==0, "Le code ne doit jamais être redemandé"
        calls=page.evaluate("() => window.__qaCalls.filter(c=>c.name==='asgq_room_mode' || c.name==='asgq_rehearsal_join_room')")
        assert calls[0]=={"name":"asgq_room_mode","args":{"p_code":"12345678"}}, calls
        assert calls[1]=={"name":"asgq_rehearsal_join_room","args":{"p_code":"12345678","p_name":"Camille"}}, calls
        no_errors(page,errors,"qcm-repetition-rejoindre")
        checks+=1
    finally:ctx.close()

    # La création est distincte de la participation et utilise l'Admin+.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('#c-name').fill('Alban')
        page.locator('[data-act="mode"][data-v="qcm"]').click()
        assert page.locator('[data-act="create"]').is_visible()
        page.locator('[data-act="create"]').click()
        page.wait_for_url("**/grinta-quiz/?repetition=1&action=create",timeout=10000)
        page.locator('#player-name').fill('Alban')
        page.locator('#admin-password').fill('SECRET-TEST')
        page.locator('#join-button').click()
        page.wait_for_function("() => window.__qaCalls?.some(c=>c.name==='asgq_rehearsal_create') === true")
        args=page.evaluate("() => window.__qaCalls.find(c=>c.name==='asgq_rehearsal_create').args")
        assert args=={"p_bots":0,"p_password":"SECRET-TEST","p_name":"Alban"},args
        no_errors(page,errors,"qcm-creation-admin")
        checks+=1
    finally:ctx.close()

    # L'animateur d'une partie officielle déjà créée peut reprendre avec Admin+.
    # Un invité ne reçoit toujours jamais de rôle animateur via le code du salon.
    ctx=browser.new_context(viewport={"width":390,"height":844},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e: errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/",wait_until="load",timeout=20000)
        page.locator('[data-host-recovery]').click()
        assert page.locator('[data-screen="recover-host"]').is_visible(), "Reprise animateur non accessible"
        assert page.locator('#player-name').count()==0, "La reprise ne doit pas créer de nouveau pseudo"
        page.locator('#recovery-admin-password').fill('BAD')
        page.locator('#recover-host-form button[type="submit"]').click()
        page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='asgq_recover_host' && x.args.p_password==='BAD')")
        assert page.evaluate("() => localStorage.getItem('asgq-2026-participant')") is None, "Un mot de passe incorrect ne doit pas récupérer l'animateur"
        page.locator('#recovery-admin-password').fill('SECRET-TEST')
        page.locator('#recover-host-form button[type="submit"]').click()
        page.wait_for_function("() => localStorage.getItem('asgq-2026-participant')==='recovered-host-token'")
        assert page.locator('[data-screen="lobby"]').is_visible(), "L'animateur doit retrouver le vestiaire sans recréer une partie"
        assert page.locator('.roster li').count()==1, "La reprise ne doit pas créer de nouveau joueur"
        # After an existing guest joins, the host can issue a one-time rescue code.
        page.evaluate("""() => {
          state.players.push({id:'guest',name:'Camille',is_host:false});
          renderState(true);
        }""")
        page.locator('.host-access summary').click()
        page.locator('[data-issue-player-code="guest"]').click()
        page.locator('.handoff-code').wait_for(state='visible')
        assert page.locator('.handoff-code').inner_text()=="00112233", "Code unique absent des outils animateur"
        assert page.evaluate("() => window.__qaCalls.some(c=>c.name==='asgq_issue_player_handoff' && c.args.p_host_token==='recovered-host-token' && c.args.p_player_id==='guest')"), "Un code de secours doit être délivré par le jeton animateur"
        no_errors(page,errors,"qcm-reprise-animateur")
        checks+=1
    finally:ctx.close()

    # Un joueur perdant son jeton peut retrouver son identite + score avec le
    # code temporaire emis par l'animateur, sans second formulaire dans le quiz.
    ctx,page,errors=open_page(browser,base)
    try:
        page.locator('[data-act="tab"][data-tab="join"]').click()
        page.locator('#j-name').fill('Nina')
        page.locator('#j-code').fill('87654321')
        page.locator('[data-act="join"]').click()
        page.locator('#asgq-recovery-panel').wait_for(state='visible')
        assert page.locator('#asgq-recovery-code').count()==1, "Le code de secours n'est pas accessible dans Le Soulieteur"
        page.locator('#asgq-recovery-code').fill('00112233')
        page.locator('[data-act="asgq-recover"]').click()
        page.wait_for_url("**/grinta-quiz/",timeout=10000)
        assert page.evaluate("() => localStorage.getItem('asgq-2026-participant')")=="guest-restored-token", "La session restauree doit etre sauvegardee"
        assert page.locator('.host-access').count()==0, "Un invite ne doit pas voir les outils de recuperation animateur"
        assert page.locator('#admin-password').count()==0, "Un invite ne doit jamais demander le mot de passe Admin+"
        no_errors(page,errors,"qcm-reprise-invite")
        checks+=1
    finally:ctx.close()

    # Changer de jeu depuis un salon ne crée pas non plus de QCM générique.
    ctx,page,errors=open_page(browser,base,game="phrases")
    try:
        page.locator('[data-act="game-pick"]').click()
        page.locator('[data-act="set-game"][data-v="qcm"]').click()
        page.wait_for_url("**/grinta-quiz/",timeout=10000)
        assert page.locator('#admin-password[type="password"]').count()==1
        assert page.locator('#room-code').count()==0
        no_errors(page,errors,"qcm-depuis-salon")
        checks+=1
    finally:ctx.close()

    # Un ancien salon QCM déjà ouvert est redirigé à la nouvelle porte d'entrée.
    legacy, _ = fixture("qcm")
    ctx = browser.new_context(viewport={"width":375,"height":812},reduced_motion="reduce",service_workers="block")
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    page.add_init_script("if (!location.pathname.includes('/grinta-quiz/')) localStorage.setItem('pdcat'," +
                         json.dumps(json.dumps({"code":"00123456","token":"host-token"})) + ");")
    page.add_init_script("window.__qaState = "+json.dumps(legacy,ensure_ascii=False)+";window.__qaWhite = null;")
    try:
        page.goto(base+"/",wait_until="load",timeout=20000)
        page.wait_for_url("**/grinta-quiz/",timeout=10000)
        assert page.locator('#admin-password[type="password"]').count()==1
        assert page.locator('#room-code').count()==0
        assert page.evaluate("localStorage.getItem('pdcat')") is None
        no_errors(page,errors,"qcm-ancien-salon")
        checks+=1
    finally:ctx.close()

    # Un ancien lien d'invitation au quiz renvoie vers l'accueil Soulieteur
    # avec son code, puis se connecte directement après le prénom.
    ctx=browser.new_context(viewport={"width":375,"height":812},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e:errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/?code=87654321",wait_until="load",timeout=20000)
        page.wait_for_url("**/?code=87654321",timeout=10000)
        assert page.locator('#pane-join').is_visible(), "Le lien devrait ouvrir l'onglet rejoindre du Soulieteur"
        assert page.locator('#j-code').input_value()=="87654321", "L'invitation doit préremplir le code"
        page.locator('#j-name').fill('Camille')
        page.locator('[data-act="join"]').click()
        page.wait_for_url("**/grinta-quiz/",timeout=10000)
        assert page.evaluate("() => localStorage.getItem('asgq-2026-participant')")=="guest-token", "Participation officielle non transférée"
        no_errors(page,errors,"qcm-invitation-code")
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

    # Exercices complets de boutons : les véritables écouteurs JS déclenchent
    # les RPC mockés, dont on inspecte la charge utile exacte.
    for game,phase,role,do,width in [
        (g,p,r,k,w) for (g,p,r,k) in [
        ("phrases","answering","guest","phrases"),
        ("priorites","ranking","guest","priorites"),
        ("ondes","guessing","guest","ondes"),
        ("bac","writing","guest","bac"),
        ("mimes","mime_play","host","mimes"),
        ("dico","dico_vote","guest","dico"),
        ("dilemme","dilemme_vote","guest","dilemme"),
        ("white","white_vote","guest","white"),
        ] for w in (320,430)
    ]:
        ctx,page,errors=open_page(browser,base,game=game,role=role,phase=phase,width=width)
        try:
            if do=="phrases":
                page.locator('[data-act="select"]').first.click()
                assert page.locator('[data-act="send"]').is_enabled()
                page.locator('[data-act="send"]').click()
                name="submit_answer"
            elif do=="priorites":
                for i in range(5):
                    page.locator('[data-act="rank"]').first.click()
                assert page.locator('[data-act="send-rank"]').is_enabled()
                page.locator('[data-act="send-rank"]').click()
                name="submit_ranking"
            elif do=="ondes":
                page.locator('[data-act="guess"]').click()
                name="submit_guess"
            elif do=="bac":
                for i in range(6):
                    page.locator("#bac-"+str(i)).fill("Pomme"+str(i))
                page.locator('[data-act="bac-done"]').click()
                name="bac_save"
            elif do=="mimes":
                page.locator('[data-act="mime-note"][data-id="p1"][data-v="8"]').click()
                page.locator('[data-act="mime-note"][data-id="p2"][data-v="6"]').click()
                assert page.locator('[data-act="mime-rate"]').is_enabled()
                page.locator('[data-act="mime-rate"]').click()
                name="mime_rate"
            elif do=="dico":
                assert page.locator('[data-act="dico-vote"][data-id="d2"]').is_disabled()
                page.locator('[data-act="dico-vote"][data-id="d1"]').click()
                name="dico_vote"
            elif do=="dilemme":
                page.locator('[data-act="dil-yn"][data-id="b1"][data-v="1"]').click()
                page.locator('[data-act="dil-yn"][data-id="b3"][data-v="0"]').click()
                assert page.locator('[data-act="dil-vote"]').is_enabled()
                page.locator('[data-act="dil-vote"]').click()
                name="dilemme_vote"
            elif do=="white":
                assert page.locator('[data-act="white-vote"][data-id="p1"]').count()==0
                page.locator('[data-act="white-vote"][data-id="p0"]').click()
                name="white_vote"
            page.wait_for_function("""name => window.__qaCalls.some(c=>c.name===name)""",
                                   arg=name, timeout=5000)
            calls=page.evaluate("""name => window.__qaCalls.filter(x=>x.name===name)""",name)
            args=calls[-1]["args"]
            if do=="priorites": assert args["p_cards"]==[1,2,3,4,5],args
            if do=="ondes": assert args["p_value"]==50,args
            if do=="bac":
                assert any(c["args"].get("p_done") is True
                    for c in calls),calls
            if do=="mimes":
                assert args["p_players"]==["p1","p2"] and args["p_notes"]==[8,6],args
            if do=="dilemme":
                assert args["p_buts"]==["b1","b3"] and args["p_yes"]==[True,False],args
            if do=="white": assert args["p_target"]=="p0",args
            no_horizontal_overflow(page,game+"-"+phase+"-"+str(width)+"-interactif")
            no_errors(page,errors,game+"-"+phase+"-"+str(width)+"-interactif")
            checks+=1
        except Exception:
            page.screenshot(path=str(OUT/(game+"-"+phase+"-"+str(width)+"-interactif.png")),full_page=True)
            raise
        finally:ctx.close()

    # Défis temporaires : véritables champs et callbacks de l'interface.
    for width in (320,390,430):
        # Phrases à trou : le lecteur écrit deux trous, les autres cartes ne bougent pas.
        ctx,page,errors=open_page(browser,base,game="phrases",role="host",
                                  phase="question_select",width=width)
        try:
            page.locator('[data-act="custom-phrase-open"]').click()
            page.locator('#custom-phrase').fill('____ rencontre ____')
            page.locator('[data-act="custom-phrase-send"]').click()
            page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='choose_custom_question')")
            calls=page.evaluate("() => window.__qaCalls.filter(x=>x.name==='choose_custom_question')")
            assert calls[-1]["args"]["p_text"]=="____ rencontre ____"
            no_horizontal_overflow(page,f"phrase-libre-{width}")
            no_errors(page,errors,f"phrase-libre-{width}")
            checks+=1
        finally:ctx.close()

        # Baromètre normal : les extrêmes ne changent jamais la cible.
        ctx,page,errors=open_page(browser,base,game="ondes",role="host",
                                  phase="clue",width=width)
        try:
            page.locator('[data-act="custom-wave-open"]').click()
            page.locator('#custom-wave-left').fill('Nul au foot')
            page.locator('#custom-wave-right').fill('Génie du ballon')
            page.locator('[data-act="custom-wave-send"]').click()
            page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='choose_custom_wave')")
            calls=page.evaluate("() => window.__qaCalls.filter(x=>x.name==='choose_custom_wave')")
            assert calls[-1]["args"]["p_left"]=="Nul au foot"
            assert calls[-1]["args"]["p_right"]=="Génie du ballon"
            no_horizontal_overflow(page,f"barometre-libre-{width}")
            no_errors(page,errors,f"barometre-libre-{width}")
            checks+=1
        finally:ctx.close()

        # Mimes : la carte reste invisible tant que le juge n'a pas choisi.
        ctx,page,errors=open_page(browser,base,game="mimes",role="host",
                                  phase="mime_play",width=width)
        try:
            page.evaluate("() => { window.__qaState.mime.ready=false; refresh(true) }")
            page.locator('[data-act="custom-mime-open"]').wait_for()
            page.locator('[data-act="custom-mime-open"]').click()
            page.locator('#custom-mime-action').fill('Manger un citron')
            page.locator('#custom-mime-low').fill('Délicieux')
            page.locator('#custom-mime-high').fill('Acide')
            page.locator('[data-act="custom-mime-send"]').click()
            page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='choose_mime_challenge')")
            calls=page.evaluate("() => window.__qaCalls.filter(x=>x.name==='choose_mime_challenge')")
            assert calls[-1]["args"]["p_custom"] is True
            assert calls[-1]["args"]["p_action"]=="Manger un citron"
            no_horizontal_overflow(page,f"mime-libre-{width}")
            no_errors(page,errors,f"mime-libre-{width}")
            checks+=1
        finally:ctx.close()

    # Le choix classique de Mimes utilise bien le même RPC, sans nouveau défi.
    ctx,page,errors=open_page(browser,base,game="mimes",role="host",phase="mime_play")
    try:
        page.evaluate("() => { window.__qaState.mime.ready=false; refresh(true) }")
        page.locator('[data-act="custom-mime-default"]').click()
        page.wait_for_function("() => window.__qaCalls.some(x=>x.name==='choose_mime_challenge')")
        calls=page.evaluate("() => window.__qaCalls.filter(x=>x.name==='choose_mime_challenge')")
        assert calls[-1]["args"]["p_custom"] is False
        no_errors(page,errors,"mime-classique")
        checks+=1
    finally:ctx.close()

    # Injection HTML malveillante : le contenu de joueurs et cartes doit
    # être affiché en texte et jamais interprété comme du code.
    payload='<img src="x" onerror="window.__qaInjected=true">'
    for game,phase,field,selector in [
        ("phrases","lobby","player",".plist"),
        ("phrases","answering","card",".hand"),
        ("dico","dico_vote","definition",".ddefs"),
    ]:
        role="guest" if phase!="lobby" else "host"
        ctx,page,errors=open_page(browser,base,game=game,role=role,phase=phase)
        try:
            page.evaluate("""([kind,txt]) => {
              window.__qaInjected=false;
              if (kind==='player') state.players[1].name=txt;
              if (kind==='card') state.hand[0].text=txt;
              if (kind==='definition') state.dico.defs[0].text=txt;
              if (kind==='quiz') state.qcm.choices[0]=txt;
              render();
            }""",[field,payload])
            assert page.locator(selector+' img[src="x"]').count()==0,"HTML exécuté : "+field
            assert page.evaluate("window.__qaInjected") is False,"XSS exécuté : "+field
            assert payload in page.locator(selector).inner_text(), "Texte mal échappé : "+field
            no_errors(page,errors,"injection-"+field)
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

    # Vrai cache PWA : pas de SDK mocké, vraies ressources statiques locales.
    # Premier chargement installe le service worker, le suivant peuple le cache.
    pwa_ctx=browser.new_context(viewport={"width":375,"height":812},
                                service_workers="allow",reduced_motion="reduce")
    pwa=pwa_ctx.new_page()
    pwa_errors=[]
    pwa.on("pageerror", lambda e:pwa_errors.append(str(e)))
    try:
        pwa.goto(base+"/",wait_until="load",timeout=15000)
        pwa.wait_for_function("() => !!navigator.serviceWorker?.controller",timeout=15000)
        pwa.reload(wait_until="load",timeout=15000)
        pwa.wait_for_function("""async () => {
          const c=await caches.open('soulieteur');
          const urls=(await c.keys()).map(k=>new URL(k.url).pathname);
          return ['/js/core.js','/js/actions.js','/vendor/supabase.js'].every(
            path=>urls.some(url=>url.endsWith(path)));
        }""",timeout=15000)
        pwa_ctx.set_offline(True)
        pwa.goto(base+"/",wait_until="domcontentloaded",timeout=15000)
        pwa.locator("#pane-create").wait_for(timeout=5000)
        assert pwa.locator(".seg.games button").count()==len(GAMES)+1,"Accueil hors ligne incomplet (QCM AS Grinta compris)"
        no_horizontal_overflow(pwa,"pwa-demarrage-hors-ligne")
        no_errors(pwa,pwa_errors,"pwa-demarrage-hors-ligne")
        pwa_ctx.set_offline(False)
        checks+=1
    except Exception:
        pwa.screenshot(path=str(OUT/"pwa-demarrage-hors-ligne.png"),full_page=True)
        raise
    finally:
        pwa_ctx.close()
    print(f"CHROMIUM QA OK : {checks} parcours navigateur, {len(GAMES)} jeux classiques + QCM AS Grinta, 5 tailles, rôles, invitation, vote, panne réseau et PWA hors connexion.")

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
