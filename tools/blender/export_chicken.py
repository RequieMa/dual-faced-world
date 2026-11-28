import bpy
import os
from mathutils import Vector

SRC = r"E:\dev\vibe\dual-faced-world\external-assets\_work\chicken\鸡哥模型.fbx"
OUT = r"E:\dev\vibe\dual-faced-world\external-assets\generated\chicken.glb"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

# Drop the imported camera.
for obj in list(bpy.data.objects):
    if obj.type == 'CAMERA':
        bpy.data.objects.remove(obj, do_unlink=True)

# Flatten the FBX hierarchy. It imports with an empty scale=0.001 and mesh scale=-25,
# which makes the GLB root offset huge and the avatar render far outside its NPC node.
# Bake world transforms into the meshes, join them, and export one clean static mesh.
mesh_objects = [obj for obj in bpy.data.objects if obj.type == 'MESH']
for obj in mesh_objects:
    world = obj.matrix_world.copy()
    obj.parent = None
    obj.matrix_world = world
bpy.context.view_layer.update()
bpy.ops.object.select_all(action='DESELECT')
for obj in mesh_objects:
    obj.select_set(True)
bpy.context.view_layer.objects.active = mesh_objects[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
bpy.ops.object.join()
joined = bpy.context.view_layer.objects.active
joined.name = "Chicken"
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.normals_make_consistent(inside=False)
bpy.ops.object.mode_set(mode='OBJECT')

# Center the joined mesh on X/Z and put its feet at the origin before export.
# Otherwise the FBX-baked world offset leaks into the GLB and the runtime
# normalizer places the avatar far away from its NPC node.
bpy.context.view_layer.update()
corners = [joined.matrix_world @ Vector(c) for c in joined.bound_box]
min_x = min(p.x for p in corners)
max_x = max(p.x for p in corners)
min_y = min(p.y for p in corners)
max_y = max(p.y for p in corners)
min_z = min(p.z for p in corners)
joined.location = Vector((-(min_x + max_x) * 0.5, -(min_y + max_y) * 0.5, -min_z))
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

for obj in list(bpy.data.objects):
    if obj.type == 'EMPTY':
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
