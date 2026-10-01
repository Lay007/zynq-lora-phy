function report = run_synthesis(options)
%RUN_SYNTHESIS Out-of-context Vivado synthesis of the generated DUTs.
%
% The first numbers in this project that describe silicon rather than
% inferred operators. Everything published before this was HDL Coder's
% count of operators in the generated code, which does not translate into
% LUT/FF/DSP/BRAM and was always labelled as such.
%
%   report = run_synthesis;
%   report = run_synthesis(Part="xc7z010clg225-1");
%
% Out-of-context on purpose. There is no board wrapper, no clocking, and no
% AXI, so anything else would measure parts of the design that do not exist
% yet. These numbers describe the DUTs alone and will move once wrapped.
%
% Fmax is derived, not requested: synthesis runs against a probe period and
% Fmax = 1/(probe - WNS). A negative slack against an aggressive probe is
% still a valid measurement of what the design achieves.
%
% RUN_HDL_GENERATION now gives every target a unique ModulePrefix so the
% generated cores can coexist in one Vivado project. The Tcl layer prefers
% that namespaced top but falls back to historical module DUT, keeping the
% already-committed synthesis evidence reproducible before regeneration.

arguments
    % ZC702, taken from the ADI reference scripts rather than from memory:
    % adi_project_xilinx.tcl maps _zc702 to xc7z020clg484-1. The board runs
    % Pluto firmware, which is why the capture documentation calls it a
    % Pluto-compatible ZynqSDR -- that describes the software interface, not
    % the silicon.
    options.Part (1,1) string = "xc7z020clg484-1"
    options.ProbePeriodNs (1,1) double = 5
    % Keep in step with RUN_HDL_GENERATION's target list. Adding a DUT there
    % and not here has now happened twice: generation covers it, synthesis
    % silently does not, and the published table is short by a row with no
    % error to notice. RUN_SYNTHESIS checks the two lists agree.
    options.Targets (1,:) string = ["fft-correlator-fixed", ...
        "blind-detector", "acquisition", "framing", "sfd", ...
        "toa-interpolator", "joint-timing-cfo", "frequency-estimator"]
    options.VivadoPath (1,1) string = string(getenv("VIVADO_PATH"))
    options.OutputDirectory string = string.empty
    options.WriteCsv (1,1) logical = true
    options.Verbose (1,1) logical = true
end

simulinkRoot = fileparts(mfilename("fullpath"));
repositoryRoot = fileparts(fileparts(simulinkRoot));
if isempty(options.OutputDirectory)
    options.OutputDirectory = string(fullfile(repositoryRoot, "docs", "data"));
end
if ~isfile(options.VivadoPath)
    error("lora_sim:NoVivado", "Set VIVADO_PATH or pass VivadoPath; launcher not found: %s", options.VivadoPath);
end

generatedRoot = fullfile(repositoryRoot, "fpga", "generated");
buildRoot = fullfile(repositoryRoot, "fpga", "build");
if ~isfolder(buildRoot)
    mkdir(buildRoot);
end
tclScript = fullfile(repositoryRoot, "fpga", "scripts", "synth_ooc.tcl");

% Every generated DUT must have a known synthesis definition. The selected
% Targets may be a subset for a focused measurement, but an unknown generated
% directory still means generation and synthesis have drifted apart.
knownTargets = ["fft-correlator-fixed", "blind-detector", ...
    "acquisition", "framing", "sfd", "toa-interpolator", ...
    "joint-timing-cfo", "frequency-estimator"];
unknown = setdiff(options.Targets, knownTargets);
if ~isempty(unknown)
    error("lora_sim:UnknownSynthesisTarget", ...
        "Unknown synthesis target: %s", strjoin(unknown, ", "));
end
generatedTargets = string.empty;
entries = dir(generatedRoot);
for k = 1:numel(entries)
    if entries(k).isdir && ~startsWith(entries(k).name, ".")
        generatedTargets(end+1) = string(entries(k).name); %#ok<AGROW>
    end
end
missing = setdiff(generatedTargets, knownTargets);
if ~isempty(missing)
    error("lora_sim:UnsynthesizedTarget", ...
        "Generated but not in the synthesis target list: %s", ...
        strjoin(missing, ", "));
end

rows = {};
failures = strings(0, 1);

for target = options.Targets
    sourceDirectory = findVerilogDirectory(fullfile(generatedRoot, target));
    if sourceDirectory == ""
        failures(end+1, 1) = target+": no generated Verilog"; %#ok<AGROW>
        continue;
    end

    workDirectory = fullfile(buildRoot, target);
    if isfolder(workDirectory)
        rmdir(workDirectory, "s");
    end
    mkdir(workDirectory);
    resultFile = fullfile(workDirectory, "synth.txt");
    preferredTop = generatedTopName(target);

    command = sprintf('"%s" -mode batch -nojournal -nolog -source "%s" ' + ...
        "-tclargs ""%s"" ""%s"" %g ""%s"" ""%s""", ...
        options.VivadoPath, tclScript, sourceDirectory, options.Part, ...
        options.ProbePeriodNs, resultFile, preferredTop);
    previous = cd(workDirectory);
    cleanup = onCleanup(@() cd(previous));
    [status, output] = system(command);
    clear cleanup;

    if status ~= 0 || ~isfile(resultFile)
        failures(end+1, 1) = target+": synthesis failed"; %#ok<AGROW>
        if options.Verbose
            fprintf("%-22s FAILED\n%s\n", target, tail(output, 25));
        end
        continue;
    end

    values = readKeyValues(resultFile);
    rows{end+1} = table(target, string(options.Part), ...
        options.ProbePeriodNs, values.luts, values.registers, ...
        values.bram_tiles, values.dsps, values.carry4, values.wns_ns, ...
        values.achieved_period_ns, values.fmax_mhz, ...
        VariableNames=["Target", "Part", "ProbePeriodNs", "LUTs", ...
        "Registers", "BramTiles", "DSPs", "Carry4", "WnsNs", ...
        "AchievedPeriodNs", "FmaxMHz"]); %#ok<AGROW>

    if options.Verbose
        fprintf("%-22s LUT=%-6d FF=%-6d BRAM=%-5g DSP=%-4d Fmax=%.1f MHz\n", ...
            target, values.luts, values.registers, values.bram_tiles, ...
            values.dsps, values.fmax_mhz);
    end
end

report = struct;
report.summary = vertcat(rows{:});
report.failures = failures;
report.passed = isempty(failures) && ~isempty(rows);
report.part = options.Part;
report.synthesized = true;
report.placedAndRouted = false;

if options.WriteCsv && ~isempty(rows)
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    writetable(report.summary, fullfile(options.OutputDirectory, ...
        "simulink-m3-synthesis.csv"));
end

if options.Verbose
    fprintf("\n");
    if ~isempty(rows)
        disp(report.summary);
    end
    if report.passed
        fprintf("Synthesis only. Not placed, not routed, no power figure, " + ...
            "and no board wrapper: these are out-of-context results.\n");
    else
        fprintf("FAILURES:\n  %s\n", strjoin(failures, newline+"  "));
    end
end
end

function name = generatedTopName(target)
%GENERATEDTOPNAME Top module produced by RUN_HDL_GENERATION's ModulePrefix.
switch target
    case "fft-correlator-fixed"
        name = "lora_fft_DUT";
    case "acquisition"
        name = "lora_acq_DUT";
    case "blind-detector"
        name = "lora_blind_DUT";
    case "framing"
        name = "lora_frame_DUT";
    case "sfd"
        name = "lora_sfd_DUT";
    case "toa-interpolator"
        name = "lora_toa_DUT";
    case "joint-timing-cfo"
        name = "lora_sync_DUT";
    case "frequency-estimator"
        name = "lora_freq_DUT";
    otherwise
        error("lora_sim:UnknownSynthesisTarget", ...
            "No generated top name for %s", target);
end
end

function directory = findVerilogDirectory(root)
%FINDVERILOGDIRECTORY HDL Coder nests the Verilog one level under the target.
directory = "";
if ~isfolder(root)
    return;
end
if ~isempty(dir(fullfile(root, "*.v")))
    directory = string(root);
    return;
end
entries = dir(root);
for k = 1:numel(entries)
    if entries(k).isdir && ~startsWith(entries(k).name, ".")
        candidate = fullfile(root, entries(k).name);
        if ~isempty(dir(fullfile(candidate, "*.v")))
            directory = string(candidate);
            return;
        end
    end
end
end

function values = readKeyValues(path)
values = struct("luts", NaN, "registers", NaN, "bram_tiles", NaN, ...
    "dsps", NaN, "carry4", NaN, "wns_ns", NaN, ...
    "achieved_period_ns", NaN, "fmax_mhz", NaN);
lines = string(splitlines(strtrim(fileread(path))));
for k = 1:numel(lines)
    parts = split(lines(k), "=");
    if numel(parts) == 2 && isfield(values, parts(1))
        values.(parts(1)) = str2double(parts(2));
    end
end
end

function text = tail(output, count)
lines = string(splitlines(string(output)));
lines = lines(max(1, numel(lines)-count+1):end);
text = strjoin(lines, newline);
end
