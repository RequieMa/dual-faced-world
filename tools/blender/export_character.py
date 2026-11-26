## Blender 4.2 headless export helper for the three demo avatars.
## Run:
##   blender -b SOYO1.blend --python export_character.py -- soyo out.glb
##   blender -b TacticalLumine_decoded.blend --python export_character.py -- lumine out.glb
import bpy
import bmesh
import sys
import os
from mathutils import Vector

argv = sys.argv
print("RAW_ARGV", argv)
if "--" in argv:
    argv = argv[argv.index("--") + 1:]
else:
    argv = []
print("SCRIPT_ARGV", argv)
if len(argv) < 2:
    raise SystemExit("usage: export_character.py -- <soyo|lumine> <out.glb>")
MODE = argv[0].lower()
OUT = argv[1]
print("EXPORT_MODE", MODE, "OUT", OUT)

# Pack external textures if present so the GLB is self-contained.
try:
    bpy.ops.file.pack_all()
except Exception as exc:
    print("PACK_WARN", exc)


def has_outline_material(obj):
    for slot in obj.material_slots:
        if slot.material and "outline" in slot.material.name.lower():
            return True
    return False


def strip_outline_surfaces(obj):
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    remove_indices = set()
    for i, slot in enumerate(obj.material_slots):
        name = slot.material.name.lower() if slot.material else ""
        if "outline" in name or name.startswith("edge_"):
            remove_indices.add(i)
    if not remove_indices:
        bm.free()
        return True
    for face in list(bm.faces):
        if face.material_index in remove_indices:
            bm.faces.remove(face)
    mapping = {}
    kept_materials = []
    for i, slot in enumerate(obj.material_slots):
        if i in remove_indices:
            continue
        mapping[i] = len(kept_materials)
        kept_materials.append(slot.material)
    for face in bm.faces:
        if face.material_index in mapping:
            face.material_index = mapping[face.material_index]
    bm.to_mesh(me)
    bm.free()
    me.materials.clear()
    for mat in kept_materials:
        me.materials.append(mat)
    return len(me.polygons) > 0


def best_image(mat):
    if mat is None or not mat.use_nodes:
        return None
    candidates = []
    for node in mat.node_tree.nodes:
        if node.type == 'TEX_IMAGE' and node.image is not None:
            name = node.image.name.lower()
            score = 1
            if "diffuse" in name or "basecolor" in name or "base_color" in name:
                score += 6
            elif "texture" in name or "albedo" in name:
                score += 5
            elif "pants" in name:
                score += 4
            elif "clothes" in name or "body" in name or "hair" in name or "face" in name:
                score += 2
            for bad in ["shadow", "lightmap", "normal", "ramp", "mask", "metal", "highlight", "spec"]:
                if bad in name:
                    score -= 5
            if "light" in name:
                score -= 3
            candidates.append((score, node.image))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def make_anime_material(old_mat):
    name = "Anime_" + (old_mat.name if old_mat else "Default")
    existing = bpy.data.materials.get(name)
    if existing is not None:
        return existing
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.node_tree.nodes.clear()
    output = mat.node_tree.nodes.new('ShaderNodeOutputMaterial')
    bsdf = mat.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
    mat.node_tree.links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])
    bsdf.inputs['Roughness'].default_value = 0.82
    bsdf.inputs['Metallic'].default_value = 0.0
    image = best_image(old_mat)
    if image is not None:
        tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
        tex.image = image
        mat.node_tree.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
        mat.node_tree.links.new(tex.outputs['Alpha'], bsdf.inputs['Alpha'])
    elif old_mat is not None:
        bsdf.inputs['Base Color'].default_value = old_mat.diffuse_color
    if hasattr(mat, "blend_method"):
        mat.blend_method = 'HASHED'
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = 'DITHERED'
    return mat


def is_character_mesh(obj):
    if obj.type != 'MESH':
        return False
    if obj.hide_render:
        return False
    if not obj.material_slots:
        return False
    mats = [s.material.name.lower() if s.material else "" for s in obj.material_slots]
    if not mats:
        return False
    if all("rigid" in m for m in mats if m):
        return False
    if any(m.startswith("mmd_tools_rigid") for m in mats if m):
        return False
    if MODE == "soyo":
        if obj.name.startswith("Bone.") or obj.name.startswith("J.Bone") or obj.name.startswith("front hair"):
            return False
        return True
    if MODE == "lumine":
        return obj.name.startswith("Lumine") or obj.name == "Lumine Chest pouches"
    # Generic fallback (e.g. a future Fontaine mesh blend): keep every rendered mesh
    # that still has a usable material; rigid helper/outline surfaces are filtered above.
    return True


keep = []
for obj in bpy.data.objects:
    if is_character_mesh(obj):
        keep.append(obj)

if MODE == "soyo":
    for obj in bpy.data.objects:
        if obj.type == 'ARMATURE' and obj.name in ("soyo mmd", "soyo mmd.001"):
            keep.append(obj)
        if obj.type == 'EMPTY' and obj.name == "soyo":
            keep.append(obj)
elif MODE == "lumine":
    for obj in bpy.data.objects:
        if obj.type == 'ARMATURE' and obj.name.startswith("Lumine rig"):
            keep.append(obj)
else:
    for obj in bpy.data.objects:
        if obj.type == 'ARMATURE':
            keep.append(obj)

# Strip outline shell surfaces before material simplification.
final_meshes = []
for obj in keep:
    if obj.type != 'MESH':
        continue
    if not strip_outline_surfaces(obj):
        print("DROP_EMPTY_MESH", obj.name)
        continue
    final_meshes.append(obj)

# Build simplified anime materials and assign them.
material_map = {}
for obj in final_meshes:
    for slot in obj.material_slots:
        if slot.material is None:
            continue
        if slot.material.name not in material_map:
            material_map[slot.material.name] = make_anime_material(slot.material)
        slot.material = material_map[slot.material.name]

# Delete everything that is not part of the character.
keep_set = set(keep)
for obj in list(bpy.data.objects):
    if obj not in keep_set:
        try:
            bpy.data.objects.remove(obj, do_unlink=True)
        except Exception as exc:
            print("DELETE_WARN", obj.name, exc)

# Report bounds for the Godot-side normalizer.
mins = [1e9, 1e9, 1e9]
maxs = [-1e9, -1e9, -1e9]
for obj in final_meshes:
    corners = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    for p in corners:
        for i in range(3):
            mins[i] = min(mins[i], p[i])
            maxs[i] = max(maxs[i], p[i])
print("BOUNDS_MIN", mins, "BOUNDS_MAX", maxs, "HEIGHT", maxs[2] - mins[2])

os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=OUT,
    export_format='GLB',
    export_apply=False,
    export_animations=False,
    export_skins=True,
    export_morph=False,
    export_materials='EXPORT',
    export_image_format='AUTO',
    export_cameras=False,
    export_lights=False,
    export_yup=True,
    export_texcoords=True,
    export_normals=True,
    export_extras=True,
)
print("EXPORT_DONE", OUT)
