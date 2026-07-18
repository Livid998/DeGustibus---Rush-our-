# Hook di fine giornata

`DayCycleManager.day_completed(completed_day)` viene emesso una sola volta quando
il clock persistente supera la mezzanotte. `completed_day` identifica il giorno
appena terminato; al momento del segnale `GameState.world_clock` contiene gia il
nuovo giorno.

Payroll, riepilogo economico e premi giornalieri devono connettersi a questo
segnale dall'autoload che ne possiede la logica. Il manager del ciclo non applica
direttamente costi o ricompense, così il rollover resta deterministico e testabile.
