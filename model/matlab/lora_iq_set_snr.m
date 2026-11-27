function [y, info] = lora_iq_set_snr(file, snr_db, varargin)
%LORA_IQ_SET_SNR Make a copy of an IQ recording with the LoRa signal at a set SNR.
%   Y = LORA_IQ_SET_SNR(FILE, SNR_DB) finds the LoRa dwells with LORA_IQ_SNR, cuts
%   each one out with a band-pass filter of one LoRa bandwidth, sets every dwell to
%   the same level and adds white complex Gaussian noise so that the SNR in the LoRa
%   bandwidth is SNR_DB. The recording's own noise is dropped (only the in-channel
%   part is kept, ~40 dB below the signal), so the output has the noise you ask for.
%   FILE can also be a complex vector of samples in int16 units.
%
%   Options (name, value):
%     'Out'         output .iq file (int16 I,Q) or '' for none   ('')
%     'SignalDbfs'  signal level in the channel, dBFS; [] keeps the median of the
%                   first chunk                                  ([])
%     'Start'       first second read from FILE                  (0)
%     'Duration'    seconds read; Inf = to the end of FILE       (1)
%     'Chunk'       seconds processed at a time                  (1)
%     'Fs','BW'     as in LORA_IQ_SNR                            (40e6, 500e3)
%     'Seed'        noise seed                                   (1)
%     'NoiseBW'     noise bandwidth, Hz: Inf = white over Fs; less limits it to
%                   |f| < NoiseBW/2, like a receiver's front-end filter    (Inf)
%
%   The noise is white over the whole sampling band (or over 'NoiseBW'), as the bench's
%   lora_tx_noise makes it, and its power in BW is signal / 10^(SNR/10). Y is single complex, scaled
%   as the file (int16 units); if white noise at a low SNR would overflow int16,
%   signal and noise are scaled down together (INFO.gain_db). INFO holds the dwell table, the levels and the SNR read
%   back from the result by LORA_IQ_SNR.
%
%   A recording longer than 'Chunk' is processed chunk by chunk, so a whole
%   recording fits in memory. Each chunk is read with 50 ms on either side, so a
%   dwell across a chunk border (a hop lasts ~40 ms) is cut out whole. The signal
%   level and the int16 gain are set on the first chunk and kept for the rest, and
%   the noise is one continuous stream; samples that would still overflow int16
%   are clipped and counted (INFO.clipped). With 'Out' and more than one chunk, Y
%   is empty: the result is only in the file (10 s at 40 MS/s is 3.2 GB in memory).
%
%   The recording's own noise leaves a floor: an SNR above about 38 dB cannot be
%   reached, and the function warns.
%
%   Example:
%     [y, info] = lora_iq_set_snr('IQREC.iq', 10, 'Out', 'IQREC_snr10.iq');
%     [~, info] = lora_iq_set_snr('IQREC.iq', 10, 'Out', 'all_snr10.iq', 'Duration', Inf);

p = inputParser;
addParameter(p, 'Out', '');
addParameter(p, 'SignalDbfs', []);
addParameter(p, 'Start', 0);
addParameter(p, 'Duration', 1);
addParameter(p, 'Chunk', 1);
addParameter(p, 'Fs', 40e6);
addParameter(p, 'BW', 500e3);
addParameter(p, 'Seed', 1);
addParameter(p, 'NoiseBW', Inf);
parse(p, varargin{:});
o = p.Results;
fs = o.Fs; bw = o.BW; fullscale = 32768;

n0 = round(o.Start * fs);
n = min(source_length(file) - n0, round(o.Duration * fs));
assert(n > 0, 'nothing to read after %.3f s', o.Start);
nc = round(o.Chunk * fs);
nchunks = ceil(n / nc);
pad = 0;
if nchunks > 1, pad = round(50e-3 * fs); end
keep_y = isempty(o.Out) || nchunks == 1;
y = zeros(n * keep_y, 1, 'single');

St = [];
if ~isempty(o.SignalDbfs), St = fullscale^2 * 10^(o.SignalDbfs / 10); end
rs = RandStream('mt19937ar', 'Seed', o.Seed);
gain = []; clipped = 0;
dw = struct('start_s', [], 'dur_ms', [], 'fc_hz', [], 'snr_db', [], 'sig_dbfs', [], 'duty', []);
fid = -1;
if ~isempty(o.Out)
    fid = fopen(o.Out, 'w'); assert(fid > 0, 'cannot write %s', o.Out);
end

for k = 1:nchunks
    c0 = (k - 1) * nc; c1 = min(n, k * nc);        % kept samples [c0, c1) after n0
    r0 = max(0, c0 - pad); r1 = min(n, c1 + pad);  % read with the margins
    z = read_samples(file, n0 + r0, r1 - r0);

    % ---- find the dwells, cut every one out, measure its signal power ----------------
    r = lora_iq_snr(z, 'Fs', fs, 'BW', bw, 'Duration', numel(z) / fs, 'Plot', false);
    [pieces, rng_, Sj] = cut_dwells(z, r, fs, bw);
    clear z
    if isempty(St)
        assert(~isempty(Sj), 'no LoRa signal found in the first %.1f s', o.Chunk);
        St = median(Sj);
    end
    sig = zeros(r1 - r0, 1, 'single');
    for j = 1:numel(pieces)
        sig(rng_(j,1):rng_(j,2)) = sig(rng_(j,1):rng_(j,2)) + pieces{j} * sqrt(St / Sj(j));
    end
    clear pieces
    % the dwell table: each dwell once, in the chunk where it starts
    s0 = r0 + round(r.start_s * fs);
    in = s0 >= c0 & s0 < c1;
    dw.start_s  = [dw.start_s,  o.Start + s0(in) / fs];
    dw.dur_ms   = [dw.dur_ms,   r.dur_ms(in)];
    dw.fc_hz    = [dw.fc_hz,    r.fc_hz(in)];
    dw.snr_db   = [dw.snr_db,   r.snr_db(in)];
    dw.sig_dbfs = [dw.sig_dbfs, r.sig_dbfs(in)];
    dw.duty     = [dw.duty,     r.duty(in)];

    % ---- noise ------------------------------------------------------------------------
    m = c1 - c0;
    Nbw = St / 10^(snr_db / 10);                   % noise power in BW
    sigma2 = Nbw * fs / bw;                        % total, white over fs
    noise = single(sqrt(sigma2 / 2)) * complex(randn(rs, m, 1, 'single'), randn(rs, m, 1, 'single'));
    if o.NoiseBW < fs
        % band-limited like a receiver's front end: white over |f| < NoiseBW/2, nothing
        % outside; the density inside, and so the noise in BW, does not change
        G = fft(noise);
        fq = (0:m-1)' / m; fq(fq >= 0.5) = fq(fq >= 0.5) - 1;
        G(abs(fq * fs) > o.NoiseBW / 2) = 0;
        noise = ifft(G);
        clear G fq
    end
    yk = sig(c0 - r0 + 1:c1 - r0) + noise;
    clear sig noise

    % keep 10 % headroom: scale signal and noise together, the SNR does not change
    if isempty(gain)
        peak = max(abs([real(yk); imag(yk)]));
        gain = min(1, 0.9 * 32767 / peak);
        if gain < 1
            fprintf('Scaled by %.1f dB to fit int16 (white noise over the whole band is loud at low SNR)\n', 20*log10(gain));
        end
    end
    yk = yk * gain;
    clipped = clipped + nnz(abs(real(yk)) > 32767 | abs(imag(yk)) > 32767);
    if keep_y, y(c0+1:c1) = yk; end

    if fid > 0
        q = zeros(2, m, 'int16');
        q(1, :) = int16(max(min(round(real(yk)), 32767), -32768));
        q(2, :) = int16(max(min(round(imag(yk)), 32767), -32768));
        fwrite(fid, q, 'int16');
        clear q
    end
    clear yk
    if nchunks > 1
        fprintf('Chunk %d/%d: %.2f..%.2f s, %d dwells\n', k, nchunks, ...
            o.Start + c0 / fs, o.Start + c1 / fs, nnz(in));
    end
end
if fid > 0, fclose(fid); end

nd = numel(dw.start_s);
assert(nd > 0, 'no LoRa signal found');
if snr_db > min(dw.snr_db) - 2
    warning('lora_iq_set_snr:floor', ...
        'Requested SNR %.1f dB is close to the recording''s own %.1f dB (min over dwells): the result will be lower.', ...
        snr_db, min(dw.snr_db));
end
if clipped
    warning('lora_iq_set_snr:clipped', '%d samples clipped to int16 after the first chunk.', clipped);
end
St = St * gain^2; Nbw = Nbw * gain^2;

info.dwells = dw; info.signal_dbfs = 10*log10(St / fullscale^2);
info.noise_dbfs_in_bw = 10*log10(Nbw / fullscale^2); info.requested_snr_db = snr_db;
info.peak = peak * gain; info.gain_db = 20*log10(gain);
info.chunks = nchunks; info.clipped = clipped;
fprintf('Signal %.1f dBFS, noise in %.0f kHz %.1f dBFS, SNR %.1f dB\n', ...
    info.signal_dbfs, bw/1e3, info.noise_dbfs_in_bw, snr_db);

% ---- read back ------------------------------------------------------------------------
if ~isempty(o.Out)
    fprintf('Written %s (%.2f s, %.0f MB)\n', o.Out, n/fs, n*4/1e6);
    if snr_db >= 8       % lora_iq_snr reads within 0.15 dB from 2 dB above its 6 dB threshold
        chk = lora_iq_snr(o.Out, 'Fs', fs, 'BW', bw, 'Duration', min(n, nc) / fs, 'Plot', false);
        info.measured_snr_db = chk.snr_db;
        fprintf('Read back (first %.1f s): SNR median %.1f dB (requested %.1f)\n', ...
            min(n, nc) / fs, median(chk.snr_db), snr_db);
    else
        fprintf('Read-back skipped: SNR too close to the detector''s 6 dB threshold\n');
    end
end
end

function [pieces, rng_, Sj] = cut_dwells(z, r, fs, bw)
% Every dwell of R band-passed out of Z with a tapered window; its sample range in Z
% and its mean power where the signal is on.
n = numel(z); nd = numel(r.start_s);
margin = round(100e-6 * fs);                       % room for the filter ends
taper  = round(100e-6 * fs);
Sj = zeros(1, nd);
pieces = cell(1, nd); rng_ = zeros(nd, 2);
for j = 1:nd
    a = max(1, round(r.start_s(j) * fs) + 1 - margin);
    b = min(n, round((r.start_s(j) + r.dur_ms(j) * 1e-3) * fs) + margin);
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
    ps = sort(pwf);
    hot = pwf > 0.5 * ps(ceil(0.9 * numel(ps)));   % samples with signal (not the gaps)
    hot(1:tw) = false; hot(end-tw+1:end) = false;
    Sj(j) = mean(pw(hot));
    pieces{j} = s; rng_(j, :) = [a b];
end
end

function n = source_length(file)
% Samples in FILE (int16 I,Q pairs) or in a sample vector.
if isnumeric(file)
    n = numel(file);
else
    d = dir(file); assert(~isempty(d), 'cannot open %s', file);
    n = floor(d.bytes / 4);
end
end

function z = read_samples(file, a, len)
% LEN samples from sample A (0-based) as a single complex column, int16 units.
if isnumeric(file)
    z = single(file(a+1:a+len));
    z = z(:);
else
    fid = fopen(file, 'r'); assert(fid > 0, 'cannot open %s', file);
    fseek(fid, a * 4, 'bof');
    raw = fread(fid, [2, len], 'int16=>single'); fclose(fid);
    z = complex(raw(1, :), raw(2, :)).';
end
end
