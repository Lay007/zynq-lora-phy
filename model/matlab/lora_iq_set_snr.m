function [y, info] = lora_iq_set_snr(file, snr_db, varargin)
%LORA_IQ_SET_SNR Make a copy of an IQ recording with the LoRa signal at a set SNR.
%   Y = LORA_IQ_SET_SNR(FILE, SNR_DB) finds the LoRa dwells with LORA_IQ_SNR, cuts
%   each one out with a band-pass filter of one LoRa bandwidth, sets every dwell to
%   the same level and adds white complex Gaussian noise so that the SNR in the LoRa
%   bandwidth is SNR_DB. The recording's own noise is dropped (only the in-channel
%   part is kept, ~40 dB below the signal), so the output has the noise you ask for.
%
%   Options (name, value):
%     'Out'         output .iq file (int16 I,Q) or '' for none   ('')
%     'SignalDbfs'  signal level in the channel, dBFS; [] keeps the median of the
%                   recording                                    ([])
%     'Start'       first second read from FILE                  (0)
%     'Duration'    seconds read                                 (1)
%     'Fs','BW'     as in LORA_IQ_SNR                            (40e6, 500e3)
%     'Seed'        noise seed                                   (1)
%
%   The noise is white over the whole sampling band, as the bench's lora_tx_noise
%   makes it, and its power in BW is signal / 10^(SNR/10). Y is single complex, scaled
%   as the file (int16 units); if white noise at a low SNR would overflow int16,
%   signal and noise are scaled down together (INFO.gain_db). INFO holds the dwell table, the levels and the SNR read
%   back from the result by LORA_IQ_SNR.
%
%   The recording's own noise leaves a floor: an SNR above about 38 dB cannot be
%   reached, and the function warns.
%
%   Example:
%     [y, info] = lora_iq_set_snr('IQREC.iq', 10, 'Out', 'IQREC_snr10.iq');

p = inputParser;
addParameter(p, 'Out', '');
addParameter(p, 'SignalDbfs', []);
addParameter(p, 'Start', 0);
addParameter(p, 'Duration', 1);
addParameter(p, 'Fs', 40e6);
addParameter(p, 'BW', 500e3);
addParameter(p, 'Seed', 1);
parse(p, varargin{:});
o = p.Results;
fs = o.Fs; bw = o.BW; fullscale = 32768;

% ---- find the dwells ---------------------------------------------------------------
r = lora_iq_snr(file, 'Fs', fs, 'BW', bw, 'Start', o.Start, 'Duration', o.Duration, 'Plot', false);
nd = numel(r.start_s);
assert(nd > 0, 'no LoRa signal found');
if snr_db > min(r.snr_db) - 2
    warning('lora_iq_set_snr:floor', ...
        'Requested SNR %.1f dB is close to the recording''s own %.1f dB (min over dwells): the result will be lower.', ...
        snr_db, min(r.snr_db));
end

% ---- read -----------------------------------------------------------------------------
n  = round(o.Duration * fs);
fid = fopen(file, 'r'); fseek(fid, round(o.Start * fs) * 4, 'bof');
raw = fread(fid, [2, n], 'int16=>single'); fclose(fid);
n = size(raw, 2);
z = complex(raw(1, :), raw(2, :)).'; clear raw

% ---- cut every dwell out, measure its signal power --------------------------------------
margin = round(100e-6 * fs);                       % room for the filter ends
taper  = round(100e-6 * fs);
sig = zeros(n, 1, 'single');
Sj = zeros(1, nd);
pieces = cell(1, nd); rng_ = zeros(nd, 2);
for j = 1:nd
    a = max(1, round((r.start_s(j) - o.Start) * fs) + 1 - margin);
    b = min(n, round((r.start_s(j) - o.Start + r.dur_ms(j) * 1e-3) * fs) + margin);
    seg = z(a:b);
    m = numel(seg);
    win = ones(m, 1, 'single');
    tw = min(taper, floor(m/2));
    ramp = single(0.5 - 0.5 * cos(pi * ((0:tw-1)' + 0.5) / tw));
    win(1:tw) = ramp; win(end-tw+1:end) = flipud(ramp);
    F = fft(seg .* win);
    fr = ((0:m-1)' / m); fr(fr >= 0.5) = fr(fr >= 0.5) - 1; fr = fr * fs;   % Hz
    % centre of the channel: spectral centroid near the frame-wise estimate
    Pw = abs(F).^2; near = abs(fr - r.fc_hz(j)) < bw;
    base = median(Pw(abs(fr - r.fc_hz(j)) < 3e6));
    q = max(Pw(near) - base, 0);
    fcj = sum(fr(near) .* q) / sum(q);
    F(abs(fr - fcj) > 0.525 * bw) = 0;             % one bandwidth, 5 % margin
    s = ifft(F);
    pw = abs(s).^2;
    pwf = movmean(pw, round(51e-6 * fs));          % frame-length smoothing
    hot = pwf > 0.5 * prctile(pwf, 90);            % samples with signal (not the gaps)
    hot(1:tw) = false; hot(end-tw+1:end) = false;
    Sj(j) = mean(pw(hot));
    pieces{j} = s; rng_(j, :) = [a b];
end
if isempty(o.SignalDbfs)
    St = median(Sj);
else
    St = fullscale^2 * 10^(o.SignalDbfs / 10);
end
for j = 1:nd
    sig(rng_(j,1):rng_(j,2)) = sig(rng_(j,1):rng_(j,2)) + pieces{j} * sqrt(St / Sj(j));
end

% ---- noise ----------------------------------------------------------------------------
rs = RandStream('mt19937ar', 'Seed', o.Seed);
Nbw = St / 10^(snr_db / 10);                       % noise power in BW
sigma2 = Nbw * fs / bw;                            % total, white over fs
noise = single(sqrt(sigma2 / 2)) * complex(randn(rs, n, 1, 'single'), randn(rs, n, 1, 'single'));
y = sig + noise;

% keep 10 % headroom: scale signal and noise together, the SNR does not change
peak = max(abs([real(y); imag(y)]));
gain = min(1, 0.9 * 32767 / peak);
if gain < 1
    y = y * gain; St = St * gain^2; Nbw = Nbw * gain^2;
    fprintf('Scaled by %.1f dB to fit int16 (white noise over the whole band is loud at low SNR)\n', 20*log10(gain));
end

info.dwells = r; info.signal_dbfs = 10*log10(St / fullscale^2);
info.noise_dbfs_in_bw = 10*log10(Nbw / fullscale^2); info.requested_snr_db = snr_db;
info.peak = peak * gain; info.gain_db = 20*log10(gain);
fprintf('Signal %.1f dBFS, noise in %.0f kHz %.1f dBFS, SNR %.1f dB\n', ...
    info.signal_dbfs, bw/1e3, info.noise_dbfs_in_bw, snr_db);

% ---- write and read back -------------------------------------------------------------
if ~isempty(o.Out)
    q = zeros(2, n, 'int16');
    q(1, :) = int16(max(min(round(real(y)), 32767), -32768));
    q(2, :) = int16(max(min(round(imag(y)), 32767), -32768));
    fid = fopen(o.Out, 'w'); fwrite(fid, q, 'int16'); fclose(fid);
    fprintf('Written %s (%.2f s, %.0f MB)\n', o.Out, n/fs, n*4/1e6);
    if snr_db >= 12      % below that the detector (10 dB threshold) cannot find the dwells
        chk = lora_iq_snr(o.Out, 'Fs', fs, 'BW', bw, 'Duration', o.Duration, 'Plot', false);
        info.measured_snr_db = chk.snr_db;
        fprintf('Read back: SNR median %.1f dB (requested %.1f)\n', median(chk.snr_db), snr_db);
    else
        fprintf('Read-back skipped: SNR below the detector''s 10 dB threshold\n');
    end
end
end
