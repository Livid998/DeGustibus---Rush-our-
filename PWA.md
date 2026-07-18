# DeGustibus PWA

## Creare la build

Da PowerShell, nella cartella del progetto:

```powershell
.\BUILD_PWA.ps1
```

I file pronti da pubblicare vengono creati in `builds/pwa`.

La cartella contiene anche `build-info.json`, con data UTC, versione di Godot,
commit e stato sorgente (`clean`, `dirty` oppure `unknown`). In GitHub Actions il
commit coincide con `GITHUB_SHA` e lo stato è sempre registrato esplicitamente
come pulito; in locale lo script cerca sia Git installato sia il runtime Git
fornito da Codex, senza inventare `dirty=true` quando Git non è disponibile.

## Provarla nella rete locale

```powershell
.\START_PWA_PREVIEW.ps1
```

Lo script mostra l'indirizzo da aprire sul PC e sul tablet. Il gioco è testabile via HTTP nella rete locale; l'installazione PWA, l'uso offline e gli aggiornamenti richiedono invece che la build sia pubblicata tramite HTTPS.

## Aggiornamenti senza reinstallazione

Pubblicare ogni nuova cartella `builds/pwa` allo stesso indirizzo HTTPS. La PWA installata:

- controlla automaticamente gli aggiornamenti all'avvio, quando torna in primo piano e periodicamente;
- mostra `Aggiorna e riavvia` quando la nuova versione è pronta;
- offre anche `Impostazioni > Controlla aggiornamenti`;
- conserva il salvataggio locale durante l'aggiornamento.

Non cambiare dominio o percorso pubblico tra una versione e l'altra e non cancellare i dati del sito, altrimenti il browser la considererà un'installazione diversa o eliminerà il salvataggio.

## Uso offline e prova reale

Il service worker mette subito in cache shell, manifest, build-info e icone.
I due file pesanti del gioco (`index.wasm` e `index.pck`) vengono invece salvati
mentre il gioco li usa, evitando un download bloccante di circa 70 MB durante
l'installazione del worker.

Alla prima installazione la pagina può ricaricarsi automaticamente una volta:
è il worker appena attivato che prende il controllo della scheda. Attendere che
la mappa torni utilizzabile prima di chiudere la pagina o togliere la rete.

Per verificare una nuova build su `localhost`:

1. avviare `START_PWA_PREVIEW.ps1 -NoBuild` e aprire il gioco, aspettando che la
   mappa sia utilizzabile e che l'eventuale riavvio automatico sia concluso;
2. se non è già avvenuto il riavvio automatico, ricaricare una volta con il
   server ancora acceso e aspettare di nuovo la mappa: questo è il secondo caricamento,
   ora controllato dal service worker;
3. spegnere il server;
4. ricaricare la stessa scheda. La mappa deve avviarsi anche a server spento.

Usare sempre la stessa origine (protocollo, host e porta) per tutti e tre i
passaggi. Il primo caricamento installa il worker; il secondo garantisce che
WASM e PCK passino dal worker attivo. Una nuova porta crea invece un'origine e
una cache separate.

## Pubblicazione automatica su GitHub Pages

Il workflow `.github/workflows/deploy-pwa.yml` esporta e pubblica automaticamente la PWA a ogni push rilevante sul ramo `main`.

La prima volta, nel repository GitHub aprire `Settings > Pages` e scegliere `GitHub Actions` come sorgente. Dopo il successivo push o un avvio manuale da `Actions > Pubblica PWA`, il gioco sarà disponibile all'indirizzo Pages mostrato dal job di pubblicazione.

## Installazione su iPad/iPhone

Aprire l'indirizzo HTTPS in Safari, usare `Condividi` e scegliere `Aggiungi alla schermata Home`.

La PWA non blocca l'orientamento: può essere usata in portrait su telefono e
tablet oppure in landscape su tablet e desktop. La barra inferiore mostra
quattro destinazioni principali e `Altro` a 390x844 e 412x915; da 800 px in su
mostra direttamente tutte le sezioni. I target verificati sono:

- 390x844;
- 412x915;
- 800x1024;
- 1280x720;
- 1366x768.

Le schermate gestionali vengono mantenute in memoria: cambiare sezione conserva
scroll e selezione. Recensioni, personale, statistiche operative e countdown del
mercato aggiornano soltanto i controlli interessati.

## Modalita sicura su iPad

La build Web riconosce automaticamente i dispositivi mobili e riduce il carico della GPU. Se iOS segnala comunque `WebGL context lost`, la pagina esegue una sola volta il riavvio in modalita sicura, con risoluzione 3D e frequenza ridotte.

La modalita sicura puo essere attivata manualmente aggiungendo `?safe=1` alla fine dell'indirizzo della PWA. Prima di riprovare, chiudere le altre schede o applicazioni Web 3D aperte. Non cancellare i dati del sito: contengono anche il salvataggio locale.

## Verifica prima della pubblicazione

`BUILD_PWA.ps1` interrompe l'export se falliscono l'audit dei glifi, lo smoke
test responsive o la verifica del flusso di aggiornamento. Anche il workflow
GitHub Pages esegue la suite completa prima di caricare l'artifact. Dopo
l'export, la CI verifica inoltre orientamento `any`, icone PNG 192×192 e
512×512, file runtime, strategia di cache e dimensione finale.

Ogni export genera una nuova versione del service worker. Quando una build è
pronta compare `Aggiorna e riavvia`; il worker in attesa prende il controllo,
la pagina si ricarica una sola volta e il salvataggio locale resta nello stesso
origin.

Gli atlanti sorgente usati per produrre le icone restano versionati nel
repository, ma non vengono inseriti nel PCK distribuito. Nella build rimangono
solo gli atlanti trasparenti e le icone effettivamente caricate dal gioco.
