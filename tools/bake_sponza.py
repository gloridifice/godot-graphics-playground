"""Build the Sponza preview from Intel's Base Scene + Colorful Curtains (offline).
Requires Pillow, NumPy and gltfpack 1.2. See assets/sponza/SOURCE.md.
"""
import argparse
import copy
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image


TEXTURE_LIMIT = 2048
JPEG_QUALITY = 90


def prepare_textures(doc, source, work, cache):
    for image in doc['images']:
        src = source / image['uri']
        if src.name not in cache:
            name = src.stem.lower()
            # The exporter concatenates the source roughness/metalness names.
            if '_roughness' in name:
                name = name.split('_roughness')[0] + '_rm'
            elif 'decal' in name:
                name = 'dirt_decal_basecolor'
            with Image.open(src) as original:
                is_decal = name == 'dirt_decal_basecolor'
                im = original.convert('RGBA' if is_decal else 'RGB')
                im.thumbnail((TEXTURE_LIMIT, TEXTURE_LIMIT), Image.Resampling.LANCZOS)
                if is_decal:
                    # JPEG has no alpha; the Godot decal material reads this as linear opacity.
                    im.getchannel('A').save(work / 'textures/dirt_decal_opacity.jpg', quality=JPEG_QUALITY)
                    im = im.convert('RGB')
                uri = f'textures/{name}.jpg'
                im.save(work / uri, quality=JPEG_QUALITY, subsampling=0)
                # World-space hits use a constant, not the texture; estimate it
                # in linear light (metalness is already linear, blue channel).
                pixels = np.asarray(im)[::8, ::8, :3].astype(np.float32) / 255
                if name.endswith('_rm'):
                    mean = float(pixels[:, :, 2].mean())
                else:
                    mean = np.where(pixels <= .04045, pixels / 12.92,
                                    ((pixels + .055) / 1.055) ** 2.4).mean(axis=(0, 1)).tolist()
            cache[src.name] = uri, mean
        image['uri'] = cache[src.name][0]


def trace_model(doc, means):
    proxy = copy.deepcopy(doc)
    for mesh in proxy['meshes']:
        mesh['primitives'] = [p for p in mesh['primitives']
                              if proxy['materials'][p['material']].get('alphaMode', 'OPAQUE') == 'OPAQUE']
        for prim in mesh['primitives']:
            prim['attributes'] = {'POSITION': prim['attributes']['POSITION']}
    for node in proxy['nodes']:
        if 'mesh' in node and not proxy['meshes'][node['mesh']]['primitives']:
            del node['mesh']
    # Avoid empty meshes in the intermediate glTF (decal-only nodes).
    keep = [i for i, m in enumerate(proxy['meshes']) if m['primitives']]
    mapping = {old: new for new, old in enumerate(keep)}
    proxy['meshes'] = [proxy['meshes'][i] for i in keep]
    for node in proxy['nodes']:
        if 'mesh' in node:
            node['mesh'] = mapping[node['mesh']]

    def mean(tex):
        return means[proxy['images'][proxy['textures'][tex['index']]['source']]['uri']]

    for mat in proxy['materials']:
        pbr = mat['pbrMetallicRoughness']
        color = np.array(pbr.get('baseColorFactor', [1, 1, 1, 1])[:3], dtype=float)
        metal = pbr.get('metallicFactor', 1.0)
        if 'baseColorTexture' in pbr:
            color *= mean(pbr['baseColorTexture'])
        if 'metallicRoughnessTexture' in pbr:
            metal *= mean(pbr['metallicRoughnessTexture'])
        mat['pbrMetallicRoughness'] = dict(baseColorFactor=[*color, 1.0], metallicFactor=metal)
        mat.pop('normalTexture', None)
    for key in ('textures', 'images', 'samplers'):
        del proxy[key]
    return proxy


def triangles(doc):
    return sum(doc['accessors'][p['indices']]['count'] // 3 for n in doc['nodes'] if 'mesh' in n
               for p in doc['meshes'][n['mesh']]['primitives'])


def bake(base, curtains, gltfpack, out):
    out.mkdir(exist_ok=True, parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / 'textures').mkdir()
        cache, deliver = {}, []
        total_visible = total_trace = 0
        for name, gltf in [('palace', base), ('curtains', curtains)]:
            doc = json.loads(gltf.read_text(encoding='utf-8-sig'))
            for buffer in doc['buffers']:
                shutil.copyfile(gltf.parent / buffer['uri'], work / buffer['uri'])
            # The preview owns its cameras and real-time lights. Keep all mesh transforms.
            for key in ('cameras', 'extensions', 'extensionsUsed'):
                doc.pop(key, None)
            for node in doc['nodes']:
                node.pop('camera', None)
                node.pop('extensions', None)
            prepare_textures(doc, gltf.parent, work, cache)
            proxy = trace_model(doc, dict(cache.values()))
            # Lock open architectural borders: adjacent vaults/arches are separate
            # surfaces. Cloth can simplify its hems without opening gaps in the palace.
            visible = (['-si', '0.065', '-se', '0.0025', '-slb'] if name == 'palace' else
                       ['-si', '0.071', '-se', '0.004'])
            for model, suffix, options in [(doc, '.gltf', visible + ['-sp', '-tr']),
                                           (proxy, '_trace.glb', ['-si', '0.009', '-sa'])]:
                src, dst = work / 'input.gltf', work / (name + suffix)
                src.write_text(json.dumps(model), encoding='utf-8')
                subprocess.run([gltfpack, '-i', src, '-o', dst, '-noq', *options], check=True)
                if dst.suffix == '.glb':
                    blob = dst.read_bytes()
                    length = struct.unpack_from('<I', blob, 12)[0]
                    count = triangles(json.loads(blob[20:20 + length]))
                    total_trace += count
                else:
                    count = triangles(json.loads(dst.read_text(encoding='utf-8')))
                    total_visible += count
                    deliver.append(dst.with_suffix('.bin'))
                deliver.append(dst)
                print(f'{dst.name}: {count:,} triangles', flush=True)
        if not 300_000 <= total_visible <= 500_000:
            raise ValueError(f'{total_visible:,} visible triangles outside the 300k–500k budget')
        if not 0 < total_trace <= 65536:
            raise ValueError(f'{total_trace:,} proxy triangles outside the SRC budget')
        for path in deliver:
            shutil.copyfile(path, out / path.name)
        shutil.copytree(work / 'textures', out / 'textures', dirs_exist_ok=True)
        shutil.copyfile(base.parent / 'credits_license.txt', out / 'credits_license.txt')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path, help='NewSponza_Main_glTF_003.gltf')
    parser.add_argument('curtains', type=Path, help='NewSponza_Curtains_glTF.gltf')
    parser.add_argument('--gltfpack', default='gltfpack', help='path to the gltfpack 1.2 executable')
    parser.add_argument('--output', type=Path, default=Path('assets/sponza'))
    args = parser.parse_args()
    bake(args.base, args.curtains, args.gltfpack, args.output)
