class_name MockMarketProvider
extends MarketProvider

var _offers: Array = []
var restaurant_names := ["Osteria Aurora", "Bistrot 21", "Forno Rosso", "Trattoria Nova", "Cucina Centrale", "Il Girasole"]


func _init() -> void:
	refresh()


func refresh() -> void:
	_offers.clear()
	var prep_ids := DataRegistry.preparations_by_id.keys()
	prep_ids.shuffle()
	for index: int in mini(6, prep_ids.size()):
		var prep_id: String = prep_ids[index]
		var prep: Dictionary = DataRegistry.preparations_by_id[prep_id]
		var amount: int = int([5, 8, 10, 12].pick_random())
		var quality: int = randi_range(1, 3)
		var unit_price: float = float(prep.market_price) * randf_range(0.82, 1.18) * (0.85 + quality * 0.1)
		_offers.append({
			"id": "M%d_%s" % [Time.get_ticks_msec(), prep_id],
			"seller": restaurant_names.pick_random(),
			"preparation_id": prep_id,
			"name": prep.name,
			"amount": amount,
			"quality": quality,
			"unit_price": snappedf(unit_price, 0.1),
			"remaining": randi_range(45, 120)
		})


func get_offers() -> Array:
	return _offers


func tick(delta: float) -> bool:
	var changed := false
	for offer: Dictionary in _offers.duplicate():
		offer.remaining = float(offer.remaining) - delta
		if float(offer.remaining) <= 0.0:
			_offers.erase(offer)
			changed = true
	if _offers.is_empty():
		refresh()
		changed = true
	return changed


func buy_offer(offer_id: String) -> bool:
	for offer: Dictionary in _offers:
		if offer.id != offer_id:
			continue
		var total := int(ceil(float(offer.unit_price) * int(offer.amount)))
		if not GameState.spend(total, "Mercato · %s" % offer.name):
			return false
		GameState.purchased_preparations[offer.preparation_id] = int(GameState.purchased_preparations.get(offer.preparation_id, 0)) + int(offer.amount)
		_offers.erase(offer)
		return true
	return false
