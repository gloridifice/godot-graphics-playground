"""Make a labeled comparison from actual GPU readbacks, never from a render mock.
Optional dependencies: Pillow, NumPy, ffmpeg (libx264). No Godot or GPU usage.
"""
import argparse
from pathlib import Path
import subprocess
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from run import COMBO995

CASES=list(COMBO995)
TITLES=('Fixed 0.995','A + 0.995','C + 0.995','A + C + 0.995')
SIZE=(1340,500)


def rgb(root,case,tag,n):
    p=root/'data'/case/(tag+'.rgb')
    if p.stat().st_size!=n*320*180*3: raise ValueError(f'incomplete capture: {p}')
    return np.memmap(p,mode='r',dtype=np.uint8,shape=(n,180,320,3))


def font(size):
    for path in ('C:/Windows/Fonts/segoeui.ttf','DejaVuSans.ttf'):
        try: return ImageFont.truetype(path,size)
        except OSError: continue
    return ImageFont.load_default()


def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('lab',type=Path);ap.add_argument('mp4',type=Path);a=ap.parse_args()
    top,sub=font(23),font(17)
    a.mp4.parent.mkdir(exist_ok=True,parents=True)
    cmd=['ffmpeg','-v','error','-y','-f','rawvideo','-pixel_format','rgb24','-video_size','1340x500','-framerate','24','-i','pipe:0','-an','-c:v','libx264','-threads','2','-preset','medium','-crf','15','-pix_fmt','yuv420p','-movflags','+faststart',str(a.mp4)]
    def fields(tag,n): return [rgb(a.lab,c,tag,n) for c in CASES]
    with subprocess.Popen(cmd,stdin=subprocess.PIPE) as video:
        def send(label,bottom,imgs,refs,gain,repeat=1):
            canvas=Image.new('RGB',SIZE,(21,25,30));draw=ImageDraw.Draw(canvas)
            draw.text((12,5),'Sponza / Arcade     '+label,font=top,fill=(239,242,244))
            draw.text((12,36),'Top: recorded composite, same exposure.     Playback: 24 frames/s (not a performance measurement).',font=sub,fill=(185,195,201))
            draw.text((12,266),bottom,font=sub,fill=(235,207,150))
            for i,(img,ref) in enumerate(zip(imgs,refs)):
                x=12+332*i;draw.text((x,61),TITLES[i],font=sub,fill='white');canvas.paste(Image.fromarray(img),(x,84))
                diff=np.clip(np.abs(img.astype(np.float32)-ref)*gain,0,255).astype('uint8');canvas.paste(Image.fromarray(diff),(x,295))
            raw=canvas.tobytes()
            for _ in range(repeat): video.stdin.write(raw)
        seq=fields('static',120)
        for j in range(1,120): send(f'Camera held | draw {j+1:03d}/120','Bottom: absolute RGB change since previous frame, x64 (diagnostic only).',[s[j] for s in seq],[s[j-1] for s in seq],64)
        seq=fields('motion',8)
        for j in range(8):
            ref=rgb(a.lab,'reference',f'pose{j+1}',24).mean(0)
            send(f'Camera moving | draw {4*(j+1):02d}/32','Bottom: error versus the dense reference at the SAME pose, x12. One capture every four draws.',[s[j] for s in seq],[ref]*4,12,4)
        settled=[s.mean(0) for s in fields('plateau',24)]
        for tag,n,start in [('before',24,12),('response',96,0)]:
            seq=fields(tag,n)
            for j in range(start,n):
                label='Light about to move' if tag=='before' else f'Light moved | draw {j+1:02d}/96'
                send(label,'Bottom: absolute RGB difference from each column\'s own settled post-move image, x4.',[s[j] for s in seq],settled,4)
        video.stdin.close()
        if video.wait()!=0: raise RuntimeError('ffmpeg failed')

if __name__=='__main__': main()
