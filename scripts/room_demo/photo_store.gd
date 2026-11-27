extends RefCounted
## 照片仓库 + 滚动屏组合逻辑（纯数据，不碰 UI / 3D）。
##
## 照片来源：
## - `clue`：NPC 找到线索时自动拍下；
## - `screenshot`：玩家按 S 截取的当前监控画面；
## - `combined`：两张线索照片在滚动屏上组合后的产物。
##
## 组合规则（Scope 缩小版）：
## - 只看滚动屏上最后两张 `clue` 照片；
## - 两张照片的拍摄时间差 <= COMBO_WINDOW，且 clue_id 属于同一对，才成功；
## - 成功产出“门禁码”照片，作为开门的钥匙。
##
## 运行时图片纹理放在 photo["texture"]（Texture2D）；模型层不依赖纹理，测试可传 null。

const COMBINATION_CODE := "A-317"
const COMBO_WINDOW := 20.0
const CLUE_PAIRS := {
	"clue_a": "clue_b",
	"clue_b": "clue_a",
}

signal photos_changed
signal screen_changed

var photos: Array[Dictionary] = []
var screen_photo_ids: Array[String] = []
var last_result: Dictionary = {}

var _seq := 1


func clear() -> void:
	photos.clear()
	screen_photo_ids.clear()
	last_result.clear()
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


## 把一张照片拖到滚动屏。返回：
## {accepted, combined, screenshot, code, label, photo_id, reason, focus_point}
func drop_to_screen(photo_id: String, now: float) -> Dictionary:
	var photo := find_photo(photo_id)
	if photo.is_empty():
		return _result(false, false, false, "", "", "", "照片不存在")
	if screen_photo_ids.has(photo_id):
		return _result(false, false, false, "", "", "", "这张照片已经在滚动屏上了")
	screen_photo_ids.append(photo_id)

	var kind := String(photo.get("kind", ""))
	if kind == "screenshot":
		var focus: Vector3 = photo.get("meta", {}).get("focus_point", Vector3.ZERO)
		last_result = _result(true, false, true, "", String(photo.get("label", "")),
			photo_id, "", focus, String(photo.get("camera_id", "")))
		screen_changed.emit()
		return last_result
	if kind == "combined":
		last_result = _result(true, true, false, COMBINATION_CODE,
			String(photo.get("label", "")), photo_id, "门禁码已经生成")
		screen_changed.emit()
		return last_result
	if kind != "clue":
		last_result = _result(true, false, false, "", String(photo.get("label", "")), photo_id, "这张照片不能组合")
		screen_changed.emit()
		return last_result

	if screen_photo_ids.size() < 2:
		last_result = _result(true, false, false, "", String(photo.get("label", "")),
			photo_id, "等待另一张照片")
		screen_changed.emit()
		return last_result

	var previous := find_photo(screen_photo_ids[-2])
	var previous_clue := String(previous.get("meta", {}).get("clue_id", ""))
	var current_clue := String(photo.get("meta", {}).get("clue_id", ""))
	var gap := absf(float(photo.get("timestamp", 0.0)) - float(previous.get("timestamp", 0.0)))
	if gap > COMBO_WINDOW:
		last_result = _result(true, false, false, "", String(photo.get("label", "")),
			photo_id, "两张照片间隔太久（%.1fs > %.1fs）" % [gap, COMBO_WINDOW])
		screen_changed.emit()
		return last_result
	if String(CLUE_PAIRS.get(previous_clue, "")) != current_clue:
		last_result = _result(true, false, false, "", String(photo.get("label", "")),
			photo_id, "这两张线索无法组合")
		screen_changed.emit()
		return last_result

	var combined_id := add_photo("combined", "门禁码", String(photo.get("camera_id", "")), now, {
		"source": [String(previous["id"]), photo_id],
		"code": COMBINATION_CODE,
	})
	last_result = _result(true, true, false, COMBINATION_CODE, "门禁码", combined_id,
		"组合成功：门禁码 %s" % COMBINATION_CODE)
	screen_changed.emit()
	return last_result


func get_context() -> Dictionary:
	return {"combination_code": COMBINATION_CODE, "combo_window": COMBO_WINDOW}


func _result(accepted: bool, combined: bool, screenshot: bool, code: String, label: String,
		photo_id: String, reason: String, focus_point: Variant = null,
		camera_id: String = "") -> Dictionary:
	var result := {
		"accepted": accepted,
		"combined": combined,
		"screenshot": screenshot,
		"code": code,
		"label": label,
		"photo_id": photo_id,
		"reason": reason,
		"focus_point": focus_point if focus_point is Vector3 else Vector3.ZERO,
		"camera_id": camera_id,
	}
	return result
