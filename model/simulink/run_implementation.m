function report = run_implementation(options)
%RUN_IMPLEMENTATION Place, route, and estimate power for selected DUTs.
%
% Boundary-register wrappers close every functional input and output into a
% register-to-register path without inventing PS, AXI, package pins, or board
% clocking. Timing is measured against an aggressive probe period. Vectorless
% power is estimated separately at the application sample clock under the
% explicit assumptions recorded in the output table.
%
% RUN_HDL_GENERATION now prefixes generated module names so several HDL Coder
% targets can coexist in one Vivado design. The wrapper flow passes the
% preferred generated module and a target-specific Verilog macro to Tcl; Tcl
% falls back to historical module DUT for already-committed generated snapshots.
%
%   report = run_implementation;
%   report = run_implementation(Targets="toa-interpolator");

arguments
    options.Part (1,1) string = "xc7z020clg484-1"
    options.ProbePeriodNs (1,1) double {mustBePositive} = 5
    options.PowerClockMHz (1,1) double {mustBePositive} = 4
    options.InputTogglePercent (1,1) double ...
        {mustBeGreaterThanOrEqual(options.InputTogglePercent, 0), ...
        mustBeLessThan(options.InputTogglePercent, 200)} = 12.5
    options.JunctionTemperatureC (1,1) double = 25
    options.Targets (1,:) string = ...
        ["fft-correlator-fixed", "toa-interpolator"]
    options.VivadoPath (1,1) string = ...
        string(getenv("VIVADO_PATH"))
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

definitions = targetDefinitions(repositoryRoot);
unknown = setdiff(options.Targets, string({definitions.name}));
if ~isempty(unknown)
    error("lora_sim:UnknownImplementationTarget", ...
        "No boundary wrapper for: %s", strjoin(unknown, ", "));
end

generatedRoot = fullfile(repositoryRoot, "fpga", "generated");
buildRoot = fullfile(repositoryRoot, "fpga", "build", "post-route");
if ~isfolder(buildRoot)
    mkdir(buildRoot);
end
tclScript = fullfile(repositoryRoot, "fpga", "scripts", "implement_ooc.tcl");

rows = {};
failures = strings(0, 1);
for target = options.Targets
    definitionIndex = find(string({definitions.name}) == target, 1);
    if isempty(definitionIndex)
        failures(end+1, 1) = target+": no boundary wrapper"; %#ok<AGROW>
        continue;
    end
    definition = definitions(definitionIndex);
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
    resultFile = fullfile(workDirectory, "implementation.txt");

    command = sprintf('"%s" -mode batch -nojournal -nolog -source "%s" ' + ...
        "-tclargs ""%s"" ""%s"" ""%s"" ""%s"" ""%s"" ""%s"" %g %g %g %g ""%s""", ...
        options.VivadoPath, tclScript, sourceDirectory, definition.wrapper, ...
        definition.top, definition.generatedTop, definition.generatedMacro, ...
        options.Part, options.ProbePeriodNs, options.PowerClockMHz, ...
        options.InputTogglePercent, options.JunctionTemperatureC, resultFile);
    if options.Verbose
        fprintf("Running: %s\n", command);
    end
    previous = cd(workDirectory);
    cleanup = onCleanup(@() cd(previous));
    [status, output] = system(command);
    clear cleanup;

    if status ~= 0 || ~isfile(resultFile)
        failures(end+1, 1) = target+": implementation failed"; %#ok<AGROW>
        if options.Verbose
            fprintf("%-22s FAILED\n%s\n", target, tail(output, 35));
        end
        continue;
    end

    values = readKeyValues(resultFile);
    labels = readTextValues(resultFile);
    required = struct2array(values);
    if any(isnan(required))
        failures(end+1, 1) = target+": incomplete implementation report"; %#ok<AGROW>
    elseif ~logical(values.route_complete)
        failures(end+1, 1) = target+": routing errors remain"; %#ok<AGROW>
    elseif ~logical(values.power_confidence_medium)
        failures(end+1, 1) = target+": power confidence is not Medium"; %#ok<AGROW>
    end
    rows{end+1} = table(target, string(options.Part), ...
        options.ProbePeriodNs, options.PowerClockMHz, ...
        options.InputTogglePercent, options.JunctionTemperatureC, ...
        logical(values.route_complete), values.luts, values.registers, ...
        values.bram_tiles, values.dsps, values.carry4, ...
        values.setup_wns_ns, values.hold_wns_ns, ...
        values.achieved_period_ns, values.fmax_mhz, ...
        values.critical_datapath_delay_ns, ...
        values.critical_logic_delay_ns, values.critical_net_delay_ns, ...
        labels.critical_startpoint, labels.critical_endpoint, ...
        values.total_on_chip_power_w, values.dynamic_power_w, ...
        values.device_static_power_w, values.power_report_resolution_w, ...
        logical(values.power_confidence_medium), "vectorless", ...
        VariableNames=["Target", "Part", "ProbePeriodNs", "PowerClockMHz", ...
        "InputTogglePercent", "JunctionTemperatureC", "RouteComplete", ...
        "LUTs", "Registers", "BramTiles", "DSPs", "Carry4", ...
        "SetupWnsNs", "HoldWnsNs", "AchievedPeriodNs", "FmaxMHz", ...
        "CriticalDataPathDelayNs", "CriticalLogicDelayNs", ...
        "CriticalNetDelayNs", "CriticalStartpoint", "CriticalEndpoint", ...
        "TotalOnChipPowerW", "DynamicPowerW", "DeviceStaticPowerW", ...
        "PowerReportResolutionW", "PowerConfidenceMedium", ...
        "PowerMethod"]); %#ok<AGROW>

    if options.Verbose
        fprintf("%-22s LUT=%-6d FF=%-6d Fmax=%-7.1f MHz " + ...
            "power@%.1fMHz=%.3f W\n", target, values.luts, ...
            values.registers, values.fmax_mhz, options.PowerClockMHz, ...
            values.total_on_chip_power_w);
    end
end

report = struct;
if isempty(rows)
    report.summary = table;
else
    report.summary = vertcat(rows{:});
end
report.failures = failures;
report.passed = isempty(failures) && height(report.summary) == numel(options.Targets);
report.part = options.Part;
report.synthesized = ~isempty(rows);
report.placedAndRouted = report.passed && all(report.summary.RouteComplete);
report.powerEstimated = report.passed && ...
    all(report.summary.PowerConfidenceMedium);
report.powerMethod = "vectorless";

if options.WriteCsv && ~isempty(rows)
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    writetable(report.summary, fullfile(options.OutputDirectory, ...
        "simulink-m3-post-route.csv"));
end

if options.Verbose
    fprintf("\n");
    if ~isempty(rows)
        disp(report.summary);
    end
    if report.passed
        fprintf("Placed and routed out of context. Power is a vectorless " + ...
            "core estimate, not a board measurement.\n");
    else
        fprintf("FAILURES:\n  %s\n", strjoin(failures, newline+"  "));
    end
end
end

function definitions = targetDefinitions(repositoryRoot)
wrapperRoot = fullfile(repositoryRoot, "fpga", "wrappers");
definitions = struct( ...
    "name", {"fft-correlator-fixed", "toa-interpolator"}, ...
    "top", {"fft_correlator_route_top", "toa_interpolator_route_top"}, ...
    "generatedTop", {"lora_fft_DUT", "lora_toa_DUT"}, ...
    "generatedMacro", {"LORA_FFT_GENERATED_DUT", "LORA_TOA_GENERATED_DUT"}, ...
    "wrapper", { ...
        fullfile(wrapperRoot, "fft_correlator_route_top.v"), ...
        fullfile(wrapperRoot, "toa_interpolator_route_top.v")});
end

function directory = findVerilogDirectory(root)
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
values = struct("route_complete", NaN, "luts", NaN, "registers", NaN, ...
    "bram_tiles", NaN, "dsps", NaN, "carry4", NaN, ...
    "setup_wns_ns", NaN, "hold_wns_ns", NaN, ...
    "achieved_period_ns", NaN, "fmax_mhz", NaN, ...
    "critical_datapath_delay_ns", NaN, ...
    "critical_logic_delay_ns", NaN, "critical_net_delay_ns", NaN, ...
    "total_on_chip_power_w", NaN, "dynamic_power_w", NaN, ...
    "device_static_power_w", NaN, "power_report_resolution_w", NaN, ...
    "power_confidence_medium", NaN);
lines = string(splitlines(strtrim(fileread(path))));
for k = 1:numel(lines)
    parts = split(lines(k), "=");
    if numel(parts) == 2 && isfield(values, parts(1))
        values.(parts(1)) = str2double(parts(2));
    end
end
end

function values = readTextValues(path)
values = struct("critical_startpoint", "", "critical_endpoint", "");
lines = string(splitlines(strtrim(fileread(path))));
for k = 1:numel(lines)
    separator = strfind(lines(k), "=");
    if ~isempty(separator)
        key = extractBefore(lines(k), separator(1));
        if isfield(values, key)
            values.(key) = extractAfter(lines(k), separator(1));
        end
    end
end
end

function text = tail(output, count)
lines = string(splitlines(string(output)));
lines = lines(max(1, numel(lines)-count+1):end);
text = strjoin(lines, newline);
end
