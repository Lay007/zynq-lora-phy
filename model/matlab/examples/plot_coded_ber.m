function [resultsCr1, resultsCr4, figureHandle] = plot_coded_ber(outputPath)
%PLOT_CODED_BER Compare coded payload BER and PER for CR 4/5 and 4/8.

rootDirectory = fileparts(fileparts(mfilename("fullpath")));
addpath(rootDirectory);
if nargin < 1
    repositoryRoot = fileparts(fileparts(rootDirectory));
    outputPath = fullfile(repositoryRoot, "docs", "images", ...
        "lora-coded-ber-sf7.png");
end

snrDb = (-20:2:-6).';
configCr1 = lora_phy.phy_config(7, 2, 1);
configCr4 = lora_phy.phy_config(7, 2, 4);
resultsCr1 = lora_phy.simulate_coded_ber(snrDb, configCr1, 100, 16, 19);
resultsCr4 = lora_phy.simulate_coded_ber(snrDb, configCr4, 100, 16, 23);

figureHandle = figure("Color", "white", "Position", [100, 100, 860, 540]);
plot_error_rate(gca, snrDb, resultsCr1.PayloadBER, resultsCr1.PayloadBits, ...
    "o-", "LineWidth", 1.5, "DisplayName", "Payload BER, CR 4/5");
hold on;
plot_error_rate(gca, snrDb, resultsCr4.PayloadBER, resultsCr4.PayloadBits, ...
    "s-", "LineWidth", 1.5, "DisplayName", "Payload BER, CR 4/8");
plot_error_rate(gca, snrDb, resultsCr1.PER, resultsCr1.Packets, ...
    "o--", "LineWidth", 1.3, "DisplayName", "PER, CR 4/5");
plot_error_rate(gca, snrDb, resultsCr4.PER, resultsCr4.Packets, ...
    "s--", "LineWidth", 1.3, "DisplayName", "PER, CR 4/8");
grid on;
xlabel("SNR per complex sample, dB");
ylabel("Error probability");
title("LoRa packet coding in AWGN, SF7, 16-byte payload");
legend("Location", "southwest");
ylim([1e-5, 1.05]);
subtitle("Unconnected triangles: zero errors, 95% Wilson upper bound");

outputDirectory = fileparts(outputPath);
if ~isfolder(outputDirectory)
    mkdir(outputDirectory);
end
exportgraphics(figureHandle, outputPath, "Resolution", 160);
dataDirectory = fullfile(fileparts(outputDirectory), "data");
if ~isfolder(dataDirectory)
    mkdir(dataDirectory);
end
writetable(resultsCr1, fullfile(dataDirectory, "lora-coded-ber-sf7-cr1.csv"));
writetable(resultsCr4, fullfile(dataDirectory, "lora-coded-ber-sf7-cr4.csv"));
end
