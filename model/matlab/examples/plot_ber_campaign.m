function campaign = plot_ber_campaign(outputDirectory, options)
%PLOT_BER_CAMPAIGN Compare CSS demodulators and coded low-SF performance.

arguments
    outputDirectory (1,1) string = ""
    options.UncodedSymbolsPerPoint (1,1) double ...
        {mustBeInteger, mustBePositive} = 4000
    options.CodedPacketsPerPoint (1,1) double ...
        {mustBeInteger, mustBePositive} = 200
    options.PayloadBytes (1,1) double ...
        {mustBeInteger, mustBePositive} = 16
    options.UncodedSnrDb (:,1) double = (-20:2:-4).'
    options.CodedSnrDb (:,1) double = (-20:2:-4).'
end
rootDirectory = fileparts(fileparts(mfilename("fullpath")));
addpath(rootDirectory);
if outputDirectory == ""
    repositoryRoot = fileparts(fileparts(rootDirectory));
    outputDirectory = fullfile(repositoryRoot, "docs");
end
imageDirectory = fullfile(outputDirectory, "images");
dataDirectory = fullfile(outputDirectory, "data");
if ~isfolder(imageDirectory)
    mkdir(imageDirectory);
end
if ~isfolder(dataDirectory)
    mkdir(dataDirectory);
end

uncoded = run_uncoded(options.UncodedSnrDb, ...
    options.UncodedSymbolsPerPoint);
writetable(uncoded, fullfile(dataDirectory, ...
    "css-ber-demodulator-comparison.csv"));

idealGap = summarize_ideal_gap(uncoded, [1e-2; 1e-3]);
writetable(idealGap, fullfile(dataDirectory, "css-ber-ideal-gap.csv"));

coded = run_coded(options.CodedSnrDb, options.CodedPacketsPerPoint, ...
    options.PayloadBytes);
figures = render_ber_campaign(uncoded, coded, idealGap, outputDirectory);
writetable(coded, fullfile(dataDirectory, ...
    "lora-coded-ber-sf5-sf7-fft-correlator.csv"));

settings = struct( ...
    "schema", "zynq-lora-ber-campaign-v3", ...
    "uncodedSymbolsPerPoint", options.UncodedSymbolsPerPoint, ...
    "codedPacketsPerPoint", options.CodedPacketsPerPoint, ...
    "payloadBytes", options.PayloadBytes, ...
    "uncodedSnrDb", options.UncodedSnrDb, ...
    "codedSnrDb", options.CodedSnrDb, ...
    "uncodedSeedBase", 70, ...
    "codedSeedBySf", [105; 106; 107], ...
    "confidenceInterval", "Wilson score, two-sided 95 percent");
save(fullfile(dataDirectory, "ber-demodulator-campaign.mat"), ...
    "uncoded", "coded", "idealGap", "settings");
campaign = struct("uncoded", uncoded, "coded", coded, ...
    "idealGap", idealGap, ...
    "settings", settings, "uncodedFigure", figures.uncodedFigure, ...
    "idealGapFigure", figures.idealGapFigure, "codedFigure", figures.codedFigure);
end

function results = run_uncoded(snrDb, symbolsPerPoint)
rows = cell(0, 1);
samplesPerChipValues = [1, 2, 4, 8];
for samplesPerChip = samplesPerChipValues
    config = lora_phy.css_config(7, samplesPerChip);
    modes = ["single-phase", "polyphase", ...
        "fft-correlator", "matched-filter"];
    for mode = modes
        item = lora_phy.simulate_uncoded_ber( ...
            snrDb, config, symbolsPerPoint, 70+samplesPerChip, mode);
        rows{end+1, 1} = item; %#ok<AGROW>
    end
end
results = vertcat(rows{:});
end

function results = run_coded(snrDb, packetsPerPoint, payloadBytes)
rows = cell(0, 1);
for sf = 5:7
    config = lora_phy.phy_config(sf, 8, 1);
    item = lora_phy.simulate_coded_ber(snrDb, config, ...
        packetsPerPoint, payloadBytes, 100+sf, true, "fft-correlator");
    rows{end+1, 1} = item; %#ok<AGROW>
end
results = vertcat(rows{:});
end

function summary = summarize_ideal_gap(results, targets)
rows = cell(0, 1);
for samplesPerChip = [1, 2, 4, 8]
    current = results(results.SamplesPerChip == samplesPerChip & ...
        results.DemodulationMode == "fft-correlator", :);
    legacy = results(results.SamplesPerChip == samplesPerChip & ...
        results.DemodulationMode == "polyphase", :);
    ideal = results(results.SamplesPerChip == samplesPerChip & ...
        results.DemodulationMode == "matched-filter", :);
    for target = targets(:).'
        legacyThreshold = estimate_threshold(legacy, target);
        currentThreshold = estimate_threshold(current, target);
        idealThreshold = estimate_threshold(ideal, target);
        rows{end+1, 1} = table(samplesPerChip, target, ...
            legacyThreshold, currentThreshold, idealThreshold, ...
            legacyThreshold-idealThreshold, ...
            currentThreshold-idealThreshold, ...
            'VariableNames', {'SamplesPerChip', 'TargetBER', ...
            'LegacyPolyphaseSNR_dB', 'FftCorrelatorSNR_dB', ...
            'MatchedFilterSNR_dB', 'LegacyGap_dB', ...
            'CurrentGap_dB'}); %#ok<AGROW>
    end
end
summary = vertcat(rows{:});
end

function threshold = estimate_threshold(results, target)
[snrDb, order] = sort(results.SNR_dB);
shown = max(results.BER(order), 0.5./results.Bits(order));
crossing = find(shown(1:end-1) >= target & ...
    shown(2:end) <= target, 1, "first");
if isempty(crossing)
    threshold = NaN;
    return
end
x = log10(shown(crossing:crossing+1));
threshold = interp1(x, snrDb(crossing:crossing+1), ...
    log10(target), "linear");
end
