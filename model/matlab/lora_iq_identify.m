function id = lora_iq_identify(source, varargin)
%LORA_IQ_IDENTIFY Identify the LoRa parameters of a signal in an IQ recording.
%   ID = LORA_IQ_IDENTIFY(FILE) takes one dwell found by LORA_IQ_SNR in the
%   first 0.1 s of FILE (int16 I,Q), moves it to zero frequency, decimates it
%   and measures bandwidth, spreading factor, preamble length, sync word,
%   header mode, payload size candidates and packet timing.
%   SOURCE can also be a complex vector of samples (then 'Fs' must be given).
%
%   Options (name, value):
%     'Fs'        sample rate, Hz                                (40e6)
%     'Start'     first second searched                          (0)
%     'Duration'  seconds searched for dwells                    (0.1)
%     'Dwell'     dwell index in that window; [] = the longest   ([])
%     'OutFs'     sample rate after decimation, Hz; Fs/OutFs must be an
%                 integer and OutFs/BW too                       (4e6)
%     'Bandwidths' standard bandwidths to choose from, Hz   ([62.5e3 125e3 250e3 500e3])
%
%   Steps.
%   1. Bandwidth: the -3 dB width of the dwell's smoothed spectrum, snapped to
%      the nearest standard value (a chirp's spectrum is flat over BW).
%   2. SF: dechirp with the reference upchirp for every SF and keep the one that
%      concentrates the energy in one bin (lora_phy.inspect_iq_capture). Two
%      modes with the same chirp rate BW^2/2^SF (e.g. SF7/500 kHz and SF5/250 kHz)
%      are told apart by step 1.
%   3. Packets: bursts in the dwell's envelope. On a symbol grid with an arbitrary
%      start the preamble upchirps dechirp to one bin, cfo - lag, and the SFD
%      downchirps to cfo + lag; the two give the lag and the CFO (the half-symbol
%      ambiguity goes to the smaller CFO). On the corrected grid the two symbols
%      before the SFD give the sync word, the upchirps on the preamble bin before
%      them the preamble length, and the symbols with energy after the 2.25-symbol
%      SFD the payload length. Nothing assumes a sync word or a preamble length.
%   4. Header: an explicit header is tried first (its checksum validates it). If it
%      fails, the header is implicit and the payload symbol count limits payload
%      length, coding rate and CRC to the combinations listed in ID.implicit; those
%      with CRC are tried by decoding (a valid CRC confirms one).

p = inputParser;
addParameter(p, 'Fs', 40e6);
addParameter(p, 'Start', 0);
addParameter(p, 'Duration', 0.1);
addParameter(p, 'Dwell', []);
addParameter(p, 'OutFs', 4e6);
addParameter(p, 'Bandwidths', [62.5e3 125e3 250e3 500e3]);
parse(p, varargin{:});
o = p.Results;
fs = o.Fs; D = fs / o.OutFs;
assert(abs(D - round(D)) < 1e-9, 'Fs/OutFs must be an integer');
D = round(D); fsd = fs / D;

% ---- 1. the dwell ------------------------------------------------------------------------
r = lora_iq_snr(source, 'Fs', fs, 'Start', o.Start, 'Duration', o.Duration, 'Plot', false);
assert(~isempty(r.start_s), 'no LoRa signal found');
j = o.Dwell;
if isempty(j), [~, j] = max(r.dur_ms); end
margin = 0.5e-3;
t0 = max(o.Start, r.start_s(j) - margin);
z = read_samples(source, fs, t0, r.dur_ms(j) * 1e-3 + 2 * margin);
n = numel(z);
F = fft(z);
fr = (0:n-1)' / n; fr(fr >= 0.5) = fr(fr >= 0.5) - 1; fr = fr * fs;

% centre and occupied bandwidth from the smoothed spectrum near the dwell
near = abs(fr - r.fc_hz(j)) < 1.5e6;
[fn, order] = sort(fr(near)); pn = abs(F(near)).^2; pn = pn(order);
ps = movmean(pn, max(3, round(5e3 / (fs / n))));   % 5 kHz smoothing
noise = median(ps);
top = median(ps(abs(fn - r.fc_hz(j)) < 100e3));
occ = fn(ps - noise > (top - noise) / 2);
fc = (min(occ) + max(occ)) / 2;
occupied = max(occ) - min(occ);
[~, k] = min(abs(o.Bandwidths - occupied));
bw = o.Bandwidths(k);
spc = fsd / bw;
assert(abs(spc - round(spc)) < 1e-9, 'OutFs/BW must be an integer');
spc = round(spc);

% to zero frequency, keep one bandwidth (+10 %: the chirp's skirts), decimate
F(abs(fr - fc) > 0.55 * bw) = 0;
y = ifft(F) .* exp(-2j * pi * fc * (0:n-1)' / fs);
y = y(1:D:end);

% ---- 2. spreading factor ------------------------------------------------------------------
ins = lora_phy.inspect_iq_capture(y, fsd, CandidateBandwidthHz = bw);
sf = ins.estimatedSpreadingFactor;
ts = 2^sf / bw;
L = 2^sf * spc;                                    % samples per symbol

% ---- 3. packets in the dwell ---------------------------------------------------------------
env = movmean(abs(y).^2, L);
es = sort(env);
act = env > es(ceil(0.9 * numel(es))) / 4;                  % 6 dB under the packets' level: works
                                                   % whether the dwell is mostly signal or not
d = diff([false; act; false]);
bs = find(d == 1); be = find(d == -1) - 1;
ok = (be - bs) > 8 * L;                            % at least 8 symbols
bs = bs(ok); be = be(ok);

up = lora_phy.reference_chirp(lora_phy.css_config(sf, spc), "up");
dn = conj(up);
N = 2^sf;
pk = struct('start_s', {}, 'preamble', {}, 'sync_word', {}, 'payload_symbols', {}, ...
    'header', {}, 'cfo_hz', {}, 'seg', {});
dec = [];
for b = 1:numel(bs)
    a0 = max(1, bs(b) - 2 * L); a1 = min(numel(y), be(b) + 2 * L);
    seg = y(a0:a1);
    % Symbol grid. Its start is arbitrary at first: on any grid the preamble upchirps
    % dechirp to one bin bp = cfo - d and the SFD downchirps to bd = cfo + d (bins),
    % d being the grid's lag behind the symbols. So d = (bd - bp)/2, up to half a
    % symbol, which the smaller |cfo| resolves.
    g = grid_bins(seg, 1, L, up, dn, spc);
    [ksfd, bp] = find_sfd(g);
    if isnan(ksfd), continue; end
    bd = g.bd(ksfd);
    best = [];
    for h = [0 N/2]
        dd = wrap((bd - bp) / 2 + h, N);           % lag, bins
        cf = wrap(bp + dd, N);                     % cfo, bins
        if isempty(best) || abs(cf) < abs(best(2)), best = [dd cf]; end
    end
    shift = round(best(1) * spc);
    g = grid_bins(seg, 1 + mod(shift, L), L, up, dn, spc);
    [ksfd, bp] = find_sfd(g);
    if isnan(ksfd) || ksfd < 3, continue; end
    cthr = 0.3 * median(g.cu(max(1, ksfd - 5):ksfd - 3));
    % sync word: the two symbols before the SFD, relative to the preamble
    nib = mod(round(wrap(g.bu(ksfd - [2 1]) - bp, N) / 8), 16);
    sw = 16 * nib(1) + nib(2);
    % preamble: upchirps on bin bp before the sync word
    np = 0; k = ksfd - 3;
    while k >= 1 && g.cu(k) > cthr && abs(wrap(g.bu(k) - bp, N)) <= 1
        np = np + 1; k = k - 1;
    end
    % payload: symbols after the 2.25-symbol SFD, counted by power (the envelope is
    % constant over a packet, the dechirped peak of data symbols is not)
    ps0 = g.start(ksfd) + round(2.25 * L);
    pthr = 0.5 * median(g.pw(max(1, ksfd - 5):ksfd - 3));
    m = 0; s1 = ps0;
    while s1 + L - 1 <= numel(seg) && mean(abs(seg(s1:s1+L-1)).^2) > pthr
        m = m + 1; s1 = s1 + L;
    end
    % explicit header? (its checksum validates it)
    hdr = "implicit";
    try
        q = lora_phy.receive_lora_packet(seg, fsd, bw, sf, PreambleSymbols = min(np, 6), SyncWord = sw);
        if q.success, hdr = "explicit"; dec = q.decoded; end
    catch
    end
    i = numel(pk) + 1;
    pk(i).start_s = t0 + (a0 - 1 + g.start(ksfd - 2 - np) - 1) / fsd;
    pk(i).preamble = np;
    pk(i).sync_word = sw;
    pk(i).payload_symbols = m;
    pk(i).header = hdr;
    pk(i).cfo_hz = best(2) * bw / N;                % +-0.5 bin
    pk(i).seg = seg;
end
assert(~isempty(pk), 'no packet with a preamble, sync word and SFD found');

% ---- 4. implicit header: payload candidates -------------------------------------------------
m = mode([pk.payload_symbols]);
cand = zeros(0, 3);
de = sf >= 11 && bw <= 125e3;                      % low data rate optimisation is on by rule
for crc = [false true]
    for cr = 1:4
        for pl = 1:64
            nsym = 8 + max(ceil((8*pl - 4*sf + 28 + 16*crc - 20) / (4*(sf - 2*de))) * (cr + 4), 0);
            if nsym == m, cand(end+1, :) = [pl cr crc]; end %#ok<AGROW>
        end
    end
end
confirmed = zeros(0, 3);
if all([pk.header] == "implicit")
    q1 = pk(1);
    for c = cand(cand(:, 3) == 1, :).'
        try
            qq = lora_phy.receive_lora_packet(q1.seg, fsd, bw, sf, PreambleSymbols = min(q1.preamble, 6), ...
                SyncWord = q1.sync_word, ExplicitHeader = false, PayloadLength = c(1), ...
                CodingRate = c(2), PayloadCrc = true);
            if qq.success, confirmed(end+1, :) = c.'; dec = qq.decoded; end %#ok<AGROW>
        catch
        end
    end
end

% ---- result -----------------------------------------------------------------------------------
id.fc_hz = fc; id.occupied_bw_hz = occupied; id.bw_hz = bw; id.sf = sf;
id.symbol_us = ts * 1e6; id.sf_scores = ins.spreadingFactorScores;
id.preamble = mode([pk.preamble]); id.sync_word = mode([pk.sync_word]);
id.header = pk(1).header; id.payload_symbols = m;
id.implicit = array2table(cand, 'VariableNames', {'payload_bytes', 'cr', 'crc'});
id.implicit.cr = "4/" + string(4 + id.implicit.cr);
id.confirmed = confirmed; id.decoded = dec;
starts = [pk.start_s];
id.packet_start_s = starts;
id.airtime_ms = (id.preamble + 4.25 + m) * ts * 1e3;
% period: the packets in the dwell (a missed packet shows as a double step, so keep
% the steps close to the shortest), else the spacing of the hops
st = diff(starts);
id.period_ms = NaN; id.period_from = "";
if ~isempty(st)
    id.period_ms = median(st(st < 1.5 * min(st))) * 1e3;
    id.period_from = "packets in the dwell";
elseif numel(r.start_s) >= 2
    id.period_ms = median(diff(r.start_s)) * 1e3;
    id.period_from = "dwell spacing, one packet per hop";
end
id.packets = rmfield(pk, 'seg');
id.cfo_hz = median([pk.cfo_hz]);
id.dwell = j; id.dwell_snr_db = r.snr_db(j);

fprintf('Dwell %d at %.4f s, %.1f ms, centre %.4f MHz, SNR %.1f dB\n', j, r.start_s(j), r.dur_ms(j), fc/1e6, r.snr_db(j));
fprintf('Bandwidth %.1f kHz (occupied -3 dB: %.0f kHz), SF %d, symbol %.0f us\n', bw/1e3, occupied/1e3, sf, ts*1e6);
fprintf('Packets: %d, period %.2f ms (%s), airtime %.2f ms, CFO from the dwell centre %.1f kHz\n', ...
    numel(pk), id.period_ms, id.period_from, id.airtime_ms, id.cfo_hz/1e3);
fprintf('Preamble %d upchirps (packets: %s), sync word 0x%02X, header %s, %d payload symbols\n', ...
    id.preamble, mat2str([pk.preamble]), id.sync_word, id.header, m);
if id.header == "implicit"
    fprintf('Implicit-header combinations giving %d symbols:\n', m);
    for c = cand.'
        fprintf('   %2d bytes, CR 4/%d, CRC %s\n', c(1), c(2) + 4, string(logical(c(3))));
    end
    if isempty(confirmed)
        fprintf('No combination with CRC decodes with a valid CRC: CRC off (or not standard LoRa payload).\n');
    else
        fprintf('Confirmed by CRC: %s\n', mat2str(confirmed));
    end
end
end

function z = read_samples(source, fs, t0, dur)
n0 = round(t0 * fs); n = round(dur * fs);
if isnumeric(source)
    z = double(source(n0+1:min(end, n0+n)));
    z = z(:);
else
    fid = fopen(source, 'r'); assert(fid > 0, 'cannot open %s', source);
    fseek(fid, n0 * 4, 'bof');
    raw = fread(fid, [2, n], 'int16=>double'); fclose(fid);
    z = complex(raw(1, :), raw(2, :)).';
end
end

function [k, c] = symbol_bin(x, s, L, up, spc)
% Dechirped peak of the symbol starting at sample s: bin (0..2^SF-1) and its share of the energy.
if s < 1 || s + L - 1 > numel(x), k = NaN; c = 0; return; end
v = fft(x(s:s+L-1) .* conj(up));
N = L / spc;
pw = abs(v).^2;
pw = pw(1:N) + pw(end-N+1:end);                    % fold: a symbol's tone lands in either half
[mx, k] = max(pw); k = k - 1;
c = mx / sum(abs(v).^2);
end

function g = grid_bins(x, s0, L, up, dn, spc)
% Up- and down-dechirped peaks of every symbol window on the grid starting at s0.
g.start = s0:L:numel(x) - L + 1;
n = numel(g.start);
g.bu = zeros(1, n); g.cu = g.bu; g.bd = g.bu; g.cd = g.bu; g.pw = g.bu;
for k = 1:n
    [g.bu(k), g.cu(k)] = symbol_bin(x, g.start(k), L, up, spc);
    [g.bd(k), g.cd(k)] = symbol_bin(x, g.start(k), L, dn, spc);
    g.pw(k) = mean(abs(x(g.start(k):g.start(k)+L-1)).^2);
end
end

function [ksfd, bp] = find_sfd(g)
% First window of the SFD: two downchirp windows in a row after at least four
% upchirp windows on one bin; bp is that preamble bin.
ksfd = NaN; bp = NaN;
N = numel(g.bu);
% the scale is the preamble's peak share (median of the best upchirp windows); a
% misaligned grid splits an SFD window between two symbols, so 0.3 of it
cref = median(maxk(g.cu, 6));
for k = 5:N - 1
    if g.cd(k) > 0.3 * cref && g.cd(k+1) > 0.3 * cref && g.cd(k) > 2 * g.cu(k)
        pre = g.bu(k-4:k-3);                       % before the two sync symbols
        if all(g.cu(k-4:k-3) > 0.5 * cref) && pre(1) == pre(2)
            ksfd = k; bp = pre(1); return;
        end
    end
end
end

function v = wrap(v, N)
% Circular difference in bins, in [-N/2, N/2).
v = mod(v + N/2, N) - N/2;
end
