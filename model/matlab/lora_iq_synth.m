function [z, truth] = lora_iq_synth(snr_db, varargin)
%LORA_IQ_SYNTH Synthetic frequency-hopping LoRa recording with a known SNR.
%   [Z, TRUTH] = LORA_IQ_SYNTH(SNR_DB) returns complex samples in int16 units:
%   LoRa packets (lora_phy.build_lora_packet) hopping over 'Channels', a few
%   packets per channel, plus complex white Gaussian noise over the whole
%   sampling band. SNR_DB is the SNR in the LoRa bandwidth: signal power over
%   the noise power in BW. TRUTH holds what an estimator should find.
%
%   Options (name, value):
%     'Fs'            sample rate, Hz                         (8e6)
%     'BW'            bandwidth, Hz (Fs/BW integer)           (500e3)
%     'SF'            spreading factor                        (7)
%     'Channels'      channel centres, one dwell each, Hz     ([-2.4 -1.2 0 1.2 2.4]*1e6)
%     'PacketsPerDwell'                                       (4)
%     'Period'        packet period, s                        (10e-3)
%     'Preamble'      preamble upchirps                       (7)
%     'SyncWord'                                              (0x12)
%     'PayloadBytes'                                          (8)
%     'CodingRate'    1..4 for 4/5..4/8                       (3)
%     'Crc'                                                   (false)
%     'ExplicitHeader'                                        (false)
%     'SignalDbfs'    signal power, dB re 32768^2             (-20)
%     'Seed'                                                  (1)

p = inputParser;
addParameter(p, 'Fs', 8e6);
addParameter(p, 'BW', 500e3);
addParameter(p, 'SF', 7);
addParameter(p, 'Channels', [-2.4 -1.2 0 1.2 2.4] * 1e6);
addParameter(p, 'PacketsPerDwell', 4);
addParameter(p, 'Period', 10e-3);
addParameter(p, 'Preamble', 7);
addParameter(p, 'SyncWord', hex2dec("12"));
addParameter(p, 'PayloadBytes', 8);
addParameter(p, 'CodingRate', 3);
addParameter(p, 'Crc', false);
addParameter(p, 'ExplicitHeader', false);
addParameter(p, 'SignalDbfs', -20);
addParameter(p, 'Seed', 1);
parse(p, varargin{:});
o = p.Results;
fs = o.Fs; bw = o.BW;
spc = fs / bw;
assert(abs(spc - round(spc)) < 1e-9, 'Fs/BW must be an integer');
spc = round(spc);

rs = RandStream('mt19937ar', 'Seed', o.Seed);
cfg = lora_phy.phy_config(o.SF, spc, o.CodingRate);
cfg.payloadCrc = o.Crc;
cfg.explicitHeader = o.ExplicitHeader;
cfg.lowDataRateOptimization = o.SF >= 11 && bw <= 125e3;
if ~o.ExplicitHeader, cfg.payloadLength = o.PayloadBytes; end

np = o.PacketsPerDwell; nd = numel(o.Channels);
nper = round(o.Period * fs);
n = nd * np * nper;
amp = 32768 * 10^(o.SignalDbfs / 20);
z = complex(zeros(n, 1));
t = (0:n-1)' / fs;
starts = zeros(1, nd * np); fcs = zeros(1, nd * np);
nsym = 0; len = 0;
for d = 1:nd
    for k = 1:np
        i = (d - 1) * np + k;
        payload = randi(rs, [0 255], o.PayloadBytes, 1);
        [w, info] = lora_phy.build_lora_packet(payload, cfg, PreambleSymbols = o.Preamble, ...
            SyncWord = o.SyncWord, InitialPhaseRadians = 2*pi*rand(rs));
        a = (i - 1) * nper + round(0.05 * nper) + 1;  % small lead-in of noise
        b = a + numel(w) - 1;
        assert(b <= i * nper, 'packet longer than the period');
        z(a:b) = amp * w .* exp(2j * pi * o.Channels(d) * t(a:b));
        starts(i) = (a - 1) / fs; fcs(i) = o.Channels(d);
        nsym = numel(info.encoded.symbols); len = numel(w);
    end
end
signalPower = amp^2;
noiseInBw = signalPower / 10^(snr_db / 10);
sigma2 = noiseInBw * fs / bw;                      % white over fs
z = z + sqrt(sigma2 / 2) * complex(randn(rs, n, 1), randn(rs, n, 1));

truth.fs = fs; truth.bw_hz = bw; truth.sf = o.SF; truth.snr_db = snr_db;
truth.signal_dbfs = o.SignalDbfs; truth.noise_dbfs_in_bw = 10*log10(noiseInBw / 32768^2);
truth.packet_start_s = starts; truth.fc_hz = fcs; truth.channels_hz = o.Channels;
truth.dwell_s = np * o.Period; truth.period_s = o.Period;
truth.preamble = o.Preamble; truth.sync_word = o.SyncWord;
truth.payload_bytes = o.PayloadBytes; truth.coding_rate = o.CodingRate; truth.crc = o.Crc;
truth.explicit_header = o.ExplicitHeader; truth.payload_symbols = nsym;
truth.airtime_s = len / fs;
end
