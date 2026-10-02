function [results, figureHandle] = plot_ber_curve(outputPath)
%PLOT_BER_CURVE Simulate and visualize uncoded CSS BER/SER versus sample SNR.

rootDirectory = fileparts(fileparts(mfilename("fullpath")));
addpath(rootDirectory);
if nargin < 1
    repositoryRoot = fileparts(fileparts(rootDirectory));
    outputPath = fullfile( ...
        repositoryRoot, "docs", "images", "css-ber-sf7.png");
end

config = lora_phy.css_config(7, 2);
snrDb = (-20:2:0).';
results = lora_phy.simulate_uncoded_ber(snrDb, config, 4000, 7);

figureHandle = figure("Color", "white", "Position", [100, 100, 820, 520]);
plot_error_rate(gca, results.SNR_dB, results.BER, results.Bits, "o-", ...
    "LineWidth", 1.5, "MarkerSize", 6, "DisplayName", "Uncoded BER");
hold on;
plot_error_rate(gca, results.SNR_dB, results.SER, results.Symbols, "s--", ...
    "LineWidth", 1.5, "MarkerSize", 6, "DisplayName", "SER");
grid on;
xlabel("SNR per complex sample, dB");
ylabel("Error probability");
title(sprintf("CSS Monte Carlo, SF%d, %d samples/chip", ...
    config.spreadingFactor, config.samplesPerChip));
legend("Location", "southwest");
ylim([1e-5, 1.05]);
subtitle("Unconnected triangles: zero errors, 95% Wilson upper bound");

outputDirectory = fileparts(outputPath);
if ~isfolder(outputDirectory)
    mkdir(outputDirectory);
end
exportgraphics(figureHandle, outputPath, "Resolution", 160);

[imageDirectory, baseName] = fileparts(outputPath);
dataDirectory = fullfile(fileparts(imageDirectory), "data");
if ~isfolder(dataDirectory)
    mkdir(dataDirectory);
end
writetable(results, fullfile(dataDirectory, baseName + ".csv"));
end
