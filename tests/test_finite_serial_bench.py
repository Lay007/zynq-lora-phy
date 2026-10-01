from pathlib import Path
from types import SimpleNamespace
import sys
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from finite_serial_bench import LineReader, parse_rx, summarize_serial, verify_profile
from lora_per_ideal import test_payload as payload

def record(seq,count,state='0',data=None):
    data=payload(seq) if data is None else data
    return parse_rx(f'RX n={count} state={state} code={0 if state=="0" else -7} '
                    f'len={len(data)} rssi=-90 snr=-7 ferr=3 payload={data.hex()}')

def summary(records,**kwargs):
    defaults=dict(first=10,packets=5,final_counter=len(records),tx_complete=True,collection_complete=True)
    defaults.update(kwargs)
    return summarize_serial(records,**defaults)

def test_losses_at_both_edges_are_in_denominator():
    r=summary([record(11,1),record(12,2),record(13,3)])
    assert r['measurement_valid'] and r['per']==pytest.approx(.4)
    assert r['missing_sequences']==[10,14]

def test_total_rf_loss_remains_a_valid_measurement():
    assert summary([])['per']==1

def test_duplicates_crc_failure_and_payload_validation():
    r=summary([record(10,1),record(10,2),record(11,3,'crc')])
    assert r['measurement_valid'] and r['received_unique']==1 and r['duplicates']==1 and r['crc_fail']==1
    bad=bytearray(payload(12)); bad[-1]^=1
    assert not summary([record(12,1,data=bytes(bad))])['measurement_valid']
    assert not summary([record(100,1)])['measurement_valid']

@pytest.mark.parametrize('records,final', [([record(10,2)],2),([record(10,1)],2),([],1)])
def test_serial_loss_invalidates_per(records,final):
    r=summary(records,final_counter=final)
    assert not r['serial_transport_complete'] and r['per'] is None

@pytest.mark.parametrize('key', ['tx_complete','collection_complete'])
def test_incomplete_trial_has_no_per(key):
    assert summary([],**{key:False})['per'] is None

def test_partial_serial_lines_are_preserved():
    class Port:
        in_waiting=1
        chunks=iter([b'RX n=1 pay',b'load=abcd\r',b'\nPROFILE sf=7\n'])
        def read(self,n): return next(self.chunks,b'')
    import time
    reader=LineReader(Port()); deadline=time.monotonic()+1
    assert reader.readline(deadline)=='RX n=1 payload=abcd'
    assert reader.readline(deadline)=='PROFILE sf=7'

def test_profile_requires_ldro_and_counter():
    args=SimpleNamespace(sf=12,cr=1,bw=500)
    p=dict(sf='12',cr='4/5',bw_khz='500.0',freq_mhz='868.100',sync='0x12',preamble='12',
           crc='on',boost='on',receiving='yes',ldro='off',rx_packets='0')
    verify_profile(p,args,True)
    with pytest.raises(ValueError): verify_profile(dict(p,ldro='on'),args,True)
    p.pop('rx_packets')
    with pytest.raises(ValueError): verify_profile(p,args,True)
