import bpy
import os
from mathutils import Vector

SRC = r"E:\dev\vibe\dual-faced-world\external-assets\_work\chicken\鸡哥模型.fbx"
OUT = r"E:\dev\vibe\dual-faced-world\external-assets\generated\chicken.glb"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

# Drop the imported camera; keep the mesh hierarchy and empties (the empties carry scale/pivot).
for obj in list(bpy.data.objects):
    if obj.type == 'CAMERA':
        bpy.data.objects.remove(obj, do_unlink=True)

# Solid-color FBX materials -> simple Principled base colors; no textures in this asset.
material_map = {}
for mat in list(bpy.data.materials):
    new_mat = bpy.data.materials.new("Anime_" + mat.name)
    new_mat.use_nodes = True
    new_mat.node_tree.nodes.clear()
    output = new_mat.node_tree.nodes.new('ShaderNodeOutputMaterial')
    bsdf = new_mat.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
    new_mat.node_tree.links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])
    color = mat.diffuse_color
    bsdf.inputs['Base Color'].default_value = color
    bsdf.inputs['Roughness'].default_value = 0.82
    bsdf.inputs['Metallic'].default_value = 0.0
    material_map[mat.name] = new_mat

for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    for slot in obj.material_slots:
        if slot.material and slot.material.name in material_map:
            slot.material = material_map[slot.material.name]

mins = [1e9, 1e9, 1e9]
maxs = [-1e9, -1e9, -1e9]
for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    for c in obj.bound_box:
        p = obj.matrix_world @ Vector(c)
        for i in range(3):
            mins[i] = min(mins[i], p[i])
            maxs[i] = max(maxs[i], p[i])
print("BOUNDS_MIN", mins, "BOUNDS_MAX", maxs, "SIZE", [maxs[i] - mins[i] for i in range(3)])

os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=OUT,
    export_format='GLB',
    export_apply=False,
    export_animations=False,
    export_skins=False,
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
