from pathlib import Path
import subprocess,os,json,re,sys,time,argparse,hashlib
import numpy as np
parser=argparse.ArgumentParser(description="Real-density SF7/BW125 full-packet joint ToA/CFO RTL regression")
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--jobs',type=int,default=4)
parser.add_argument('--extra-source', action='append', default=[],
                    help='Additional RTL source relative to the source tree')
args=parser.parse_args()
tree=Path(__file__).resolve().parents[1]
out=args.out.resolve()
out.mkdir(parents=True,exist_ok=True)
os.chdir(tree)
sys.path[:0]=[str(tree/'tools'),str(tree/'src')]
from lora_tx_waveform import packet_waveform
from lora_per_ideal import test_payload
from zynq_lora_phy import decode_lora_symbol_trace
sources=[str(p.relative_to(tree)) for p in sorted((tree/'fpga/generated/fft-correlator-fixed/lora_fft_correlator_gen').glob('*.v'))]
sources += ['fpga/generated/blind-detector/lora_blind_detector_gen/lora_blind_BlindDetector.v',
 'fpga/generated/toa-interpolator/lora_toa_interpolator_gen/lora_toa_ToaInterpolator.v']
sources += ['fpga/wrappers/'+name+'.v' for name in (
 'fft_correlator_route_top', 'lora_detector_timestamp_align', 'lora_detector_timestamp_path',
 'lora_cfo_derotator','lora_fft_detector_timestamp_path','lora_iq_history_buffer',
 'lora_reference_chirp_rom','lora_matched_filter_mac','lora_peak_triplet_capture',
 'lora_matched_filter_search','lora_joint_chirp_grid_controller','lora_symbol_grid_resync',
 'lora_timestamp_metadata_join','lora_axi_lite_status','lora_packet_toa_receiver_top')]
sources += ['fpga/tb/tb_replay_detect.sv']
for name in args.extra_source:
    path=(tree/name).resolve()
    if not path.is_relative_to(tree) or not path.is_file():
        parser.error('extra source must be an existing file in the source tree')
    sources.append(str(path.relative_to(tree)))
directory=out/'simulator'
cmd=['verilator','--binary','--timing','-j',str(args.jobs),'-Wno-fatal',
     '--unroll-count','4096','--unroll-stmts','1000000',
     '--top-module','tb_replay_detect','-DLORA_NAMESPACED_GENERATED',
     '-GSEARCH_RADIUS=48','-GFINE_GUARD=48','-GFAST_MAC=1','-GPREFETCH_UP=1',
     '-GCOARSE_STRIDE=2','--Mdir',str(directory),*sources]
with (out/'build.log').open('w') as log:
    result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
result.check_returncode(); print('Full packet simulator compiled',flush=True)
rows=[]
payload=test_payload(1234)
cases=[(508,1500,8,0),(512,1500,12,0),(0,0,8,0),(0,1500,8,0),(296,-1500,8,0),
       (512,-1500,8,0),(511,-1500,12,0),(700,1500,12,0),(1023,-1500,12,0),
       (508,418,8,.25),(511,-418,8,.5),(512,1000,12,.75),(1023,-1000,12,.25),
       (512,0,8,0),(508,-1000,8,.25),(512,418,12,.5),(512,-418,12,.75)]
for phase,cfo,preamble,fraction in cases:
    clean=packet_waveform(payload,7,125000,1)
    if preamble==8: clean=clean[4*1024:]
    lead=2048+phase
    x=np.pad(clean,(lead,2048))
    if fraction:
        # Bandlimited fractional translation with zero guards at both edges.
        x=np.fft.ifft(np.fft.fft(x)*np.exp(-2j*np.pi*np.fft.fftfreq(len(x))*fraction))
    x=x*np.exp(2j*np.pi*cfo/1e6*np.arange(len(x)))*400
    words=((np.rint(x.real).astype(np.int64)&65535)<<16)|(np.rint(x.imag).astype(np.int64)&65535)
    name=f'phase{phase}-cfo{cfo}-L{preamble}-frac{fraction:g}'
    hexfile=out/(name+'.hex'); hexfile.write_text('\n'.join(f'{v:08x}' for v in words)+'\n')
    started=time.monotonic()
    result=subprocess.run([str(directory/'Vtb_replay_detect'),f'+iq={hexfile}',f'+n={len(x)}',
                           '+gap=62','+gap_half=1'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(name+'.log')).write_text(result.stdout); result.check_returncode()
    syms=[int(v) for v in re.findall(r'^SYM (\d+) \d+',result.stdout,re.M)]
    det=re.search(r'^DET (\d+) (\d+) n=(\d+)',result.stdout,re.M)
    if not det: raise RuntimeError('no detection: '+name)
    # The trace decoder starts at the detection window, as board software does.
    at_det=result.stdout.index('\nDET ')
    syms=[int(v) for v in re.findall(r'^SYM (\d+) \d+',result.stdout[at_det:],re.M)]
    decoded=decode_lora_symbol_trace(syms,0).result
    meta=re.findall(r'^META (\d+) (-?\d+)',result.stdout,re.M)
    latency=re.search(r'^LATENCY joint_total_clocks=(\d+) down_to_fine_clocks=(\d+) n=(\d+) cfo_q12=(-?\d+)',result.stdout,re.M)
    if not meta or not latency: raise RuntimeError('missing joint completion: '+name)
    total,down,fine_n,estimate=map(int,latency.groups())
    detection_clocks=int(re.search(r'detection_to_fine_clocks=(\d+)',result.stdout).group(1))
    expected_origin=lead+fraction+(preamble-8)*1024
    coarse,frac=map(int,meta[0]); error=coarse+frac/4096-expected_origin
    header_start=lead+int((preamble+4.25)*1024)
    row={'phase':phase,'cfo_hz':cfo,'preamble_symbols':preamble,'fractional_delay':fraction,
         'crc_valid':bool(decoded.crc_valid),'payload_match':bytes(decoded.payload)==payload,
         'toa_error_samples':error,'joint_clocks':total,'down_to_fine_clocks':down,
         'prefetch_span_us_including_rf_wait':total/62.5,'fine_sample_count':fine_n,'header_start_sample':header_start,
         'detection_to_fine_us':detection_clocks/62.5,
         'header_margin_samples':header_start-fine_n,'estimated_cfo_hz':-estimate/4096/8192*1e6,
         'simulation_seconds':time.monotonic()-started,'raw_log':name+'.log'}
    rows.append(row); (out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(row,flush=True)
    if not (row['crc_valid'] and row['payload_match'] and abs(error)<.5 and row['header_margin_samples']>96):
        raise RuntimeError('full packet regression failed: '+name)
(out/'provenance.json').write_text(json.dumps({'pl_clock_hz':62500000,'sample_rate_hz':1000000,'search_radius':48,'guard_samples':48,'coarse_stride':2,'prefetch_up':True,'request_on_response':True,'verilator_version':subprocess.check_output(['verilator','--version'],text=True).strip(),'source_sha256':{name:hashlib.sha256((tree/name).read_bytes()).hexdigest() for name in sources}},indent=2)+'\n')
print('PASS full packet CRC/ToA/deadline at 62.5 clocks/sample',flush=True)
