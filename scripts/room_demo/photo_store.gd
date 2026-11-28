extends RefCounted
## 照片仓库 + 滚动屏提交逻辑（纯数据，不碰 UI / 3D）。
##
## 滚动屏不再自动组合：玩家可以拖任意张照片进去，点击“发送”后一次性提交。
## 发送时按照片类型集合判定：
## - clue_a + clue_b → 门禁码 A-317；
## - water + blanket → “打湿被子”提示（30 秒防护）；
## - screenshot → 让 NPC 去截图位置查看。
## 发送结果展示几秒后进入冷却并自动清屏。

const COMBINATION_CODE := "A-317"
const SCREEN_COOLDOWN := 5.0
const CLUE_PAIRS := {
	"clue_a": "clue_b",
	"clue_b": "clue_a",
}

signal photos_changed
signal screen_changed

var photos: Array[Dictionary] = []
var screen_photo_ids: Array[String] = []
var last_result: Dictionary = {}
var screen_state := "idle"
var screen_cooldown_until := 0.0

var _seq := 1


func clear() -> void:
	photos.clear()
	screen_photo_ids.clear()
	last_result.clear()
	screen_state = "idle"
	screen_cooldown_until = 0.0
	_seq = 1
	photos_changed.emit()
	screen_changed.emit()


func add_photo(kind: String, label: String, camera_id: String, timestamp: float,
		meta: Dictionary = {}) -> String:
	var photo := {
		"id": "photo_%d" % _seq,
		"kind": kind,
		"label": label,
		"camera_id": camera_id,
		"timestamp": timestamp,
		"meta": meta.duplicate(true),
	}
	photo["texture"] = meta.get("texture", null)
	_seq += 1
	photos.append(photo)
	photos_changed.emit()
	return String(photo["id"])


func find_photo(photo_id: String) -> Dictionary:
	for photo in photos:
		if String(photo["id"]) == photo_id:
			return photo
	return {}


func find_by_clue(clue_id: String) -> Dictionary:
	for photo in photos:
		if String(photo.get("kind", "")) == "clue" and String(photo.get("meta", {}).get("clue_id", "")) == clue_id:
			return photo
	return {}


func has_clue(clue_id: String) -> bool:
	return not find_by_clue(clue_id).is_empty()


## 玩家可以把任意张照片拖到滚动屏。这里只负责收下，不自动组合。
func drop_to_screen(photo_id: String, now: float) -> Dictionary:
	tick(now)
	if find_photo(photo_id).is_empty():
		return _result(false, "照片不存在")
	if screen_photo_ids.has(photo_id):
		return _result(false, "这张照片已经在滚动屏上了")
	if screen_state == "cooldown":
		return _result(false, "滚动屏冷却中，%.1fs 后重置" % maxf(screen_cooldown_until - now, 0.0))
	screen_photo_ids.append(photo_id)
	screen_state = "filling"
	last_result = _result(true, "已放入 %d 张照片，点击发送" % screen_photo_ids.size())
	screen_changed.emit()
	return last_result


## 点击滚动屏“发送”后统一校验。返回 {accepted, combined, screenshot, hint, code, ...}
func send_screen(now: float) -> Dictionary:
	tick(now)
	if screen_state == "cooldown":
		return _result(false, "滚动屏冷却中，%.1fs 后重置" % maxf(screen_cooldown_until - now, 0.0))
	if screen_photo_ids.is_empty():
		return _result(false, "滚动屏上还没有照片")

	var clue_ids: Array[String] = []
	var kinds: Array[String] = []
	var screenshot: Dictionary = {}
	for raw in screen_photo_ids:
		var photo := find_photo(String(raw))
		if photo.is_empty():
			continue
		var kind := String(photo.get("kind", ""))
		kinds.append(kind)
		if kind == "clue":
			clue_ids.append(String(photo.get("meta", {}).get("clue_id", "")))
		elif kind == "screenshot" and screenshot.is_empty():
			screenshot = photo

	var result: Dictionary
	if clue_ids.has("clue_a") and clue_ids.has("clue_b"):
		var combined_id := add_photo("combined", "门禁码", "C1", now, {
			"code": COMBINATION_CODE,
			"source": screen_photo_ids.duplicate(),
		})
		result = _result(true, "组合成功：门禁码 %s" % COMBINATION_CODE)
		result["combined"] = true
		result["code"] = COMBINATION_CODE
		result["photo_id"] = combined_id
	elif kinds.has("water") and kinds.has("blanket"):
		result = _result(true, "提示：把被子打湿后披在身上，可以坚持 30 秒")
		result["hint"] = "wet_blanket"
	elif not screenshot.is_empty():
		result = _result(true, "截图已发送：NPC 前往查看")
		result["screenshot"] = true
		result["focus_point"] = screenshot.get("meta", {}).get("focus_point", Vector3.ZERO)
		result["camera_id"] = String(screenshot.get("camera_id", ""))
	else:
		result = _result(false, "这些照片没有可识别的组合或发送目标")

	last_result = result
	screen_state = "cooldown"
	screen_cooldown_until = now + SCREEN_COOLDOWN
	screen_changed.emit()
	return result


func tick(now: float) -> void:
	if screen_state == "cooldown" and now >= screen_cooldown_until:
		_reset_screen()


func _reset_screen() -> void:
	screen_photo_ids.clear()
	last_result.clear()
	screen_state = "idle"
	screen_cooldown_until = 0.0
	screen_changed.emit()


func screen_remaining(now: float) -> float:
	if screen_state == "cooldown":
		return maxf(screen_cooldown_until - now, 0.0)
	return 0.0


func screen_status_text(now: float) -> String:
	if screen_state == "cooldown":
		return "滚动屏冷却中：%.1fs 后重置" % screen_remaining(now)
	if screen_state == "filling":
		return "已放入 %d 张，点击发送" % screen_photo_ids.size()
	return String(last_result.get("reason", ""))


func get_context() -> Dictionary:
	return {"combination_code": COMBINATION_CODE, "screen_cooldown": SCREEN_COOLDOWN}


func _result(accepted: bool, reason: String) -> Dictionary:
	return {
		"accepted": accepted,
		"combined": false,
		"screenshot": false,
		"hint": "",
		"code": "",
		"label": "",
		"photo_id": "",
		"reason": reason,
		"focus_point": Vector3.ZERO,
		"camera_id": "",
	}
