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

def test_malformed_usb_output_is_an_explicit_delivery_loss_with_counter_continuity():
    # Actual damaged line: the middle metadata disappeared while the remaining
    # payload was still complete. It must never become a successful packet.
    line = (f'RX n=2 state=0 code=0 len=32 rssi=-96.0header_crc=on '
            f'header_code=0 buffer_offset=0 payload={payload(11).hex()}')
    with pytest.raises(ValueError):
        parse_rx(line)
    broken = parse_rx(line, allow_malformed=True)
    assert broken['raw']==line and broken['sequence'] is None and not broken['crc_valid']
    rows = [record(10,1), broken, record(12,3)]
    assert not summary(rows)['measurement_valid']
    r = summary(rows, allow_malformed_rx=True)
    assert r['measurement_valid'] and r['received_unique']==2 and r['per']==pytest.approx(.6)
    assert r['serial_parse_errors']==1 and r['crc_fail']==0
    assert r['serial_event_counts_complete'] and not r['serial_transport_complete']
    assert not summary(rows,allow_malformed_rx=True,final_counter=4)['measurement_valid']
    assert not summary(rows,allow_malformed_rx=True,tx_complete=False)['measurement_valid']

@pytest.mark.parametrize('prefix', ['RX n=x', 'RX n=0', 'RX state=0', 'RX n=1 n=2'])
def test_malformed_output_without_an_unambiguous_counter_stays_fatal(prefix):
    with pytest.raises((ValueError,KeyError)):
        parse_rx(prefix+' payload=bad',allow_malformed=True)

def test_conducted_delivery_counts_unknown_outputs_without_adding_successes():
    # Observed LR1121 readData-success outputs: empty or a four-byte prefix
    # followed by a truncated planned payload. Preserve them as unknown outputs.
    shifted = b'\0'*4 + payload(12)[:-4]
    rows = [record(10,1), record(11,2,data=b''), record(12,3,data=shifted)]
    assert not summary(rows)['measurement_valid']
    r = summary(rows,allow_unrecognized_rx=True)
    assert r['measurement_valid'] and r['received_unique']==1
    assert r['foreign_packets']==2 and r['per']==pytest.approx(.8)
    assert not summary(rows,allow_unrecognized_rx=True,final_counter=4)['measurement_valid']
    assert not summary(rows,allow_unrecognized_rx=True,tx_complete=False)['measurement_valid']

@pytest.mark.parametrize('metadata', [
    'header_crc=off header_code=0 rx_done=1',
    'header_crc=unknown header_code=-2 rx_done=1',
    'header_crc=on header_code=0 rx_done=0',
])
def test_lr1121_crc_and_rx_done_metadata_are_required_when_reported(metadata):
    data=payload(10)
    r=parse_rx(f'RX n=1 state=0 code=0 len={len(data)} rssi=-90 snr=-7 ferr=0 '
               f'{metadata} payload={data.hex()}')
    assert not r['crc_valid']
    assert summary([r])['received_unique']==0

def test_lr1121_protected_rx_done_preserves_planned_success():
    data=payload(10)
    r=parse_rx(f'RX n=1 state=0 code=0 len={len(data)} rssi=-90 snr=-7 ferr=0 '
               f'header_crc=on header_code=0 rx_done=1 irq=0x38 buffer_offset=4 payload={data.hex()}')
    assert r['crc_valid'] and summary([r])['received_unique']==1

def test_duplicates_crc_failure_and_payload_validation():
    r=summary([record(10,1),record(10,2),record(11,3,'crc')])
    assert r['measurement_valid'] and r['received_unique']==1 and r['duplicates']==1 and r['crc_fail']==1
    bad=bytearray(payload(12)); bad[-1]^=1
    corrupt = summary([record(12,1,data=bytes(bad))])
    assert corrupt['measurement_valid'] and corrupt['payload_mismatches'] == 1
    assert corrupt['received_unique'] == 0 and corrupt['per'] == 1
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
