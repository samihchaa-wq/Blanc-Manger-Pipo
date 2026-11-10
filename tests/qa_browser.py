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
window.__qaRehearsalBots = [];
window.__qaRehearsalStarted = false;
window.supabase = {
  createClient: () => ({
    rpc: async (name, args) => {
      window.__qaCalls.push({name, args});
      if (name === 'get_full_state') {
        return {data:{state:JSON.parse(JSON.stringify(window.__qaState)),
                      white:window.__qaWhite || null,pun:null,
                      qcm:window.__qaState.qcm ? JSON.parse(JSON.stringify(window.__qaState.qcm)) : null},error:null};
      }
      // QCM Grinta: the browser sees the REAL UI; mocked server drives a host lobby.
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
        page.locator('[data-entry-mode="join"]').click()
        assert page.locator('#admin-password').count()==0
        assert page.locator('#room-code[inputmode="numeric"]').count()==1
        page.locator('#room-code').fill('12345678')
        page.locator('#player-name').fill('Alban')
        page.locator('#join-button').click()
        page.wait_for_function("() => window.__qaCalls?.some(c=>c.name==='asgq_rehearsal_join_room') === true")
        args=page.evaluate("() => window.__qaCalls.find(c=>c.name==='asgq_rehearsal_join_room').args")
        assert args=={"p_code":"12345678","p_name":"Alban"},args
        assert page.locator('[data-act="qcm-new"]').count()==0
        # Le bouton X est accessible depuis la page de connexion, sans commencer la partie.
        page.locator('a.brand-back').click()
        page.wait_for_url(base+'/',timeout=10000)
        assert page.locator('#c-mode').input_value()=='qcm'
        assert page.locator('.seg.games button.on[data-v="qcm"]').count()==1
        assert page.locator('[data-act="create"]').is_visible()
        no_errors(page,errors,"qcm-acces-as-grinta")
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
        page.locator('[data-entry-mode="join"]').click()
        assert page.locator('.stage-welcome img.presenter-photo').get_attribute('src')=='./presenters/thinking.png', "Accueil rejoindre : expression réfléchie"

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

        page.evaluate("""() => renderFinished({
          is_host:false,me:{id:'guest',name:'Camille'},
          standings:[{id:'guest',name:'Camille',score:10}]
        })""")
        assert page.locator('.stage-podium img.presenter-photo').get_attribute('src')=='./presenters/trophy.png', "Podium : le trophée du champion"

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
        assert presenter_layout['width']>=125 and presenter_layout['height']>=185, f"Animateur encore trop petit : {presenter_layout}"
        assert presenter_layout['right']<=presenter_layout['titleLeft']+6, f"Animateur non positionné à gauche : {presenter_layout}"
        assert presenter_layout['bottom']<=presenter_layout['panelTop']+12, f"Animateur masque la carte du vestiaire : {presenter_layout}"
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

    # Les invités de la répétition utilisent le code de salon à 8 chiffres,
    # sans jamais connaître le mot de passe Admin+.
    ctx=browser.new_context(viewport={"width":375,"height":812},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e:errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/?repetition=1&code=00123456",wait_until="load",timeout=20000)
        assert page.locator('#room-code').input_value()=="00123456"
        assert page.locator('#admin-password').count()==0
        page.locator('#player-name').fill('Camille')
        page.locator('#join-button').click()
        page.wait_for_function("() => window.__qaCalls?.some(c=>c.name==='asgq_rehearsal_join_room') === true")
        args=page.evaluate("() => window.__qaCalls.find(c=>c.name==='asgq_rehearsal_join_room').args")
        assert args=={"p_code":"00123456","p_name":"Camille"},args
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

    # Un lien d'invitation sélectionne « Rejoindre » et pré-remplit le code.
    ctx=browser.new_context(viewport={"width":375,"height":812},reduced_motion="reduce",service_workers="block")
    page=ctx.new_page()
    errors=[]
    page.on("pageerror",lambda e:errors.append(str(e)))
    page.route("**/vendor/supabase.js",
               lambda route:route.fulfill(status=200,content_type="application/javascript",body=MOCK_SDK))
    try:
        page.goto(base+"/grinta-quiz/?code=00012345",wait_until="load",timeout=20000)
        assert page.locator('#room-code').input_value()=="00012345"
        assert page.locator('#admin-password').count()==0
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
