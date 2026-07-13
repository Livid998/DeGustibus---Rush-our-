class_name GameData
extends RefCounted

const RECIPES := {
	"burger": {
		"name": "Burger & Patatine",
		"short": "BURGER",
		"price": 18,
		"margin": 10,
		"color": Color("#e95d3c"),
		"steps": ["Frigo", "Piastra", "Friggitrice", "Assemblaggio", "Pass"],
		"valid_mods": ["senza formaggio", "patatine separate"],
		"invalid_mods": ["carne cruda", "triplo tutto gratis"],
	},
	"pasta": {
		"name": "Pasta al Pomodoro",
		"short": "PASTA",
		"price": 14,
		"margin": 9,
		"color": Color("#f4b942"),
		"steps": ["Frigo", "Fornelli", "Assemblaggio", "Pass"],
		"valid_mods": ["poco cotta", "salsa a parte"],
		"invalid_mods": ["senza pasta", "cottura zero secondi"],
	},
	"special": {
		"name": "Pollo Croccante",
		"short": "SPECIALE",
		"price": 24,
		"margin": 15,
		"color": Color("#55b985"),
		"steps": ["Frigo", "Friggitrice", "Assemblaggio", "Pass"],
		"valid_mods": ["contorno sostituito"],
		"invalid_mods": ["doppio pollo allo stesso prezzo", "senza cottura"],
	},
}

const PREP_PROFILES := {
	"breve": {
		"label": "PREP BREVE",
		"subtitle": "Economica, ma si parte scoperti",
		"cost": 35,
		"stress": 8.0,
		"mise": 0,
		"disorder": 4.0,
		"color": Color("#65c18c"),
	},
	"standard": {
		"label": "PREP STANDARD",
		"subtitle": "Il compromesso della brigata",
		"cost": 60,
		"stress": 18.0,
		"mise": 1,
		"disorder": 10.0,
		"color": Color("#f2b84b"),
	},
	"lunga": {
		"label": "PREP LUNGA",
		"subtitle": "Più basi, più costo e fatica",
		"cost": 95,
		"stress": 32.0,
		"mise": 2,
		"disorder": 20.0,
		"color": Color("#ec6c5b"),
	},
}

const STAFF := {
	"cassiera": {
		"name": "Marta", "role": "CASSA", "competence": 72, "speed": 66,
		"memory": 48, "public": 84, "order": 76, "stress_resistance": 62,
		"learning": 70, "mood": 74, "color": Color("#ad75d6"),
	},
	"waiter": {
		"name": "Nico", "role": "SALA", "competence": 61, "speed": 82,
		"memory": 54, "public": 65, "order": 52, "stress_resistance": 55,
		"learning": 78, "mood": 69, "color": Color("#55a7d9"),
	},
	"assistant": {
		"name": "Pippo", "role": "AIUTO", "competence": 58, "speed": 74,
		"memory": 63, "public": 40, "order": 31, "stress_resistance": 48,
		"learning": 67, "mood": 80, "color": Color("#6bc184"),
	},
}

const CUSTOMER_ARCHETYPES := [
	{"name": "Pranzo lampo", "patience": 68.0, "aggression": 25.0, "value": 16},
	{"name": "Foodie", "patience": 84.0, "aggression": 18.0, "value": 28},
	{"name": "Famiglia", "patience": 94.0, "aggression": 22.0, "value": 36},
	{"name": "Impaziente", "patience": 55.0, "aggression": 62.0, "value": 20},
	{"name": "Abitudinario", "patience": 76.0, "aggression": 34.0, "value": 18},
]

const INTERRUPTIONS := [
	{
		"id": "catering", "title": "Signora delle informazioni",
		"line": "Chef, c'è una signora che vuole parlare di un catering.",
		"choices": ["Delegala a Marta", "Parlo io", "Rifiuta"],
	},
	{
		"id": "progressive", "title": "Richieste progressive",
		"line": "Prima una sigaretta, poi la stagnola... ora vorrebbe il telefono.",
		"choices": ["Confine gentile", "Delegala", "Cacciala"],
	},
	{
		"id": "change", "title": "Il ragazzino del cambio",
		"line": "Allora compro una bottiglietta. Però mi servono monete precise.",
		"choices": ["Fai il resto", "Cambio rapido", "Rifiuta"],
	},
	{
		"id": "unwelcome", "title": "Non siamo graditi",
		"line": "Non siamo graditi, andiamo via!",
		"choices": ["Accoglienza immediata", "Omaggio", "Ignora"],
	},
]

const BRIEFING_OPTIONS := [
	{"id": "promote_pasta", "label": "Spingete la pasta", "hint": "Più ordini semplici"},
	{"id": "special_estimate", "label": "Speciale: stima 4", "hint": "Comunica le porzioni"},
	{"id": "forbid_sauce", "label": "Vietata salsa a parte", "hint": "Filtra la modifica"},
	{"id": "forbid_cheese", "label": "Vietato senza formaggio", "hint": "Filtra la modifica"},
	{"id": "soldout_burger", "label": "Burger non disponibile", "hint": "Niente nuove vendite"},
	{"id": "update_tables", "label": "Aggiornate i tavoli", "hint": "Pazienza più stabile"},
]

static func recipe_name(id: String) -> String:
	return RECIPES.get(id, {"name": id}).name

