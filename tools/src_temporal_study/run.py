"""Run outside the source tree: independent Godot imports, no shared GPU history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ADDON = Path('addons/split_radiance_cascades')
CASES = {'ctrl98':'original','adaptive':'adaptive','sequence':'sequence','screen':'screen','ctrl99':'original'}
COMBO995 = {'fixed995':'long_history','adaptive995':'adaptive_long','screen995':'screen_long','ac995':'adaptive_screen_long'}
VARIANTS = {**CASES,**COMBO995}
# Same shader patches as the single-factor experiments. Only the study setter
# is widened; the screen filter does not inherit the probe retention value.
LONG_PATCHES = {'long_history':(), 'adaptive_long':('adaptive',), 'screen_long':('screen',), 'adaptive_screen_long':('adaptive','screen')}
COMBO_ORDER = ((0,1,3,2),(1,2,0,3),(2,3,1,0),(3,0,2,1))


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def log_run(cmd, log, env=None, timeout=300):
    with log.open('w', encoding='utf-8') as f:
        proc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout)
    s = log.read_text(encoding='utf-8', errors='replace')
    if proc.returncode or re.search(r'(?:SCRIPT |SHADER )?ERROR:', s):
        raise RuntimeError(f'{log} (exit {proc.returncode})\n{s[-3500:]}')
    return s


def patch_variant(p, patches):
    for name in patches:
        subprocess.run(['git','apply',str(HERE/(name+'.patch'))],cwd=p,check=True)
    if 'screen' in patches:
        for f in ['screen_filter.gd','screen_filter.glsl']:
            shutil.copy2(HERE/f, p/ADDON/('shaders' if f.endswith('glsl') else '')/f)


def preview_scene(project):
    # The real scene remains byte-identical. Open this inherited scene in the
    # scratch editor (Camera preview) or run it directly for a movable View 3.
    base='res://scenes/sponza_src_preview.tscn'
    scene=(project/base.removeprefix('res://')).read_text(encoding='utf-8')
    marker=re.search(r'^\[node name="Arcade"[^\n]* parent="Views"[^\n]*\]\n(transform = [^\n]+)',scene,re.M)
    if not marker: raise ValueError('missing Arcade transform in Sponza scene')
    dest=project/'scenes/sponza_temporal_preview.tscn'
    dest.write_text('[gd_scene format=3]\n\n[ext_resource type="PackedScene" path="'+base+'" id="1"]\n\n'
                    '[node name="SponzaSRCPreview" instance=ExtResource("1")]\n\n'
                    '[node name="SplitRadianceCascades" parent="WorldEnvironment" index="0"]\n'
                    'trace_proxy_root = NodePath("")\nprefer_hardware_trace = true\nhistory_retention = 0.995\n\n'
                    '[node name="Camera3D" parent="." index="3"]\n'+marker.group(1)+'\n',encoding='utf-8')


def prepare(out, engine, variant):
    p = out / variant
    if variant in LONG_PATCHES:
        base = out/'original'
        if not (base/'study-inputs.json').is_file(): prepare(out,engine,'original')
        shutil.copytree(base,p) # no links across experiments
        shaders = LONG_PATCHES[variant]
        patch_variant(p, ('long_history',*shaders))
        shutil.copy2(HERE/'measure.gd',p/'tools/temporal_measure.gd')
        preview_scene(p)
        if shaders:
            # An edited .inc alone doesn't reliably invalidate Godot's import.
            for stale in (p/'.godot/imported').glob('cascades.glsl-*'): stale.unlink()
            finish_import(out,engine,variant)
        else: manifest(p) # setter only; no shader changes
        return
    p.mkdir()  # never overwrite or delete an existing project
    for rel in [ADDON, Path('assets/sponza')]:
        shutil.copytree(ROOT/rel,p/rel)
    for rel in ['scenes/sponza_src_preview.tscn','scripts/camera/sponza_preview_camera.gd','scripts/camera/sponza_preview_camera.gd.uid','tools/profile_sponza_src.gd','tools/profile_sponza_src.gd.uid','icon.svg','icon.svg.import']:
        (p/rel).parent.mkdir(exist_ok=True,parents=True)
        shutil.copy2(ROOT/rel,p/rel)
    cfg = (ROOT/'project.godot').read_text(encoding='utf-8')
    cfg = re.sub(r'^\[(autoload|editor_plugins)\]\n.*?(?=^\[|\Z)', '', cfg, flags=re.M|re.S)
    cfg = cfg.replace('res://scenes/fog_playground.tscn','res://scenes/sponza_src_preview.tscn').replace('config/name="graphics"','config/name="SRC Temporal Lab"')
    (p/'project.godot').write_text(cfg, encoding='utf-8')
    shutil.copy2(HERE/'measure.gd',p/'tools/temporal_measure.gd')
    # Existing imported textures/meshes may be copied for speed. Never share files
    # by link and never reuse a compiled study shader between variants.
    imported = p/'.godot/imported'; imported.mkdir(parents=True)
    cache = ROOT/'.godot/imported'
    for meta in (p/'assets/sponza').rglob('*.import'):
        dests = re.findall(r'"res://\.godot/imported/([^"/]+)"',meta.read_text(encoding='utf-8'))
        for name in set(dests):
            prefix = re.match(r'.*-[0-9a-f]{32}(?=\.)', name)
            candidates = [cache/name] + ([cache/(prefix.group()+'.md5')] if prefix else [])
            for src in candidates:
                if src.is_file() and not (imported/src.name).exists(): shutil.copy2(src,imported/src.name)
    if variant != 'original': patch_variant(p,(variant,))
    finish_import(out, engine, variant)


def finish_import(out, engine, variant):
    p = out / variant
    log_run([engine,'--path',str(p),'--rendering-driver','vulkan','--single-window','--import'],out/(variant+'-import.log'),timeout=900)
    manifest(p)


def manifest(p):
    files = [p/'scenes/sponza_src_preview.tscn',p/'project.godot',*(p/ADDON).rglob('*.gd'),*(p/ADDON).rglob('*.glsl'),*(p/ADDON).rglob('*.inc')]
    (p/'study-inputs.json').write_text(json.dumps({f.relative_to(p).as_posix():digest(f) for f in sorted(files)},indent=2))


def measure(out, engine, case, job, label):
    p = out / VARIANTS[case]
    result = out/'data'/label
    result.mkdir(parents=True)  # reruns must have a fresh label
    env = dict(os.environ, SRC_STUDY_OUT=result.as_posix(), SRC_STUDY_CASE=case)
    print(f'{label}: {case} {job}',flush=True)
    s = log_run([engine,'--path',str(p),'--rendering-driver','vulkan','--disable-vsync','--max-fps','0','--script','res://tools/temporal_measure.gd','--',job],result/'run.log',env)
    if 'STUDY DONE' not in s: raise RuntimeError(f'incomplete run: {result}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('job',choices=['prepare','reference','quality','timing','settle','all'])
    ap.add_argument('--out',type=Path,required=True); ap.add_argument('--godot',required=True)
    select=ap.add_mutually_exclusive_group()
    select.add_argument('--cases',nargs='+',choices=list(VARIANTS),default=list(CASES))
    select.add_argument('--combo995',action='store_true',help='2 x 2 experiment: fixed / A / C / A+C, all at 0.995')
    args=ap.parse_args()
    if args.combo995: args.cases=list(COMBO995)
    if args.job=='settle' and any(c not in COMBO995 for c in args.cases): ap.error('settle uses the 0.995 preview scenes')
    out=args.out.resolve(); engine=shutil.which(args.godot) or str(Path(args.godot).resolve())
    if out == ROOT or ROOT in out.parents or out in ROOT.parents: ap.error('use a dedicated directory outside the repository')
    if args.job in ('prepare','all'):
        if not out.exists(): out.mkdir(parents=True)
        elif not (out/'.src-temporal-lab').is_file() and any(out.iterdir()): ap.error('refusing a nonempty unmarked directory')
        (out/'.src-temporal-lab').touch()
        variants=list(dict.fromkeys(VARIANTS[c] for c in args.cases))
        if 'original' in variants: variants.remove('original'); variants.insert(0,'original')
        for v in variants: prepare(out,engine,v)
    elif not (out/'.src-temporal-lab').is_file(): ap.error('prepare the study first')
    if args.job in ('reference','all'): measure(out,engine,'ctrl98','reference','reference')
    if args.job in ('quality','all'):
        for c in args.cases: measure(out,engine,c,'quality',c)
    if args.job in ('timing','all'):
        cases=args.cases
        orders=COMBO_ORDER if args.combo995 else [tuple((j+2*i)%len(cases) for j in range(len(cases))) for i in range(3)]
        for i,order in enumerate(orders,1):
            for j in order: measure(out,engine,cases[j],'timing',f'{cases[j]}-r{i}')
    if args.job=='settle' or (args.job=='all' and args.combo995):
        for c in args.cases: measure(out,engine,c,'settle',c+'-settle')


if __name__=='__main__': main()
