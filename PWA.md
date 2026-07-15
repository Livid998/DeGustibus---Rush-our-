# DeGustibus PWA

## Creare la build

Da PowerShell, nella cartella del progetto:

```powershell
.\BUILD_PWA.ps1
```

I file pronti da pubblicare vengono creati in `builds/pwa`.

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

## Pubblicazione automatica su GitHub Pages

Il workflow `.github/workflows/deploy-pwa.yml` esporta e pubblica automaticamente la PWA a ogni push rilevante sul ramo `main`.

La prima volta, nel repository GitHub aprire `Settings > Pages` e scegliere `GitHub Actions` come sorgente. Dopo il successivo push o un avvio manuale da `Actions > Pubblica PWA`, il gioco sarà disponibile all'indirizzo Pages mostrato dal job di pubblicazione.

## Installazione su iPad/iPhone

Aprire l'indirizzo HTTPS in Safari, usare `Condividi` e scegliere `Aggiungi alla schermata Home`.

## Modalita sicura su iPad

La build Web riconosce automaticamente i dispositivi mobili e riduce il carico della GPU. Se iOS segnala comunque `WebGL context lost`, la pagina esegue una sola volta il riavvio in modalita sicura, con risoluzione 3D e frequenza ridotte.

La modalita sicura puo essere attivata manualmente aggiungendo `?safe=1` alla fine dell'indirizzo della PWA. Prima di riprovare, chiudere le altre schede o applicazioni Web 3D aperte. Non cancellare i dati del sito: contengono anche il salvataggio locale.
