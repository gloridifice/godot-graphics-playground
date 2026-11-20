"""Analyze recorded RGB8 readbacks separately from GPU timestamps; Python + NumPy."""
import argparse
import csv
import gzip
import json
from pathlib import Path
import numpy as np
from run import CASES, COMBO995, COMBO_ORDER, VARIANTS, digest

W = np.array([.2126,.7152,.0722],np.float32)


def luma(root, group, tag, frames):
    p=root/'data'/group/(tag+'.rgb')
    if p.stat().st_size!=frames*320*180*3: raise ValueError(f'incomplete capture: {p}')
    return np.memmap(p,mode='r',dtype=np.uint8,shape=(frames,180,320,3))@W


def table(path, rows):
    with path.open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=rows[0].keys()); writer.writeheader(); writer.writerows(rows)


def quality(root,out,cases):
    ref=lambda tag,n:luma(root,'reference',tag,n)
    native=ref('native',12); native_moved=ref('native_moved',12); poses=[ref(f'pose{i}',24).mean(0) for i in range(9)]; moved=ref('moved',24).mean(0)
    held=np.stack([ref(f'native_pose{i}',1)[0] for i in range(1,9)])
    alignment=abs(ref('native_motion',8)-held)
    if alignment.max()!=0: raise ValueError('motion capture and reference poses are not aligned')
    dark=(native.mean(0)<16)&(poses[0]>=4)&(poses[0]<40)
    lights=(native.mean(0)<16)&(native_moved.mean(0)<16)&(abs(native_moved.mean(0)-native.mean(0))<1)&(abs(moved-poses[0])>=4)
    if dark.sum()<1000 or lights.sum()<100 or not np.all(np.diff(native,axis=0)==0): raise ValueError('invalid dark/relight mask or unstable native control')
    edges=[]
    for prev,cur in zip(poses,poses[1:]):
        gy,gx=np.gradient(cur); e=(np.hypot(gx,gy)>8)&(abs(cur-prev)>4)
        if e.sum()<100: raise ValueError('empty motion edge mask')
        edges.append(e)
    detail=[]; stats=[]
    for case in cases:
        get=lambda tag,n:luma(root,case,tag,n)
        y=get('static',120)[:,dark]; step=abs(np.diff(y,axis=0)); d8=abs(y[8:]-y[:-8]); flicker=step.mean(); motion=get('motion',8)
        edge_errors=[abs(a-b)[e] for a,b,e in zip(motion,poses[1:],edges)]; edge=np.concatenate(edge_errors)
        before=get('before',24).mean(0)[lights]; plateau=get('plateau',24).mean(0)[lights]; response=get('response',96)[:,lights]
        err=abs(response-plateau).mean(1); amplitude=abs(plateau-before).mean(); threshold=max(1.,.1*amplitude)
        if amplitude<4: raise ValueError(f'{case}: negligible relight step {amplitude}')
        t90=next((i+1 for i in range(len(err)-3) if (err[i:i+4]<=threshold).all()),None)
        for name,values in [('static_abs_d1',step.mean(1)),('motion_edge_mae',[x.mean() for x in edge_errors]),('relight_mae',err)]:
            for i,v in enumerate(values):detail.append(dict(case=case,series=name,frame=(i+1)*(4 if name=='motion_edge_mae' else 1),value=float(v)))
        stats.append(dict(case=case,mean_Y=float(y.mean()),mean_abs_d1=float(flicker),p95_abs_d8=float(np.percentile(d8,95)),p95_pixel_sd=float(np.percentile(y.std(0),95)),steady_mae_ref=float(abs(y.mean(0)-poses[0][dark]).mean()),edge_mae=float(edge.mean()),edge_p95=float(np.percentile(edge,95)),relight_frame=t90 or '>96',step_amplitude=float(amplitude),relight_threshold=float(threshold),relight_first8_mae=float(err[:8].mean()),new_plateau_mae_ref=float(abs(plateau-moved[lights]).mean())))
    table(out/'quality.csv',stats);table(out/'per_frame.csv',detail)
    mask_info={'dark_pixels':int(dark.sum()),'relight_pixels':int(lights.sum()),'edge_pixel_counts':[int(e.sum()) for e in edges],'native_max_abs_d1':float(abs(np.diff(native,axis=0)).max()),'native_motion_alignment_max':float(alignment.max()),'stride2_dark_mean':float(poses[0][dark].mean())}
    (out/'masks.json').write_text(json.dumps(mask_info,indent=2)+'\n'); return stats


def settle(root,out,cases):
    ref=luma(root,'reference','pose0',24).mean(0)
    dark=(luma(root,'reference','native',12).mean(0)<16)&(ref>=4)&(ref<40)
    rows=[]
    for case in cases:
        group=case+'-settle'; early=luma(root,group,'draw64',1)[0,dark]
        late=luma(root,group,'late',120)[:,dark]; center=late.mean(0)
        rows.append(dict(case=case,draw64_mae_late=float(abs(early-center).mean()),draw64_p95_error_late=float(np.percentile(abs(early-center),95)),late_abs_d1=float(abs(np.diff(late,axis=0)).mean()),late_mae_ref=float(abs(center-ref[dark]).mean())))
    table(out/'settle.csv',rows)


def timings(root,out,cases,round_count=3):
    rows=[]; records={}
    for case in cases:
        rounds=[json.loads((root/'data'/f'{case}-r{i}/timestamps.json').read_text()) for i in range(1,round_count+1)]; records[case]=rounds
        for size in ['720','1080']:
            for group in rounds:
                v=group[size];n=len(v['SRC total']); assert n>=(16 if round_count==4 else 12) and len(v['Viewport'])>=12
                keys=['Prepare','Trace','Gather','Parents','Deposit','Merge','Receiver','Apply']
                assert all(len(v[k])==n for k in keys) and np.allclose(sum(np.asarray(v[k]) for k in keys),v['SRC total'])
            for key in ['SRC total','Viewport','Trace','Merge','Apply']:
                v=np.concatenate([g[size][key] for g in rounds]);assert np.isfinite(v).all() and min(v)>=0
                rows.append(dict(case=case,height=size,stage=key,n=len(v),median_ms=float(np.median(v)),p95_ms=float(np.percentile(v,95))))
    table(out/'gpu.csv',rows)
    with gzip.open(out/'gpu-samples.json.gz','wt',encoding='utf-8') as f: json.dump(records,f,separators=(',',':'))
    return rows


def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('lab',type=Path);ap.add_argument('output',type=Path);ap.add_argument('--quality-only',action='store_true')
    group=ap.add_mutually_exclusive_group();group.add_argument('--with-ablation',action='store_true');group.add_argument('--combo995',action='store_true');a=ap.parse_args()
    cases=list(COMBO995) if a.combo995 else [*CASES]+(['fixed995'] if a.with_ablation else [])
    a.output.mkdir(parents=True,exist_ok=True)
    base_project=a.lab/'original'; scene='scenes/sponza_src_preview.tscn'; scene_sha=digest(base_project/scene)
    base_hash=json.loads((base_project/'study-inputs.json').read_text()); inputs={}
    for name in dict.fromkeys(VARIANTS[c] for c in cases):
        p=a.lab/name; hashes=json.loads((p/'study-inputs.json').read_text()); assert digest(p/scene)==hashes[scene]==scene_sha
        inputs[name]={'addon_changes':{k:v for k,v in hashes.items() if k.startswith('addons/') and base_hash.get(k)!=v},'imported_shaders':{f.name.split('-')[0]:digest(f) for f in sorted((p/'.godot/imported').glob('*.glsl-*.res'))}}
    meta={'scene_sha256':scene_sha,'original_addon':{k:v for k,v in base_hash.items() if k.startswith('addons/')},'sponza_assets':{f.name:digest(f) for f in sorted((base_project/'assets/sponza').iterdir()) if f.suffix in ('.gltf','.bin','.glb')},'variants':inputs,'quality_run_headers':{c:(a.lab/'data'/c/'run.log').read_text(errors='replace').split('STUDY DONE')[0].strip() for c in cases}}
    if a.combo995:
        kernels={}
        for case,header in meta['quality_run_headers'].items():
            if '; history 0.995;' not in header: raise ValueError(f'{case} silently clamped retention')
            entry=next(l for l in header.splitlines() if l.startswith('KERNELS '))
            kernels[case]=json.loads(entry.removeprefix('KERNELS '))
        if (len({v['cascades'] for v in kernels.values()})!=4 or len({v['hardware_trace'] for v in kernels.values()})!=1
                or {k for k,v in kernels.items() if 'screen_filter' in v}!={'screen995','ac995'}
                or kernels['screen995']['screen_filter']!=kernels['ac995']['screen_filter']):
            raise ValueError('wrong combination or stale shader import')
        meta['loaded_spirv']=kernels
        meta['timing_order']=[[cases[i] for i in order] for order in COMBO_ORDER]
    (a.output/'inputs.json').write_text(json.dumps(meta,indent=2)+'\n')
    q=quality(a.lab,a.output,cases)
    if not a.quality_only:
        if a.combo995: settle(a.lab,a.output,cases)
        g=timings(a.lab,a.output,cases,4 if a.combo995 else 3)
        control='fixed995' if a.combo995 else 'ctrl99'
        base=next(x for x in q if x['case']==control)
        med={x['case']:x['median_ms'] for x in g if x['height']=='1080' and x['stage']=='SRC total'}
        gates=[]
        for v in q:
            key=v['case']; checks=dict(flicker=v['mean_abs_d1']<=.85*base['mean_abs_d1'],brightness=abs(v['mean_Y']-base['mean_Y'])<=1,edge=v['edge_mae']-base['edge_mae']<=.5,relight=isinstance(v['relight_frame'],int) and isinstance(base['relight_frame'],int) and v['relight_frame']<=base['relight_frame']+4,gpu1080=med[key]-med[control]<=.30)
            gates.append(dict(case=key,**checks,passes=all(checks.values())))
        table(a.output/'gates.csv',gates)
    print('Wrote measurements to',a.output)

if __name__=='__main__': main()
