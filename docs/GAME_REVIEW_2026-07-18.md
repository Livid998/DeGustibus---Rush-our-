# DeGustibus — review completa del gioco

**Data:** 18 luglio 2026  
**Oggetto:** build corrente, codice, dati di bilanciamento, test automatici, PWA e catture reali del gioco  
**Verdetto sintetico:** **vertical slice avanzata e promettente, ma non ancora pronta per una beta pubblica a pagamento.**

## 1. Executive summary

DeGustibus ha già qualcosa che molti prototipi non possiedono: un’identità di gameplay potenzialmente distinguibile. Non è soltanto un gioco in cui si clicca per preparare ricette; prova a simulare fisicamente il ristorante, le postazioni, il percorso degli addetti, i tavoli, il magazzino, le preparazioni e le conseguenze del layout.

La promessa commerciale più forte è:

> **“Costruisci un vero ristorante compatto: ogni scelta di layout cambia visibilmente il servizio.”**

Il problema è che oggi questa promessa viene indebolita da tre categorie di difetti:

1. **Il loop può rompersi.** La capacità del magazzino può creare un soft lock; alcune ricette e catene di sblocco sono irraggiungibili; alcuni acquisti non hanno alcun effetto.
2. **La simulazione non è ancora abbastanza affidabile da sembrare professionale.** AI e navigazione possono tecnicamente completare il compito, ma esitazioni, congestione, sincronizzazione degli NPC e animazioni meccaniche sono immediatamente visibili.
3. **La presentazione è incoerente e ancora da prototipo.** Mondo 3D, ritratti, icone, bubble, UI e animazioni appartengono a linguaggi visivi differenti; su telefono l’interfaccia è troppo densa e vulnerabile alle sovrapposizioni.

La priorità non deve essere aggiungere altre meccaniche. Prima va resa impeccabile una sessione di 30–45 minuti: nuova partita, primo servizio, primo rush, primo problema, prima recensione, primo sblocco e prima espansione.

## 2. Cosa funziona già

- Il concept di ristorante fisicamente simulato è più profondo della media casual.
- Album e scorte sono correttamente separati come idee: collezione permanente contro inventario consumabile.
- Il progetto è ampiamente data-driven: 20 ingredienti, 13 preparazioni, 12 ricette, 13 tipi di postazione e 48 elementi di catalogo.
- Il builder possiede regole tecniche non banali: agganci, lati operativi, muri, sedie, supporti e controllo dei percorsi.
- La palette teal/arancio/crema è riconoscibile.
- Ingredienti e ricette ora sono centrati, trasparenti e leggibili.
- Salvataggi, migrazioni, responsive layout, PWA, builder, AI e pipeline alimentare hanno una copertura automatica insolitamente ampia per questa fase.
- Esistono backup del salvataggio, migrazioni fino alla versione 11, safe mode WebGL e aggiornamento PWA.

Questi punti giustificano il proseguimento del progetto. Non giustificano ancora una release commerciale.

## 3. Bloccanti P0

### P0.1 — Il magazzino può bloccare definitivamente il gioco

Lo stato iniziale è già quasi saturo:

- ambiente: circa **186 / 200**;
- refrigerato: circa **211 / 240**.

La somma dei target predefiniti è addirittura superiore alla capacità iniziale:

- target ambiente: **225 / 200**;
- target refrigerato: **258 / 240**.

`StorageManager.validate_delivery_capacity()` rifiuta l’intero acquisto quando il forecast supera la capacità. Non risultano:

- consegne parziali;
- quantità massima acquistabile proposta automaticamente;
- deposito temporaneo;
- possibilità di scartare o rivendere scorte;
- annullamento/rimborso di un ordine pendente;
- recupero automatico di un salvataggio già bloccato.

La catena di fallimento è quindi reale:

> manca un ingrediente essenziale → tutte le ricette attive diventano esaurite → non entrano ordini che consumino le scorte superflue → lo spazio rimane pieno → non si può comprare l’ingrediente mancante → il ristorante non può più produrre.

**Correzione necessaria**

1. Mostrare per ogni articolo la quantità massima realmente ordinabile.
2. Ridurre il carrello alla capienza o accettare una consegna parziale.
3. Permettere di scartare/rivendere stock a forte perdita.
4. Permettere annullamento e rimborso parziale dei batch non consegnati.
5. Offrire un overflow temporaneo penalizzato o un “deposito d’emergenza”.
6. Impedire di vendere l’ultimo deposito se rende la partita irrecuperabile.
7. Aggiungere un’invariante globale: deve sempre esistere almeno una ricetta attiva producibile oppure un modo garantito per ripristinarla.
8. All’apertura di un save soft-locked, proporre una riparazione automatica una tantum.
9. Aggiungere un test casuale di 20–30 giorni che provi stock-out, acquisti, vendita depositi e cambi menu.

### P0.2 — Parte della progressione è irraggiungibile

I dati dichiarano che `pepperoni` e `milk` si sbloccano tramite acquisto Album, ma la UI corrente non espone tale acquisto e `check_progression()` non completa quei requisiti.

Conseguenze:

- pizza pepperoni imparabile ma non producibile;
- cono gelato impossibile senza latte;
- coppa gelato impossibile;
- fragola richiede dieci dessert, ma i dessert iniziali richiedono latte: dipendenza circolare.

Serve una sola fonte autorevole per ogni requisito, mostrata direttamente nell’Album, e un test automatico:

> “Partendo da un nuovo salvataggio, ogni ingrediente e ogni ricetta deve essere raggiungibile senza cheat.”

### P0.3 — Il mercato vende semilavorati inutilizzabili

La simulazione consuma un semilavorato soltanto quando il suo ID coincide esattamente con l’output di una fase `preppable`. Il mercato vende anche prodotti che non hanno una corrispondenza utile, fra cui almeno:

- `tomato_slices`;
- `mushroom_cut`;
- `onion_chopped`;
- `cheese_slice`;
- `lettuce_cut`;
- `steak_pieces`.

Il giocatore può spendere monete senza ottenere alcun beneficio. Finché le ricette non li usano, questi articoli vanno nascosti o marcati chiaramente come non acquistabili.

### P0.4 — Prestazioni Web/iPad non ancora affidabili

L’utente ha già osservato lag, freeze e `WebGL context lost`. La PWA corrente pesa circa **60,9 MiB**:

- WASM: circa 39,5 MiB;
- PCK: circa 23,9 MiB.

Safe mode e recupero dal context loss sono buone protezioni, ma non eliminano la causa. Non esistono ancora prove automatiche di:

- FPS e frame time;
- RAM/VRAM;
- crescita della memoria in sessioni lunghe;
- temperatura/consumo;
- affidabilità Safari/iPad reale.

Inoltre, dal codice è plausibile un costo vicino a O(n²) in alcune query fra agenti: va verificato con profiler, non assunto.

**Gate minimo per una beta tablet**

- 30 FPS sostenuti sul dispositivo iPad target;
- p95 del frame sotto 33 ms;
- sessione di 60 minuti senza context loss;
- nessuna crescita continua della memoria;
- popolazione massima e qualità grafica calibrate per device.

### P0.5 — Salvataggio Web non sufficientemente sicuro per una release

Il save vive nel browser/origine. Non ci sono ancora account, cloud save, export/import manuale, richiesta di storage persistente, avviso per navigazione privata o una schermata di recupero.

Per una beta pubblica servono almeno:

- export/import del salvataggio con validazione;
- richiesta `navigator.storage.persist()`;
- salvataggio/flush quando la pagina diventa nascosta;
- avviso quando la persistenza non è garantita;
- schermata “recupera backup”;
- versione della build visibile.

La [documentazione Godot sull’export Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html) conferma i limiti di persistenza e le differenze prestazionali del Web rispetto alle build native.

## 4. Debolezze del gameplay

### 4.1 La nuova partita parte troppo avanti

Il giocatore riceve subito circa 10.000 monete, sei dipendenti, due tavoli completi, quasi tutta la cucina e stock enorme. Questo elimina molti momenti naturalmente gratificanti:

- comprare il primo tavolo;
- assumere il primo aiuto;
- sbloccare la prima nuova postazione;
- sentire il ristorante crescere;
- scegliere davvero a cosa destinare poco denaro.

Meglio partire da una micro-operazione perfettamente funzionante: un tavolo, menu ridotto, due persone e spazio evidente da conquistare.

### 4.2 Ci sono troppe “false scelte”

La UI presenta decisioni che oggi incidono poco o nulla:

- il fornitore selezionato non cambia realmente costo, tempo, qualità o assortimento;
- la qualità generata dal mercato non viene conservata nell’acquisto;
- alcune statistiche del personale sono mostrate ma non guidano la simulazione;
- la condizione della postazione pesa nella formula qualità, ma resta sempre perfetta;
- il margine mostrato usa costi statici, non il costo medio reale.

Ogni dato visibile deve produrre una conseguenza osservabile. In alternativa va temporaneamente rimosso.

### 4.3 L’economia non crea tensione interessante

I margini sono alti, lo stock iniziale è abbondante e mancano costi significativi come affitto, utenze, deterioramento, manutenzione o vero spreco. Il debito salariale è soprattutto un avviso.

Non serve introdurre un game over severo. Serve una spirale morbida e recuperabile:

- morale e rendimento calano;
- il giocatore riceve un piano di rientro;
- può ridimensionare il locale;
- può chiedere una consegna o un prestito d’emergenza;
- gli errori costano, ma non distruggono il salvataggio.

### 4.4 Il ristorante chiuso è sfruttabile

Consegne e riordino avanzano mentre il ciclo giornaliero e gli stipendi dipendono dallo stato del locale. È possibile chiudere e attendere le consegne senza far avanzare davvero il costo del tempo.

Il tempo economico deve essere autorevole e coerente indipendentemente dall’apertura.

### 4.5 Rush, prezzi e clienti non producono ancora strategie forti

- Con pochi tavoli il rush riempie rapidamente il buffer e genera soprattutto coda.
- Il prezzo funziona quasi come soglia “posso/non posso permettermelo”, non come valore percepito.
- Gli archetipi cliente cambiano poco: budget e pazienza risultano troppo simili.
- Le recensioni tendono a essere generose e non sempre riflettono bene l’attesa dell’ultimo commensale.

Gli archetipi dovrebbero modificare realmente:

- orario;
- budget e sensibilità al prezzo;
- pazienza;
- dimensione del gruppo;
- permanenza;
- aspettativa di qualità;
- mancia;
- probabilità e tono della recensione.

Il rush dovrebbe offrire un obiettivo volontario, un bonus e una fase di preparazione, non soltanto aumentare il traffico.

### 4.6 Progressione e retention sono troppo corte

Dodici ricette sono sufficienti per una vertical slice, non per sostenere una campagna. Inoltre alcune sono oggi irraggiungibili. Mancano:

- mastery delle ricette;
- crescita e training del personale;
- upgrade delle attrezzature;
- obiettivi giornalieri;
- clienti abituali memorabili;
- eventi e richieste speciali;
- milestone del locale;
- set estetici e veri traguardi di espansione;
- un sink utile per i duplicati Album.

Non è necessario aggiungere cento ricette subito. È più importante dare significato a quelle presenti.

### 4.7 Il tutorial è fragile e troppo testuale

Il secondo obiettivo, “Aggiungi una sedia”, non risulta collegato a un avanzamento reale. Il tutorial può fermarsi indefinitamente.

Inoltre l’onboarding chiede azioni senza spiegare chiaramente:

- perché contano;
- come riconoscere il successo;
- quale problema risolvono;
- come recuperare un errore.

Ogni step dovrebbe essere validato sull’evento reale, accompagnato da evidenza visiva e testato da nuovo salvataggio fino al primo servizio concluso.

### 4.8 Il builder è tecnicamente ricco ma non ancora divertente

Le regole sono migliorate, ma l’esperienza rimane più vicina a un tool tecnico che a un editor piacevole:

- pannello molto invasivo;
- catalogo orizzontale con voci tagliate;
- assenza di miniature informative, ricerca e filtri;
- preview che nasconde dettagli;
- fronte operativo poco evidente;
- molte regole di validazione percepite solo dopo il tentativo;
- nessun arco di sblocco del builder.

Servono ghost semiopaco, outline, frecce operative, punti di aggancio visibili, card con footprint e supporto richiesto, undo/redo affidabile, copia, selezione multipla e alternativa al drag.

## 5. AI, pathfinding e comportamento dei personaggi

I test automatici dimostrano che molti scenari terminano, ma non che sembrino naturali. Alcuni stress test superano le asserzioni con tempi lunghi, clearance minima molto bassa e numerosi recuperi: per il giocatore ciò appare come esitazione, collisione o “AI stupida”.

Serve un livello di coordinamento sopra il semplice pathfinding:

1. prenotazione esplicita delle strettoie;
2. priorità uscita > entrata;
3. corsie e slot per la fila esterna;
4. slot unici per tavoli, sedie e postazioni;
5. destinazioni idle fuori dai corridoi;
6. timeout con ricalcolo del percorso, non avanti/indietro;
7. query dei vicini tramite spatial hash;
8. aggiornamenti AI scaglionati;
9. separazione fra stato logico, movimento e animazione;
10. niente nuova destinazione finché lo stato corrente non è concluso o annullato atomicamente.

Per i clienti la state machine deve essere inequivocabile:

> spawn → coda → ingresso → posto prenotato → ordine unico → attesa → piatto completo → consumo → piatto sporco → pagamento → uscita → despawn.

Una persona non deve poter tornare a sedersi dopo l’uscita, generare due ordini, cambiare tavolo senza transizione o aspettare il resto del gruppo sul punto di despawn.

## 6. Grafica, modelli, animazioni e icone

### 6.1 Direzione artistica frammentata

Oggi convivono:

- mondo 3D low-poly;
- ingredienti con bordo nero illustrato;
- ritratti del personale molto dettagliati;
- icone di navigazione e bubble con altre rese ancora.

La [schermata personale](../artifacts/m10-acceptance/11-staff.png) mostra chiaramente più linguaggi visivi nello stesso pannello.

Serve una style guide con:

- palette;
- saturazione;
- spessore dei contorni;
- ombre;
- illuminazione;
- dimensione ottica;
- regole per icone 16/24/48/96 px;
- resa di hover, focus, blocco e disabilitato.

### 6.2 Ruoli 3D poco riconoscibili

Alcuni camerieri e cuochi usano silhouette da operaio con elmetto. I ruoli devono capirsi senza leggere un’etichetta:

- chef: cappello/divisa;
- cameriere: grembiule o gilet;
- tuttofare: tuta e attrezzi;
- colore secondario coerente per ruolo.

### 6.3 Animazioni e presa degli oggetti

Il riuso di `PickUp`, pose congelate e rotazioni procedurali produce:

- braccia rigide;
- utensili che fluttuano;
- piatti che non sembrano avere peso;
- mani non allineate;
- lavoro alla postazione poco credibile.

Serve una matrice dedicata e verificata per rig:

- taglia;
- impasta;
- mescola;
- gira in padella;
- inforna;
- impiatta;
- lava;
- porta;
- serve;
- paga;
- conversa;
- mangia con forchetta/cucchiaio.

Per le interazioni importanti è consigliato IK mano–prop–postazione, con marker espliciti negli asset.

### 6.4 Piatti leggibili ma non ancora rifiniti

Le dimensioni sono più coerenti e il cibo è leggibile da vicino, ma:

- a distanza normale le preparazioni sono minuscole;
- alcuni contenitori sembrano più dischi sovrapposti;
- la massa visiva varia molto fra pietanze;
- le fasi intermedie non sembrano sempre parte dello stesso piatto.

Ogni ricetta deve avere un passaggio artistico manuale alle tre distanze di camera: preparazione, trasporto, tavolo.

### 6.5 Illuminazione e mondo poco vivi

Giorno e notte cambiano soprattutto la luminosità globale. Pre-rush e rush sono quasi uguali nel mondo. Mancano:

- luci locali;
- emissivi di forno e fornelli;
- finestre illuminate;
- contact shadow/AO economica;
- vapore, fumo, briciole e schizzi;
- color grading e VFX del rush.

L’[esterno](../artifacts/exterior_lot.png) è ancora un lotto verde vuoto con strada piatta e bordi da prototipo. Servono diorama edge, marciapiede con cordolo, facciata/insegna, traffico o pedoni ambientali, vegetazione raggruppata e landmark.

### 6.6 Bubble e indicatori

Le [bubble ravvicinate](../artifacts/status_bubbles_close_zoom.png) coprono interamente i volti e creano rumore quando gli agenti sono vicini.

Ridurre del 20–30%, alzarle, mostrare solo il messaggio prioritario e sfalsarle temporalmente. Gli errori importanti devono essere badge screen-space leggibili, non piccole Label3D coperte dai personaggi.

### 6.7 Audio quasi assente

L’audio corrente è essenzialmente feedback sintetico molto breve. È una lacuna enorme per la percezione di qualità.

Priorità audio:

- musica giorno/rush;
- ambiente sala e strada;
- passi;
- stoviglie;
- elettrodomestici;
- cassa/pagamento;
- feedback UI;
- segnali sonori leggibili per ordini pronti, blocchi e problemi.

## 7. UI, mobile e accessibilità

### Desktop/tablet

La struttura è comprensibile, ma alterna schermate molto dense ad altre con grandi spazi morti. Il [Magazzino](../artifacts/m10-acceptance/08-warehouse-capacity.png) dedica gran parte della viewport a pulsanti grigi e camion sovradimensionati; inventario e soluzioni al problema sono sotto la piega.

Menu e Album richiedono progressive disclosure; Statistiche necessita di trend, confronto con il giorno precedente e grafici compatti.

### Telefono

La [cattura portrait](../artifacts/m10-acceptance/17-smartphone-portrait.png) mostra sovrapposizioni fra HUD e toast. Anche il layout finale ha:

- una ricetta quasi per schermata;
- testo eccessivo;
- barra inferiore con icone molto piccole;
- gerarchia fragile su notch e safe area.

Interventi:

- toast multilinea accodati e limitati alla safe area;
- icone da almeno 24–28 px;
- schede compatte con dettagli espandibili;
- modalità focus sul ristorante durante il servizio;
- verifica notch/home indicator;
- target touch coerenti.

### Tipografia e accessibilità

Fredoka One funziona per titoli e CTA, ma è pesante per paragrafi e tabelle. Usare Fredoka Medium per il corpo, SemiBold per schede/pulsanti e Bold/One per titoli e valuta.

Mancano ancora:

- navigazione focus progettata;
- alternativa al drag;
- scala UI/testo;
- riduzione movimento;
- modalità daltonismo/alto contrasto;
- segnali non basati soltanto su rosso/verde;
- etichette di accessibilità.

Le [WCAG 2.2](https://www.w3.org/WAI/WCAG22/quickref/) richiedono un’alternativa a singolo puntatore per le azioni di trascinamento e target minimi adeguati.

## 8. Debolezze tecniche e di produzione

- La build PWA presente dichiara commit `91b1ed…` e `dirty: true`, mentre il repository corrente è su `3410d47…`: l’artefatto testato non è riproducibile con certezza.
- Il pannello cheat F12 viene costruito anche nella release e deve essere escluso con un controllo di build.
- `restaurant_world.gd`, `simulation_manager.gd`, `restaurant_ui.gd`, `management_screens.gd`, `game_state.gd` e `customer_agent.gd` sono troppo grandi; aumentano il rischio di regressioni.
- La CI è forte ma prevalentemente headless: mancano image diff, browser matrix, Safari reale, device farm e soak test.
- Mancano crash reporting, metriche prestazionali, staging/canary e rollback automatico.
- Le stringhe sono hardcoded in italiano; non esiste una vera pipeline di localizzazione.
- Mancano schermata iniziale completa, slot, supporto, privacy e crediti in-game.

## 9. Benchmark e posizionamento

- [Good Pizza, Great Pizza](https://goodpizzagreatpizza.com/press/) rende memorabili clienti, dialoghi, capitoli, rivalità e personalizzazione.
- [PlateUp!](https://store.steampowered.com/app/1599600/PlateUp/) comunica immediatamente l’hook layout + cucina + progressione roguelite.
- [Touhou Mystia’s Izakaya](https://store.steampowered.com/app/1584090/Touhou_Mystias_Izakaya/) lega preferenze, budget, clienti rari e relazioni alla progressione.

La lezione non è copiare la quantità di contenuto. DeGustibus deve rendere chiarissima la causalità:

> layout → efficienza → qualità del servizio → recensioni → reputazione → crescita del locale.

Per distinguersi, dovrebbe puntare su:

- simulazione leggibile;
- ristorante personalizzato;
- clienti abituali riconoscibili;
- problemi operativi emergenti ma recuperabili;
- crescita visibile da piccola attività a ristorante complesso.

## 10. Roadmap consigliata

### Fase 0 — 48 ore: eliminare gli stati irrecuperabili

1. Soft lock del magazzino.
2. Latte, pepperoni e catena dessert.
3. Semilavorati inutili.
4. Tutorial della sedia.
5. Checklist pre-apertura: menu producibile, posti validi, personale e percorsi.
6. Test “ogni ricetta raggiungibile” e simulazione multi-giorno.

### Fase 1 — 1–2 settimane: affidabilità

1. Coordinatore delle strettoie e priorità uscita.
2. Slot idle e postazioni atomiche.
3. Spatial partition degli agenti.
4. Profilazione iPad/PC e soak test da 60 minuti.
5. Export/import e recovery save.
6. Build pulita, taggata e riproducibile; rimozione cheat release.

### Fase 2 — 3–6 settimane: primo ciclo perfetto

1. Nuova partita piccola.
2. Tutorial realmente guidato.
3. Primo rush con obiettivo e ricompensa.
4. Prima recensione significativa.
5. Primo sblocco e prima espansione.
6. Economia e fornitori con conseguenze reali.
7. Clienti abituali e archetipi distinti.

### Fase 3 — 3–6 settimane: presentazione

1. Silhouette dei ruoli.
2. Animazioni dedicate e IK.
3. Pass artistico ricette/piatti.
4. UI mobile e builder.
5. Illuminazione, esterno, audio e micro-VFX.
6. Style guide unica per icone, ritratti e UI.

### Fase 4 — beta chiusa

Beta con 50–200 persone e misurazione di:

- completamento onboarding;
- tempo al primo piatto servito;
- abbandono e punto di abbandono;
- D1/D7;
- durata sessione;
- stock-out e soft lock;
- NPC bloccati;
- frame time, memoria e context loss;
- recupero del salvataggio.

Solo dopo segnali positivi: più ricette, temi, eventi, monetizzazione e build native.

## 11. Cosa non fare ora

- Non aggiungere altri sistemi prima di chiudere i P0.
- Non inseguire cento ricette per compensare un primo ciclo debole.
- Non pubblicizzare la PWA come esperienza iOS definitiva.
- Non monetizzare attese artificiali, energia, gacha o doppie valute.
- Non usare animazioni o statistiche decorative che promettono causalità inesistente.
- Non considerare “test passato” equivalente a “comportamento credibile”.

## 12. Modello commerciale consigliato

Per il progetto attuale:

- PWA gratuita come demo/beta;
- prodotto premium a prezzo unico su desktop e, più avanti, native mobile;
- espansioni tematiche opzionali;
- cosmetici trasparenti, senza loot box.

Per un’eventuale pubblicazione iOS commerciale, una build Godot nativa sarà più solida di un semplice wrapper WebView. Le [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) richiedono inoltre valore duraturo, privacy policy e un prodotto che non sembri soltanto un sito riconfezionato.

## 13. Conclusione

DeGustibus non è “una demo scrausa”: possiede già una base sistemica notevole. Ma oggi il numero di sistemi supera la loro affidabilità e interconnessione.

Il percorso con la maggiore probabilità di successo è:

1. impedire qualunque soft lock;
2. rendere la progressione interamente raggiungibile;
3. far sembrare impeccabili clienti e personale;
4. rendere il primo ciclo corto, chiaro e gratificante;
5. unificare direzione artistica, animazioni, UI e audio;
6. provare prestazioni e salvataggi su hardware reale;
7. soltanto dopo espandere il contenuto.

Se questi passaggi vengono rispettati, il progetto può trovare una nicchia credibile come gestionale casual di ristorazione fisicamente simulato. Nello stato attuale, la base è valida, ma la percezione commerciale resta quella di una vertical slice ricca di idee e non ancora di un gioco finito.

