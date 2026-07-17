# Changelog demo

## 2.0.0 - 2026-07-17

- Aggiunti ciclo giorno/notte persistente, rush naturali, pausa, velocità e costo giornaliero del personale.
- Separati definitivamente Album e stock: le ricette si imparano consumando collezione, con premi recensione e pity persistente.
- Implementati capacità ambiente/refrigerata, prenotazioni atomiche, carrello consegna, batch standard, urgenze, auto sold-out e cambio ordine.
- Aggiunti qualità piatto 0–100, difetti contestuali, rifacimento automatico, cause strutturate e icone reali nel pass.
- Introdotte una recensione aggregata per gruppo, mance, reputazione EMA bidirezionale e schermata Recensioni persistente.
- Aggiunti bellezza effettiva, pulizia, sporco cucina, avvisi e incidenti visibili di topi/insetti collegati ai task del tuttofare.
- Separati personale e candidati per ruolo con preferenze operative reali per cuochi, camerieri e tuttofare.
- Resi obbligatori supporti da tavolo e cappe; la macchina gelato mantiene modello, scala e dimensioni originali come elettrodomestico da tavolo.
- Aggiunto profilo del ristorante con nome e avatar preset-based salvato.
- Convertita la UI gestionale in pagine persistenti/event-driven; eliminate le ricostruzioni periodiche di Statistiche e Mercato.
- Su telefono la navigazione usa Ristorante, Menu, Magazzino, Personale e un bottom sheet `Altro`; tablet e desktop mostrano tutte le sezioni.
- Integrati orientamento PWA libero, safe area, aggiornamento in-place, audit glifi e test responsive per 390x844, 412x915, 800x1024, 1280x720 e 1366x768.
- Aggiornato il salvataggio alla versione 11 con migrazione v9–v11 e preservazione dei dati esistenti.

## 1.2.0 - 2026-07-15

- Rimossa la patina chiara dalla mappa con illuminazione neutra, contrasto ripristinato e fog disattivata.
- Normalizzati pivot e ingombri dei modelli rispetto alla griglia; corrette le footprint delle attrezzature che risultavano sfalsate.
- Spostate le pareti sui bordi esterni delle celle: non consumano più lo spazio utile e possono incontrarsi negli angoli e nelle intersezioni a T.
- Resi porte e finestre sostituti di una parete esistente; la porta ora combina il varco murario con l'anta illustrata dal modello originale.
- Riscritto lo snap del builder sui bordi, con anteprima continua al passaggio del mouse, indicazione Nord/Ovest/Sud/Est e ripristino corretto in annullamento.
- Aggiornato il pathfinding per bloccare il passaggio attraverso pareti solide senza marcare come occupate le celle adiacenti.
- Consentito il posizionamento delle attrezzature sulle celle perimetrali, mantenendo riservato soltanto l'ingresso.
- Integrato il Fredoka One fornito dall'utente con gerarchia cartoony Medium, SemiBold e Bold in tutta l'interfaccia.
- Aggiornato il salvataggio alla versione 5 con migrazione automatica dei divisori esistenti.
- Portata la suite a 101 controlli e il controllo asset a 70 percorsi.

## 1.1.1 - 2026-07-15

- Sostituita la griglia matematica delle sprite sheet con un'estrazione calibrata per ciascuna delle 20 icone ingredienti e 12 ricette.
- Rimossi deterministicamente gli sfondi opachi e ricentrati i soggetti in atlanti RGBA uniformi, senza ridisegnare o rigenerare le illustrazioni fornite.
- Separati correttamente i contorni che si toccavano nella tavola originale, incluso il confine tra stufato e coppa gelato.
- Integrati il lucchetto illustrato e la tavola con otto icone per Ristorante, Menu, Album, Magazzino, Mercato, Personale, Statistiche e Impostazioni.
- Aggiunta una pagina Impostazioni completa per effetti sonori, zoom camera, centratura, tutorial e salvataggio manuale.
- Portata la suite a 87 controlli, inclusi mapping e trasparenza degli atlanti.

## 1.1.0 - 2026-07-15

- Riscritto il builder: selezione reale, spostamento senza duplicazioni, conferma/annulla, vendita, griglia e validazione di tutti gli accessi essenziali.
- Resi pareti, pavimenti, porte, sedie, tavoli e attrezzature veri elementi modificabili; aggiunta la modifica delle sole decorazioni durante il servizio.
- Corretti pan mouse/touch, pinch, tap e pressione prolungata; aggiunti test di regressione input.
- Eliminato lo z-fighting normalizzando scala e passo dei moduli pavimento/parete.
- Aggiunte quattro sedie reali per tavolo e disposizione distinta dei membri dei gruppi, con un ordine per cliente.
- Convertita la navigazione inferiore in pagine complete; separati Album e Magazzino e ridisegnati Menu, Mercato, Personale e Statistiche.
- Integrate senza rigenerazione le due tavole illustrate fornite dall’utente: 20 icone ingredienti e 12 icone ricette, mappate per ID e riusate nel pass.
- Aggiunti rarità, dettaglio Album, ricette/preparazioni compatibili, fonte di sblocco e progressione permanente funzionante.
- Collegati i semilavorati acquistati alle fasi produttive preparabili; aggiunti sospensione ticket, componenti mancanti e preferenze postazione.
- Reso coerente il carico menu con due taglieri iniziali e sovraccarico reale per menu concentrati sul forno.
- Aggiunti debug visuale di percorsi e code, stress/produttività, stipendi, feedback audio procedurale e controlli toast.
- Portata la suite a 80 controlli, aggiunto controllo di 69 path asset e corretto lo smoke test completo del servizio.

## 1.0.0 - 2026-07-15

- Creato da zero il progetto Godot 4.7 con renderer Mobile e scena principale isometrica.
- Selezionato e importato un sottoinsieme curato di modelli reali dall'archivio fornito.
- Implementati costruzione, griglia, pathfinding, validazione dei percorsi e camera touch/mouse.
- Implementati cataloghi data-driven per ingredienti, ricette, preparazioni, stazioni, dipendenti e fornitori.
- Implementati stock, consegne, riordino automatico, mercato mock e contabilità.
- Implementati task board, dipendenze di ricetta, code, capacità e prenotazione esclusiva.
- Implementati staff e gruppi clienti con modelli animati, servizio completo e statistiche.
- Implementata UI responsive con sei schermate, pass, onboarding e strumenti debug.
- Implementato salvataggio versionato con backup, fallback da corruzione e reset.
- Aggiunti i primi controlli deterministici, smoke test di servizio e catture visuali landscape/portrait.
- Documentati asset, licenze, audit dell'archivio e limiti noti.
