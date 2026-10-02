function figures = render_ber_campaign(uncoded, coded, idealGap, outputDirectory)
%RENDER_BER_CAMPAIGN Draw observed rates without artificial zero-error tails.
arguments
    uncoded table
    coded table
    idealGap table
    outputDirectory (1,1) string
end
imageDirectory = fullfile(outputDirectory, "images");
if ~isfolder(imageDirectory)
    mkdir(imageDirectory);
end
figures = struct;
figures.uncodedFigure = plot_uncoded_current_vs_ideal(uncoded);
exportgraphics(figures.uncodedFigure, fullfile(imageDirectory, ...
    "css-ber-current-vs-ideal.png"), "Resolution", 180);
figures.idealGapFigure = plot_ideal_gap(idealGap);
exportgraphics(figures.idealGapFigure, fullfile(imageDirectory, ...
    "css-ber-ideal-gap.png"), "Resolution", 180);
figures.codedFigure = plot_coded(coded);
exportgraphics(figures.codedFigure, fullfile(imageDirectory, ...
    "lora-coded-ber-sf5-sf7-fft-correlator.png"), "Resolution", 180);
end

function figureHandle = plot_uncoded_current_vs_ideal(results)
figureHandle = figure("Color", "white", "Position", [80, 80, 1180, 820]);
layout = tiledlayout(2, 2, "TileSpacing", "compact", ...
    "Padding", "compact");
colors = lines(4);
markers = ["o", "s", "d", "^"];
styles = ["--", ":", "-", "-."];
legendHandles = gobjects(0);
legendLabels = ["Legacy single phase", "Legacy polyphase power sum", ...
    "FFT correlator", "Exact matched filter"];
samplesPerChipValues = [1, 2, 4, 8];
modes = ["single-phase", "polyphase", ...
    "fft-correlator", "matched-filter"];
for panel = 1:4
    axesHandle = nexttile(layout);
    hold(axesHandle, "on");
    samplesPerChip = samplesPerChipValues(panel);
    for index = 1:4
        selected = results.SamplesPerChip == samplesPerChip & ...
            results.DemodulationMode == modes(index);
        subset = results(selected, :);
        lineHandle = plot_error_rate(axesHandle, subset.SNR_dB, ...
            subset.BER, subset.Bits, ...
            styles(index)+markers(index), "Color", colors(index, :), ...
            "LineWidth", 1.35, "MarkerSize", 5);
        if panel == 1
            legendHandles(end+1) = lineHandle; %#ok<AGROW>
        end
    end
    grid(axesHandle, "on");
    set(axesHandle, "YScale", "log");
    xlabel(axesHandle, "SNR per complex sample, dB");
    ylabel(axesHandle, "BER");
    title(axesHandle, sprintf("SF7, L=%d", samplesPerChip));
    ylim(axesHandle, [1e-5, 1.05]);
end
legendHandle = legend(legendHandles, legendLabels, ...
    "Orientation", "horizontal", "NumColumns", 4);
legendHandle.Layout.Tile = "south";
title(layout, "Current CSS demodulator versus coherent reference");
subtitle(layout, "Unconnected triangles: zero errors, 95% Wilson upper bound");
end

function figureHandle = plot_ideal_gap(results)
figureHandle = figure("Color", "white", "Position", [80, 80, 780, 500]);
axesHandle = axes(figureHandle);
hold(axesHandle, "on");
targets = unique(results.TargetBER, "stable");
colors = lines(numel(targets));
markers = ["o", "s"];
legendHandles = gobjects(0);
legendLabels = strings(0);
for index = 1:numel(targets)
    subset = results(results.TargetBER == targets(index), :);
    legendHandles(end+1) = plot(axesHandle, ...
        subset.SamplesPerChip, subset.LegacyGap_dB, ...
        "-"+markers(index), "Color", colors(index, :), ...
        "LineWidth", 1.5, "MarkerSize", 6); %#ok<AGROW>
    legendLabels(end+1) = sprintf("Legacy, BER = %g", ...
        targets(index)); %#ok<AGROW>
    legendHandles(end+1) = plot(axesHandle, ...
        subset.SamplesPerChip, subset.CurrentGap_dB, ...
        "--"+markers(index), "Color", colors(index, :), ...
        "LineWidth", 1.5, "MarkerSize", 6); %#ok<AGROW>
    legendLabels(end+1) = sprintf("FFT correlator, BER = %g", ...
        targets(index)); %#ok<AGROW>
end
grid(axesHandle, "on");
xticks(axesHandle, [1, 2, 4, 8]);
xlabel(axesHandle, "Samples per chip, L");
ylabel(axesHandle, "Penalty to matched filter, dB");
title(axesHandle, "Measured loss from the coherent CSS reference");
legend(legendHandles, legendLabels, "Location", "northwest");
end

function figureHandle = plot_coded(results)
figureHandle = figure("Color", "white", "Position", [80, 80, 1280, 540]);
layout = tiledlayout(1, 3, "TileSpacing", "compact", ...
    "Padding", "compact");
legendHandles = gobjects(0);
legendLabels = ["Pre-FEC BER", "Hard PER", "Soft PER", ...
    "Soft payload BER"];
colors = lines(4);
for sf = 5:7
    axesHandle = nexttile(layout);
    subset = results(results.SpreadingFactor == sf, :);
    hold(axesHandle, "on");
    values = {subset.PreFecBER, subset.HardPER, subset.SoftPER, ...
        subset.SoftPayloadBER};
    trials = {subset.PreFecBits, subset.Packets, subset.Packets, ...
        subset.PayloadBits};
    styles = ["o-", "s--", "^-", "d:"];
    for metric = 1:4
        handle = plot_error_rate(axesHandle, subset.SNR_dB, ...
            values{metric}, trials{metric}, ...
            styles(metric), "Color", colors(metric, :), ...
            "LineWidth", 1.4, "MarkerSize", 5);
        if sf == 5
            legendHandles(end+1) = handle; %#ok<AGROW>
        end
    end
    grid(axesHandle, "on");
    set(axesHandle, "YScale", "log");
    xlabel(axesHandle, "SNR per complex sample, dB");
    ylabel(axesHandle, "Error probability");
    title(axesHandle, sprintf("SF%d, L=8, CR 4/5", sf));
    ylim(axesHandle, [1e-5, 1.05]);
end
legendHandle = legend(legendHandles, legendLabels, ...
    "Orientation", "horizontal", "NumColumns", 4);
legendHandle.Layout.Tile = "south";
title(layout, "Coded LoRa packet performance, 16-byte payload");
subtitle(layout, "Unconnected triangles: zero errors, 95% Wilson upper bound");
end
