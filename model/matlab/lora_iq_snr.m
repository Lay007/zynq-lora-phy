function r = lora_iq_snr(file, varargin)
%LORA_IQ_SNR Find LoRa signal in an int16 IQ recording (frequency hopping allowed) and estimate SNR.
%   R = LORA_IQ_SNR(FILE) reads the first second of FILE (interleaved int16 I,Q;
%   FILE can also be a complex vector of samples in int16 units),
%   finds the LoRa signal in every time frame, groups the frames into dwells on one
%   channel and returns the SNR in the LoRa bandwidth for each dwell.
%
%   Options (name, value):
%     'Fs'        sample rate, Hz                          (40e6)
%     'BW'        LoRa bandwidth, Hz                       (500e3)
%     'Start'     first second to read                     (0)
%     'Duration'  seconds to read                          (1)
%     'Nfft'      STFT frame length, samples               (2048)
%     'MinSnr'    detection threshold over the noise, dB   (6)
%     'MaxGap'    gap inside a dwell that does not split it, s   (5e-3)
%     'Plot'      draw the figure                          (true)
%
%   Method.
%   1. STFT with a Hann window, scaled so that the bins add up to the mean-square
%      of the samples (Parseval).
%   2. In every frame the BW-wide window with the largest power is the channel.
%   3. Noise: the receiver noise is white over the passband, so the per-bin noise
%      power is first the median of the passband bins of all frames, leaving out each
%      frame's channel window and half a window on either side, divided by ln 2
%      (median of an exponential variable). If at least 5 % of the frames have no
%      signal (SNR below 3 dB, e.g. pauses between packets), the noise is then the
%      plain mean of those frames' bins: this needs no distribution assumption and is
%      not raised by the splatter of symbol and packet edges in signal frames.
%      Bins outside the flat passband are excluded by 'Passband' (default +-12 MHz).
%      The channel power P gives SNR = (P - N) / N with N = noise per bin x bins in
%      the window. The frame holds a signal if that SNR is above 'MinSnr'.
%   4. A signal frame joins the open dwell (last frame less than 'MaxGap' before it)
%      whose mean channel centre is within 0.75 BW, the longest if several, else it
%      opens a new dwell. A frame shows only the part of the chirp swept during it, so
%      its channel estimate wanders by up to ~BW/2 at low SNR; joining the longest
%      dwell keeps such a frame (or a stray noise frame) from splitting the dwell. Dwells with less than
%      1 ms of signal frames are dropped. A dwell's SNR is the mean power over its
%      signal frames, in dB.
%
%   Accuracy, checked on synthetic recordings (lora_iq_synth, tests/TestIqSnr.m):
%   within 0.15 dB from MinSnr + 2 dB up to 40 dB (slightly low at high SNR: the
%   window misses the chirp's spectral skirts). Nearer the threshold the frames that
%   fall below it are not counted and the SNR reads high (+0.2 dB at MinSnr + 1 dB,
%   +0.7 dB at MinSnr). With noise alone the largest window stays ~2 dB above the
%   mean, so MinSnr = 6 dB gives no false dwells.
%
%   The SNR is in-band, before dechirping; the LoRa processing gain 2^SF comes on
%   top. Levels are dB re the int16 full scale (a complex tone with I and Q both at
%   full scale reads +3 dBFS).
%
%   Example:
%     r = lora_iq_snr('IQREC-03-07-26-10h33m43s888.iq');

p = inputParser;
addParameter(p, 'Fs', 40e6);
addParameter(p, 'BW', 500e3);
addParameter(p, 'Start', 0);
addParameter(p, 'Duration', 1);
addParameter(p, 'Nfft', 2048);
addParameter(p, 'MinSnr', 6);
addParameter(p, 'MaxGap', 5e-3);
addParameter(p, 'Passband', 12e6);
addParameter(p, 'Plot', true);
parse(p, varargin{:});
o = p.Results;
fs = o.Fs; bw = o.BW; nfft = o.Nfft;
fullscale = 32768;

% ---- read -----------------------------------------------------------------
n0 = round(o.Start * fs);
n  = floor(o.Duration * fs / nfft) * nfft;
if isnumeric(file)                                % samples given directly (int16 units)
    z = single(file(n0+1:min(end, n0+n)));
    z = reshape(z, 1, []);
    n = floor(numel(z) / nfft) * nfft;
    z = z(1:n);
else
    fid = fopen(file, 'r');
    assert(fid > 0, 'cannot open %s', file);
    fseek(fid, n0 * 4, 'bof');
    raw = fread(fid, [2, n], 'int16=>single');
    fclose(fid);
    n = floor(size(raw, 2) / nfft) * nfft;
    z = complex(raw(1, 1:n), raw(2, 1:n)); clear raw
end
nfr = n / nfft;
tf = nfft / fs;                                   % frame duration

% ---- STFT: mean-square per bin ------------------------------------------------
w = single(0.5 - 0.5 * cos(2 * pi * (0:nfft-1)' / nfft));   % periodic Hann, no toolbox
w = w / sqrt(mean(w.^2));
P = zeros(nfft, nfr, 'single');
blk = 2048;
for a = 1:blk:nfr
    b = min(a + blk - 1, nfr);
    X = reshape(z(((a-1)*nfft+1):(b*nfft)), nfft, []);
    P(:, a:b) = abs(fft(X .* w, [], 1)).^2 / nfft^2;
end
clear z
P = fftshift(P, 1);
f = ((0:nfft-1) - nfft/2)' * fs / nfft;
df = fs / nfft;
nb = max(1, round(bw / df));                       % bins in the channel

% ---- channel in every frame: the BW-wide window with the largest power ------------
inband = abs(f) <= o.Passband;
c = [zeros(1, nfr, 'single'); cumsum(P .* inband, 1)];
win = c(nb+1:end, :) - c(1:end-nb, :);             % window starting at bin k
clear c
[pmax, k] = max(win, [], 1);
clear win
fc = f(k)' + (nb/2 - 0.5) * df;                    % window centre, Hz
pmax = double(pmax);

% ---- noise per bin: median of the passband with each frame's channel window
% (and half a window either side, for leakage) left out -------------------------------
Pin = P;
rows = (-ceil(nb/2):nb + ceil(nb/2) - 1)';
rr = min(max(k + rows, 1), nfft);
Pin(sub2ind(size(P), rr, repmat(1:nfr, numel(rows), 1))) = NaN;
Pin = Pin(inband, :);
Nbin = double(median(Pin(:), 'omitnan')) / log(2);
Nwin = Nbin * nb;                                  % noise power in one channel window
% refine on the frames without signal, if the recording has enough of them (pauses
% between packets): there the mean needs no assumption about the noise distribution
% and no frame is spoilt by the spectral splatter of symbol and packet edges
snr_f = 10*log10(max(pmax - Nwin, eps) / Nwin);
quiet = snr_f < 3;
if nnz(quiet) >= max(20, 0.05 * nfr)
    Pq = P(inband, quiet);                         % no signal there: every bin counts
    Nbin = double(mean(Pq(:)));
    Nwin = Nbin * nb;
    clear Pq
end
clear Pin

snr_f = 10*log10(max(pmax - Nwin, eps) / Nwin);    % per-frame SNR
on = snr_f > o.MinSnr;

% ---- dwells: consecutive signal frames on one channel --------------------------------
idx = find(on);
maxgap = round(o.MaxGap / tf);
I0 = zeros(1, 0); I1 = I0; S = I0; N = I0;        % per dwell: first/last frame, sum and count of fc
lab = zeros(1, nfr);                               % dwell of each signal frame
for i = idx
    % join the open dwell (last frame less than MaxGap ago) on this channel; a stray
    % noise frame on another frequency opens its own dwell and cuts nothing
    c = find(I1 >= i - maxgap & abs(fc(i) - S ./ max(N, 1)) < 0.75*bw);
    if isempty(c)
        I0(end+1) = i; I1(end+1) = i; S(end+1) = fc(i); N(end+1) = 1; %#ok<AGROW>
        lab(i) = numel(I0);
    else
        [~, q] = max(N(c)); m = c(q);              % the longest: a stray dwell cannot grow
        I1(m) = i; S(m) = S(m) + fc(i); N(m) = N(m) + 1; lab(i) = m;
    end
end
dw = struct('i0', num2cell(I0), 'i1', num2cell(I1), 'n', num2cell(N));
for m = 1:numel(dw), dw(m).fr = find(lab == m); end
keep = [dw.n] >= round(1e-3 / tf);   % at least 1 ms of signal
dw = dw(keep);
nd = numel(dw);
r.fs = fs; r.bw_hz = bw;
r.noise_dbfs_per_bin = 10*log10(Nbin / fullscale^2);
r.noise_dbfs_in_bw   = 10*log10(Nwin / fullscale^2);
r.start_s = zeros(1, nd); r.dur_ms = zeros(1, nd); r.fc_hz = zeros(1, nd);
r.snr_db = zeros(1, nd); r.sig_dbfs = zeros(1, nd); r.duty = zeros(1, nd);
for j = 1:nd
    ii = dw(j).i0:dw(j).i1; s = dw(j).fr;
    r.start_s(j) = o.Start + (dw(j).i0 - 1) * tf;
    r.dur_ms(j)  = numel(ii) * tf * 1e3;
    r.fc_hz(j)   = median(fc(s));
    ps = mean(pmax(s)) - Nwin;                      % signal power, noise removed
    r.snr_db(j)  = 10*log10(ps / Nwin);
    r.sig_dbfs(j) = 10*log10(ps / fullscale^2);
    r.duty(j)    = numel(s) / numel(ii);            % share of frames with signal (gaps inside a dwell)
end

fprintf('Noise: %.1f dBFS per %.1f kHz bin, %.1f dBFS in %.0f kHz\n', ...
    r.noise_dbfs_per_bin, df/1e3, r.noise_dbfs_in_bw, bw/1e3);
fprintf('Dwells found: %d in %.2f s (frame %.0f us)\n', nd, size(P,2)*tf, tf*1e6);
if nd
    fprintf('SNR in %.0f kHz: median %.1f dB, min %.1f, max %.1f; signal %.1f dBFS (median)\n', ...
        bw/1e3, median(r.snr_db), min(r.snr_db), max(r.snr_db), median(r.sig_dbfs));
    fprintf('Dwell: median %.1f ms, signal in %.0f %% of its frames; channels %.2f..%.2f MHz\n', ...
        median(r.dur_ms), 100*median(r.duty), min(r.fc_hz)/1e6, max(r.fc_hz)/1e6);
    fprintf('  %8s %8s %9s %8s\n', 'start,s', 'dur,ms', 'fc,MHz', 'SNR,dB');
    for j = 1:min(nd, 12)
        fprintf('  %8.4f %8.2f %9.3f %8.1f\n', r.start_s(j), r.dur_ms(j), r.fc_hz(j)/1e6, r.snr_db(j));
    end
end

% ---- plot -------------------------------------------------------------------------
if o.Plot
    t = o.Start + (0:nfr-1) * tf;
    figure('Name', 'LoRa IQ SNR', 'Color', 'w');
    subplot(3,1,1);
    ns = min(nfr, round(0.2 / tf));
    imagesc(t(1:ns), f/1e6, 10*log10(double(P(:, 1:ns)) / fullscale^2 + eps)); axis xy; colorbar;
    xlabel('t, s'); ylabel('f, MHz'); title('Spectrogram, dBFS per bin (first 0.2 s)');
    subplot(3,1,2);
    plot(t, fc/1e6, '.', 'Color', [.75 .75 .75]); hold on;
    plot(t(on), fc(on)/1e6, '.', 'MarkerSize', 4); grid on;
    xlabel('t, s'); ylabel('channel centre, MHz'); title('Channel found in each frame (signal frames in blue)');
    subplot(3,1,3);
    plot(t, snr_f, 'Color', [.75 .75 .75]); hold on;
    plot(r.start_s + r.dur_ms/2e3, r.snr_db, 'o', 'MarkerFaceColor', [0 .4 .8]); grid on;
    yline(o.MinSnr, 'r--', 'threshold');
    xlabel('t, s'); ylabel('SNR, dB'); title(sprintf('SNR in %.0f kHz: per frame and per dwell', bw/1e3));
end
end
