from pathlib import Path
import sys
import numpy as np
import pytest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import lora_per_ideal as ideal


@pytest.mark.parametrize('sf,bw,expected', [
    (10,125,False),(11,125,True),(11,250,False),
    (12,125,True),(12,250,True),(12,500,False)])
def test_ldro_modes(sf,bw,expected):
    assert ideal.ldro_required(sf,bw) == expected


@pytest.mark.parametrize('sf,snr,n', [(7,-10,10000),(12,-25,2048)])
def test_exact_decision_matches_waveform_fft(sf,snr,n):
    symbols = np.arange(n).reshape(-1,1) % (1 << sf)
    fft = ideal.symbol_error_matrix(symbols,sf,snr,np.random.default_rng(190))
    direct = ideal.exact_decision_matrix(symbols,sf,snr,np.random.default_rng(821))
    p_fft = np.mean(fft != symbols)
    p_direct = np.mean(direct != symbols)
    assert 0.02 < p_fft < 0.98  # Exercise decisions in the transition region.
    sigma = np.sqrt((p_fft*(1-p_fft)+p_direct*(1-p_direct))/n)
    assert abs(p_fft-p_direct) < 6*sigma


def test_packet_layer_agrees_with_waveform():
    # Independent noise trials, actual FEC/header/CRC decoder and exact payload.
    a = ideal.run_point((7,4,-12,600,615,125,'waveform-fft'))
    b = ideal.run_point((7,4,-12,600,912,125,'exact-decision'))
    sigma = np.sqrt((a['per']*(1-a['per'])+b['per']*(1-b['per']))/600)
    assert abs(a['per']-b['per']) < 6*sigma
    assert a['symbols_per_packet'] == b['symbols_per_packet']


def test_ldro_changes_packet_geometry():
    on = ideal.run_point((12,1,20,3,100,125,'exact-decision'))
    off = ideal.run_point((12,1,20,3,100,500,'exact-decision'))
    assert on['per'] == off['per'] == 0
    assert on['ldro'] and not off['ldro']
    assert on['symbols_per_packet'] > off['symbols_per_packet']
