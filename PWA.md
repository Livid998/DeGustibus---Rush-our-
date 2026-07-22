# DeGustibus PWA — build, verifica e release

La closed beta Web usa l'export Godot **PWA no-thread**. PC e iPad ricevono lo
stesso artifact: la CI lo esporta una sola volta, lo verifica, lo prova in
Chromium e WebKit e solo dopo lo rende pubblicabile. Il test fisico di 60 minuti
su iPad resta intenzionalmente un gate umano.

## Build locale

Da PowerShell, nella cartella del progetto:

```powershell
.\BUILD_PWA.ps1 -Release closed-beta-candidate
```

Una build release richiede Git disponibile e un repository pulito. Esegue la
matrice autorevole `tools/release/test_matrix.txt`, compresi soak e dieci nuove
partite fino al giorno 3, poi esporta in `builds/pwa`. Per una verifica rapida
non pubblicabile durante lo sviluppo:

```powershell
.\BUILD_PWA.ps1 -DebugBuild -Fast
```

`build-info.json` contiene `commit`, `godot_version`, `built_at_utc`, `release`
e `dirty`. Soltanto un export release con `dirty:false` supera il verificatore
pubblicabile. I limiti hard sono:

- artifact totale: 65 MiB;
- `index.wasm`: 42 MiB;
- `index.pck`: 25 MiB.

Il superamento di un solo limite interrompe la build; non viene pubblicato un
artifact fuori budget.

## Prova nella rete locale

```powershell
.\START_PWA_PREVIEW.ps1 -NoBuild
```

Lo script mostra l'indirizzo da aprire su PC e tablet. HTTP nella rete locale è
utile per il gameplay; installazione, offline e aggiornamenti richiedono HTTPS
(oppure localhost sullo stesso computer).

## Aggiornamenti senza reinstallazione

Pubblicando la nuova build sullo stesso origin, la PWA:

- cerca un aggiornamento all'avvio, tornando in primo piano e periodicamente;
- mostra `Aggiorna e riavvia` quando il worker nuovo è pronto;
- offre `Impostazioni > Controlla aggiornamenti`;
- conserva il salvataggio locale durante l'aggiornamento.

Il flusso no-thread e il service worker controllato non cambiano. Non cambiare
dominio o percorso e non cancellare i dati del sito.

## Verifica offline locale

Il service worker precachea shell, manifest, build-info e icone. WASM e PCK
entrano nella cache durante il caricamento controllato:

1. avviare la preview e attendere che la mappa sia utilizzabile;
2. ricaricare una volta con il server attivo: è il **secondo caricamento**;
3. chiudere il server;
4. ricaricare la stessa origine con il **server spento**.

La mappa deve riaprirsi. Cambiare porta crea un'origine e una cache diverse.

## Pipeline GitHub Actions

`.github/workflows/deploy-pwa.yml` separa cinque responsabilità:

1. `verify`: test core, M0, M1, M2 e M3, soak breve e 10 fresh-run;
2. `export`: checkout pulito, export unico, metadati e budget hard;
3. `reuse`: recupero opzionale di un artifact precedente per rollback;
4. `browser-smoke`: stesso artifact in Chromium e WebKit;
5. `deploy`: pubblicazione test oppure gate iPad beta, senza re-export.

Un push su `main` produce e conserva per 90 giorni artifact ed evidence e, se
tutti i gate automatici sono verdi, aggiorna Pages come **build di test**. La
build di test non equivale a una closed beta approvata. Per pubblicare una beta
ufficiale aprire `Actions > Verifica e pubblica PWA > Run workflow`, impostare:

- `release`: versione della closed beta;
- `publish`: attivo;
- `channel`: `beta`;
- `ipad_evidence`: link o ID dell'evidence del test fisico;
- `rollback_run_id`: vuoto per una build nuova.

Per ripubblicare manualmente una build di prova usare invece `channel: test`:
in questo canale l'evidence iPad non viene richiesta e il riepilogo del run la
identifica esplicitamente come build non promossa.

Impostare `Settings > Pages > Source: GitHub Actions`. È consigliato aggiungere
anche un reviewer obbligatorio all'environment `github-pages`: l'input evidence
non sostituisce la revisione umana.

### Rollback

Gli artifact `pwa-release-ready` sono conservati per 90 giorni. Per ripubblicare
una versione, avviare manualmente il workflow indicando il suo `run_id` in
`rollback_run_id`, `publish=true`, `channel=beta` e l'evidence iPad relativa a
quell'artifact.
La pipeline non ricompila: rivalida budget/metadati, ripete Chromium/WebKit e
pubblica gli stessi byte.

## Gate fisico iPad da 60 minuti

Questo gate non è automatizzato e non va dichiarato superato senza una sessione
reale. Registrare in un ticket o report:

- release, commit, modello iPad, versione iPadOS e browser/modalità Home Screen;
- ora iniziale/finale e 60 minuti continuativi di gioco reale;
- nessun `webglcontextlost`, freeze o ricaricamento spontaneo;
- p50/p95 frame time (e relativo frame rate) e memoria a fine warm-up e fine sessione dalla diagnostica
  locale; crescita memoria inferiore al 10% e nessun degrado progressivo;
- almeno un servizio, chiusura, salvataggio, ricarica e cambio schermata;
- secondo avvio online e riapertura offline dalla stessa installazione;
- screenshot iniziale/finale e diagnostica locale esportata.

Solo dopo allegare il link/ID in `ipad_evidence` e approvare l'environment.

## Installazione e target responsive

Su iPad/iPhone aprire l'URL HTTPS in Safari, scegliere `Condividi` e
`Aggiungi alla schermata Home`. La PWA supporta portrait e landscape. I target
QA sono 390x844, 412x915, 800x1024 e 1280x720 (più 1366x768 desktop).

Se iOS segnala `WebGL context lost`, la shell prova una sola ripartenza sicura.
La modalità sicura è anche attivabile con `?safe=1`; prima chiudere altre schede
WebGL. Non cancellare i dati del sito, perché contengono il salvataggio locale.
