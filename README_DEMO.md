# DeGustibus - Rush Hour

Gestionale casual di ristorazione 3D isometrico realizzato in Godot 4.7 con
renderer Mobile, eseguibile su desktop e come PWA su tablet e smartphone. Il
progetto usa gli asset forniti dall’utente e un set coerente di icone
trasparenti per ingredienti, ricette, navigazione e sistemi gestionali.

## Avvio

1. Apri `project.godot` con Godot 4.7 o successivo e premi F6/F5.
2. In alternativa esegui `RUN_DEMO.ps1` da PowerShell.
3. Alla prima apertura attendi l’importazione dei file GLTF/GLB e delle texture.
4. Per la versione installabile esegui `BUILD_PWA.ps1`; vedi `PWA.md`.

Nel workspace di sviluppo lo script rileva anche il runtime locale in `..\.tools\godot-4.7`.

## Comandi

- Trascinamento con tasto sinistro, centrale o destro: sposta la mappa.
- Trascinamento con un dito: sposta la mappa; pinch: zoom.
- Click/tap: selezione; pressione prolungata touch: apre le azioni contestuali.
- Rotella mouse: zoom.
- `R`: ruota l’anteprima di 90°; `Esc`: annulla anteprima o selezione.
- `1`, `2`, `4`: velocità simulazione; `F12`: pannello debug.

## Loop giocabile

A ristorante chiuso puoi modificare pavimenti, pareti, porte, pass, sala e cucina. Il builder mostra griglia, footprint, costo, validità e motivo dell’errore; permette selezione, spostamento, rotazione, vendita, conferma e annullamento. Durante il servizio restano modificabili soltanto piante e decorazioni non bloccanti.

Le pagine gestionali sono schermate complete e persistenti: Ristorante, Menu,
Album, Magazzino, Mercato, Personale, Statistiche e Impostazioni. L’Album è la
collezione permanente usata per imparare ricette; il Magazzino gestisce invece
scorte consumabili, capacità ambiente/refrigerata, prenotazioni e consegne in
batch. Su telefono la barra mostra quattro sezioni principali e `Altro`.

Aprendo il locale, gruppi da uno a quattro clienti entrano, occupano sedie reali distinte, ordinano un piatto ciascuno e generano task produttivi data-driven. Cuochi e camerieri prenotano task e postazioni, percorrono la griglia, eseguono le fasi, portano i piatti al pass, servono, incassano e liberano il tavolo.

## Sistemi principali

- Griglia 18×14 con pathfinding sensibile ai bordi: pareti, porte e finestre occupano i lati delle celle senza sottrarre spazio alle attrezzature.
- Camera ortografica isometrica con pan mouse/touch, pinch e limiti di zoom/movimento.
- Ciclo giorno/notte persistente, fasce orarie, rush naturali, pausa e velocità 1x/2x/4x.
- 20 ingredienti con icone illustrate trasparenti e centrate, rarità 1–5, 12 sbloccati iniziali e progressione permanente tramite obiettivi, reputazione, acquisto e stazioni.
- Album separato dallo stock, costi di apprendimento ricette, ricompense seedable e pity persistente.
- 13 semilavorati acquistabili o prodotti: quelli acquistati sostituiscono realmente le fasi `preppable` e preservano lo stock crudo.
- 12 ricette a più fasi, 13 tipi di postazione, capacità, code, dipendenze, priorità e prenotazione esclusiva.
- Qualità piatto 0–100, difetti contestuali rari, rifacimento automatico o cambio ordine recuperabile.
- Menu illustrato con prezzo, costo, margine, tempo, ingredienti mancanti, postazioni, popolarità e carico previsto.
- Pass con icone ricetta, tavolo, tempo, componenti mancanti, sospensione/ripresa e priorità.
- Magazzino fisico, carrello consegna, batch standard ogni cinque minuti, urgenze, auto sold-out e cambio ordine.
- Dipendenti e candidati separati per ruolo, preferenze operative reali, skill, stress, stipendi e licenziamento con conferma.
- Bellezza, pulizia persistente, infestazioni visibili e priorità del tuttofare.
- Una recensione per gruppo, mance aggregate, reputazione EMA bidirezionale e storico leggibile.
- Statistiche event-driven con recensioni, ricavi, produttività, carico, bellezza, pulizia e rischio infestazioni.
- Profilo ristorante con nome, avatar preset-based e anteprima on demand.
- Salvataggio JSON versione 11 con backup, migrazione v9–v11, recupero da corruzione e scrittura atomica.
- PWA offline aggiornabile in-place, safe mode WebGL iOS, orientamento libero e layout verificati da 390x844 a 1366x768.
- Debug per denaro, sblocchi, stock, clienti, rush, chiusura immediata, griglia, percorsi, code e task.

## Verifica

Controlli principali:

```powershell
godot --headless --path . tests/test_runner.tscn
godot --headless --path . tests/casual_state_migration.tscn
godot --headless --path . tests/review_runtime_integration_smoke.tscn
godot --headless --path . tests/ambience_runtime_smoke.tscn
godot --headless --path . tests/staff_role_smoke.tscn
godot --headless --path . tests/responsive_ui_smoke.tscn
godot --headless --path . tests/pwa_delivery_smoke.tscn
```

Il workflow GitHub Pages esegue unit test, migrazioni, smoke test dei sistemi,
audit glifi e responsive prima dell’export. Le catture di consegna sono in
`artifacts/`, incluse quelle portrait in `artifacts/m10-responsive/`.

## Struttura

- `assets/`: modelli selezionati, texture, tavole icone e licenze.
- `data/`: cataloghi JSON per ingredienti, preparazioni, ricette, stazioni, personale, fornitori e builder.
- `scripts/autoload/`: stato, salvataggio, economia, audio e simulazione.
- `scripts/restaurant/`, `construction/`, `ai/`, `ui/`: mondo, builder, agenti e interfaccia.
- `tests/`: regressioni, controllo asset, smoke test e catture visuali.
- `docs/`: manifest asset, crediti e limiti reali.

Vedi anche `docs/ASSET_MANIFEST.md`, `docs/CREDITS.md`, `docs/KNOWN_LIMITATIONS.md` e `CHANGELOG_DEMO.md`.
