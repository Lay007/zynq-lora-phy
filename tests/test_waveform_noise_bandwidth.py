from pathlib import Path
import sys
import numpy as np
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from lora_tx_waveform import build, packet_waveform, SAMPLE_RATE
from lora_per_ideal import test_payload as payload

@pytest.mark.parametrize('bw',[125,250,500])
def test_injected_noise_is_flat_across_full_receiver_bandwidth(bw):
    snr=-6
    x,_=build(7,bw,1,snr,1,.1,123,901,-14)
    clean=packet_waveform(payload(123),7,bw*1000,1)
    signal=np.pad(clean,(0,len(x)-len(clean)))
    gain=np.vdot(signal,x)/np.vdot(signal,signal)
    noise=x/gain-signal
    psd=np.abs(np.fft.fft(noise))**2/(len(noise)*SAMPLE_RATE)
    f=np.fft.fftfreq(len(noise),1/SAMPLE_RATE)
    inner=(np.abs(f)<.2*bw*1000)
    outer=(np.abs(f)>.35*bw*1000)&(np.abs(f)<.48*bw*1000)
    # Equal densities near centre and edges; the old +/-150k BW500 cutoff fails.
    assert np.mean(psd[outer])/np.mean(psd[inner])==pytest.approx(1,rel=.12)
    actual=np.mean(psd[np.abs(f)<bw*500])*bw*1000
    assert 10*np.log10(1/actual)==pytest.approx(snr,abs=.3)
