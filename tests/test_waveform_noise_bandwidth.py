from pathlib import Path
import sys
import numpy as np
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from lora_tx_waveform import build, packet_waveform, SAMPLE_RATE
from lora_per_ideal import test_payload as payload


@pytest.mark.parametrize('sf', range(5,13))
def test_cached_waveform_chirps_match_css_primitives(sf):
    from lora_tx_waveform import chirp
    from zynq_lora_phy.css import CssConfig, modulate_symbol, reference_chirp
    config = CssConfig(spreading_factor=sf, samples_per_chip=2)
    for symbol in [0, 1, (1 << sf)//2, (1 << sf)-1]:
        expected = modulate_symbol(symbol, config)
        expected *= np.conjugate(expected[0])
        np.testing.assert_array_equal(chirp(1 << sf, 2, symbol), expected)
    np.testing.assert_array_equal(chirp(1 << sf, 2, up=False), reference_chirp(config, up=False))


@pytest.mark.parametrize('sf', range(5,13))
def test_native_low_sf_framing_keeps_header_after_extra_upchirps(sf):
    from zynq_lora_phy import encode_lora_packet
    from zynq_lora_phy.css import CssConfig, reference_chirp, modulate_symbol
    config = CssConfig(spreading_factor=sf, samples_per_chip=2)
    size = config.samples_per_symbol
    symbols = encode_lora_packet(payload(0), spreading_factor=sf).symbols
    wave = packet_waveform(payload(0),sf,500000,1)
    extra = 2 if sf < 7 else 0
    header = int((16.25+extra)*size)
    assert len(wave) == header+len(symbols)*size
    if extra:
        # SX1262 native captures at both SF5 and SF6 identify bin 1 here.
        native_extra = modulate_symbol(1, config)
        native_extra *= np.conjugate(native_extra[0])
        np.testing.assert_allclose(wave[header-2*size:header-size], native_extra)
        np.testing.assert_allclose(wave[header-size:header], native_extra)
    expected = modulate_symbol(int(symbols[0]),config)
    np.testing.assert_allclose(wave[header:header+size], expected*np.conjugate(expected[0]))

@pytest.mark.parametrize('bw',[125,250,500])
def test_injected_noise_is_flat_across_full_receiver_bandwidth(bw):
    snr=-6
    # Four packets reduce uncertainty of the independently estimated RF gain
    # at this deliberately low SNR; a single short BW500 packet is too noisy.
    x,meta=build(7,bw,1,snr,4,.1,123,901,-14)
    signal=np.zeros(len(x),dtype=complex)
    for packet in meta:
        clean=packet_waveform(payload(packet['sequence']),7,bw*1000,1)
        signal[packet['start_sample']:packet['start_sample']+len(clean)]=clean
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
