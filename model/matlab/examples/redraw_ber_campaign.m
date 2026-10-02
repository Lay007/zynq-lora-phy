function figures = redraw_ber_campaign(outputDirectory, dataDirectory)
%REDRAW_BER_CAMPAIGN Regenerate figures from saved counts without simulation.
% Only images are written; the CSV/MAT evidence and seeds remain unchanged.
arguments
    outputDirectory (1,1) string = ""
    dataDirectory (1,1) string = ""
end
rootDirectory = fileparts(fileparts(mfilename("fullpath")));
addpath(rootDirectory);
repositoryRoot = fileparts(fileparts(rootDirectory));
if outputDirectory == ""
    outputDirectory = fullfile(repositoryRoot, "docs");
end
if dataDirectory == ""
    dataDirectory = fullfile(repositoryRoot, "docs", "data");
end
uncoded = readtable(fullfile(dataDirectory, ...
    "css-ber-demodulator-comparison.csv"), "TextType", "string");
coded = readtable(fullfile(dataDirectory, ...
    "lora-coded-ber-sf5-sf7-fft-correlator.csv"), "TextType", "string");
idealGap = readtable(fullfile(dataDirectory, "css-ber-ideal-gap.csv"));
figures = render_ber_campaign(uncoded, coded, idealGap, outputDirectory);
end
