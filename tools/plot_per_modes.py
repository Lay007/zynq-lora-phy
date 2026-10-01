"""Plot separate BW panels with binomial uncertainty and explicit LDRO labels."""
from __future__ import annotations
import argparse
import csv
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def wilson(errors, n):
    p=np.asarray(errors,dtype=float)/n
    z=1.959963984540054
    centre=(p+z*z/(2*n))/(1+z*z/n)
    half=z*np.sqrt(p*(1-p)/n+z*z/(4*n*n))/(1+z*z/n)
    return np.maximum(0,centre-half),np.minimum(1,centre+half)


def plot(data,out):
    out.mkdir(parents=True,exist_ok=True)
    rows=data['rows']; thresholds=[]
    colors=plt.get_cmap('tab10').colors
    for bw in sorted({r['bw_khz'] for r in rows}):
        fig,axes=plt.subplots(2,2,figsize=(11,8),sharex=True,sharey=True)
        for ax,cr in zip(axes.flat,(1,2,3,4)):
            for index,sf in enumerate(range(7,13)):
                pts=sorted((r for r in rows if r['bw_khz']==bw and r['sf']==sf and r['cr']==cr),key=lambda r:r['snr_db'])
                if not pts: continue
                x=np.array([r['snr_db'] for r in pts]); p=np.array([r['per'] for r in pts])
                lo,hi=wilson(np.array([r['packet_errors'] for r in pts]),pts[0]['packets'])
                label=f'SF{sf}'+(' (LDRO)' if pts[0]['ldro'] else '')
                ax.plot(x,np.where(p>0,p,np.nan),color=colors[index],label=label)
                ax.fill_between(x,np.maximum(lo,5e-4),np.maximum(hi,5e-4),where=p>0,color=colors[index],alpha=.12)
                zero=p==0
                # One-sided 95% exact upper bound; zero errors are not PER=0 proof.
                upper=1-.05**(1/pts[0]['packets'])
                if zero.any():
                    ax.plot(x[zero][0],upper,'v',color=colors[index],ms=5,alpha=.8)
                threshold={'sf':sf,'bw_khz':bw,'cr':cr,'ldro':pts[0]['ldro'],'packets_per_point':pts[0]['packets']}
                for target in (.1,.01):
                    threshold[f'first_grid_snr_per_le_{target:g}']=next((r['snr_db'] for r in pts if r['per']<=target),None)
                thresholds.append(threshold)
            ax.set_title(f'CR 4/{cr+4}',loc='left'); ax.set_yscale('log'); ax.set_ylim(5e-4,1.15)
            ax.grid(alpha=.25); ax.legend(fontsize=8,loc='lower left')
            ax.set_xlabel('SNR in signal bandwidth, dB'); ax.set_ylabel('Packet error rate')
        fig.suptitle(f'Ideal synchronized LoRa in AWGN — BW {bw:g} kHz, 32-byte payload')
        counts=sorted({r['packets'] for r in rows})
        fig.text(.05,.02,f'{" / ".join(map(str,counts))} packets/point; shaded: pointwise 95% Wilson intervals; ▼: 95% upper bound at first zero-error point.\n'
                 'Equal SF/CR/LDRO reuse the same normalized trials across bandwidths. No CFO, timing error or RF hardware impairments.',fontsize=8)
        fig.tight_layout(rect=(0,.065,1,.96))
        for ext in ('png','pdf'): fig.savefig(out/f'per-ideal-bw{bw:g}.{ext}',dpi=180)
        plt.close(fig)
    (out/'thresholds.json').write_text(json.dumps(thresholds,indent=2)+'\n')
    with (out/'thresholds.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(thresholds[0])); writer.writeheader(); writer.writerows(thresholds)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input',type=Path); parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); plot(json.loads(args.input.read_text()),args.out)
