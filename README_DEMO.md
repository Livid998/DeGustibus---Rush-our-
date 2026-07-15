# Restaurant City Pro Demo

Vertical slice giocabile di un gestionale di ristorazione 3D isometrico, realizzato in Godot 4.7 con renderer Mobile. Il progetto usa un sottoinsieme curato degli asset contenuti in `modelli 3d.zip` e le illustrazioni fornite dall’utente per ingredienti, ricette, navigazione e lucchetti.

## Avvio

1. Apri `project.godot` con Godot 4.7 o successivo e premi F6/F5.
2. In alternativa esegui `RUN_DEMO.ps1` da PowerShell.
3. Alla prima apertura attendi l’importazione dei file GLTF/GLB e delle texture.

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

Le pagine gestionali sono schermate complete e separate: Ristorante, Menu, Album, Magazzino, Mercato, Personale, Statistiche e Impostazioni. L’Album è la collezione permanente; il Magazzino gestisce invece quantità consumabili, qualità del lotto, fornitore, soglia, target, lotto e riordino automatico.

Aprendo il locale, gruppi da uno a quattro clienti entrano, occupano sedie reali distinte, ordinano un piatto ciascuno e generano task produttivi data-driven. Cuochi e camerieri prenotano task e postazioni, percorrono la griglia, eseguono le fasi, portano i piatti al pass, servono, incassano e liberano il tavolo.

## Sistemi principali

- Griglia 18×14 con pathfinding sensibile ai bordi: pareti, porte e finestre occupano i lati delle celle senza sottrarre spazio alle attrezzature.
- Camera ortografica isometrica con pan mouse/touch, pinch e limiti di zoom/movimento.
- 20 ingredienti con icone illustrate trasparenti e centrate, rarità 1–5, 12 sbloccati iniziali e progressione permanente tramite obiettivi, reputazione, acquisto e stazioni.
- 13 semilavorati acquistabili o prodotti: quelli acquistati sostituiscono realmente le fasi `preppable` e preservano lo stock crudo.
- 12 ricette a più fasi, 13 tipi di postazione, capacità, code, dipendenze, priorità e prenotazione esclusiva.
- Menu illustrato con prezzo, costo, margine, tempo, ingredienti mancanti, postazioni, popolarità e carico previsto.
- Pass con icone ricetta, tavolo, tempo, componenti mancanti, sospensione/ripresa e priorità.
- Sei fornitori, consegne differite, urgenze, riordino automatico, due negozi NPC e mercato mock con offerte a scadenza.
- Cinque dipendenti iniziali e cinque candidati, ruoli, preferenza di postazione, stress leggero, assunzione, stipendi e licenziamento con conferma.
- Statistiche di ricavi, ingredienti, personale, utile, soddisfazione, tempi, vendite, produttività e carico delle postazioni.
- Salvataggio JSON versione 5 con backup, migrazione automatica delle pareti, recupero da corruzione e reset.
- Debug per denaro, sblocchi, stock, clienti, rush, chiusura immediata, griglia, percorsi, code e task.

## Verifica

Comandi eseguiti per la consegna:

```powershell
godot --headless --path . tests/test_runner.tscn
godot --headless --quit-after 2 --path . tests/asset_load_check.tscn
godot --headless --quit-after 2 --path . tests/service_smoke.tscn
godot --headless --quit-after 3 --path .
```

Risultati correnti:

- 101 controlli deterministici, 0 errori.
- 70 percorsi asset dichiarati caricati, 0 riferimenti mancanti.
- Smoke test completo: cliente servito e pagante; 5/5 fasi margherita completate.
- Catture landscape e portrait in `artifacts/`.

## Struttura

- `assets/`: modelli selezionati, texture, tavole icone e licenze.
- `data/`: cataloghi JSON per ingredienti, preparazioni, ricette, stazioni, personale, fornitori e builder.
- `scripts/autoload/`: stato, salvataggio, economia, audio e simulazione.
- `scripts/restaurant/`, `construction/`, `ai/`, `ui/`: mondo, builder, agenti e interfaccia.
- `tests/`: regressioni, controllo asset, smoke test e catture visuali.
- `docs/`: manifest asset, crediti e limiti reali.

Vedi anche `docs/ASSET_MANIFEST.md`, `docs/CREDITS.md`, `docs/KNOWN_LIMITATIONS.md` e `CHANGELOG_DEMO.md`.
