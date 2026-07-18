# M10 acceptance captures

Queste immagini sono catture automatiche del runtime Godot reale, non mockup.
La fixture usa il seed `20260718`, disattiva le scritture del salvataggio e
attraversa le schermate e gli stati di produzione.

## Copertura

1. giorno;
2. notte;
3. pre-rush;
4. rush;
5. recensioni;
6. Album con quantità;
7. ricetta bloccata con costi Album;
8. capacità Magazzino;
9. riempimento fisico del Magazzino;
10. consegna in arrivo;
11. personale;
12. fornello con cappa;
13. fornello senza cappa;
14. gelatiera da tavolo;
15. ristorante sporco con infestazione;
16. profilo e avatar;
17. layout smartphone portrait.

`capture-index.json` registra risoluzione e dimensione di ogni PNG.
`capture-report.txt` contiene l'esito della sessione GPU.

## Riproduzione

Da una sessione desktop con renderer disponibile:

```powershell
Godot_v4.7-stable_win64_console.exe --path . res://tests/capture_m10_acceptance.tscn
```

In CI la stessa scena usa automaticamente la modalità
`headless-validation`: attraversa e verifica i 17 stati senza sostituire i PNG
con frame privi di renderer.

La verifica del punto 19 impone alla gelatiera:

- piazzamento `surface` su supporto `worktop`;
- un solo slot e nessuna scala aggiuntiva;
- dimensioni visuali `2.000 × 2.404 × 2.030`.
