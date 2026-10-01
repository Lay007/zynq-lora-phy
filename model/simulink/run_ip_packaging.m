function report = run_ip_packaging(options)
%RUN_IP_PACKAGING Package the generated DUTs as reusable Vivado IP.
%
%   report = run_ip_packaging;
%   report = run_ip_packaging(Targets="toa-interpolator");
%
% Turns each HDL Coder output under fpga/generated into a self-contained IP
% directory under fpga/build/ip/<target>: a component.xml plus a copy of the
% Verilog. Nothing under fpga/generated is written, so regenerating from the
% Simulink model stays the only way to change the RTL.
%
% Packaging is not the same claim as synthesis. RUN_SYNTHESIS measures what a
% core costs in silicon; this measures only that the core can be handed to
% another project as a catalog item. The Tcl layer therefore proves the
% result rather than assuming it: after writing the IP it opens a fresh
% project that knows nothing but the output directory, rebuilds the catalog
% from it, and instantiates the IP. A component.xml that cannot be
% instantiated is not a deliverable and fails the target.
%
% The packaged IP is deliberately versioned 1.0 and carries a GENERATED_FROM
% user parameter naming the HDL Coder target directory it came from, so an
% unpacked IP cannot be mistaken for hand-written RTL.

arguments
    % The board part this project actually targets. Packaging is part
    % independent in principle, but the catalog check has to run against
    % something, and running it against the real part is free.
    options.Part (1,1) string = "xc7z020clg400-2"
    % Keep in step with RUN_HDL_GENERATION and RUN_SYNTHESIS. A generated
    % directory that no target covers means the lists have drifted apart.
    options.Targets (1,:) string = ["fft-correlator-fixed", ...
        "blind-detector", "acquisition", "framing", "sfd", ...
        "toa-interpolator", "joint-timing-cfo", "frequency-estimator"]
    options.Version (1,1) string = "1.0"
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
packageRoot = fullfile(repositoryRoot, "fpga", "build", "ip");
if ~isfolder(packageRoot)
    mkdir(packageRoot);
end
tclScript = fullfile(repositoryRoot, "fpga", "scripts", "package_ip.tcl");

knownTargets = ["fft-correlator-fixed", "blind-detector", "acquisition", ...
    "framing", "sfd", "toa-interpolator", "joint-timing-cfo", ...
    "frequency-estimator"];
unknown = setdiff(options.Targets, knownTargets);
if ~isempty(unknown)
    error("lora_sim:UnknownPackagingTarget", ...
        "Unknown packaging target: %s", strjoin(unknown, ", "));
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
    error("lora_sim:UnpackagedTarget", ...
        "Generated but not in the packaging target list: %s", ...
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

    definition = ipDefinition(target);
    outputDirectory = fullfile(packageRoot, target);
    if isfolder(outputDirectory)
        rmdir(outputDirectory, "s");
    end
    mkdir(outputDirectory);

    % Vivado consumes backslash escapes in -tclargs, which turns a Windows
    % path into a different, usually nonexistent one. Hand it forward slashes.
    command = sprintf('"%s" -mode batch -nojournal -nolog -source "%s" ' + ...
        "-tclargs ""%s"" ""%s"" ""%s"" ""%s"" ""%s"" ""%s"" ""%s"" ""%s""", ...
        options.VivadoPath, tclScript, ...
        forwardSlashes(sourceDirectory), options.Part, ...
        forwardSlashes(outputDirectory), definition.top, definition.name, ...
        options.Version, definition.displayName, definition.description);
    previous = cd(outputDirectory);
    cleanup = onCleanup(@() cd(previous));
    [status, output] = system(command);
    clear cleanup;

    reportFile = fullfile(outputDirectory, "package_report.txt");
    if status ~= 0 || ~isfile(reportFile) || ~contains(output, "PACKAGE_OK")
        failures(end+1, 1) = target+": packaging failed"; %#ok<AGROW>
        if options.Verbose
            fprintf("%-22s FAILED\n%s\n", target, tail(output, 25));
        end
        continue;
    end

    values = readKeyValues(reportFile);
    componentPath = fullfile(outputDirectory, "component.xml");
    sourceCount = numel(dir(fullfile(outputDirectory, "src", "*.v")));
    rows{end+1} = table(target, values.vlnv, values.top, ...
        string(options.Part), sourceCount, ...
        isfile(componentPath), ...
        VariableNames=["Target", "Vlnv", "Top", "Part", ...
        "PackagedSourceFiles", "ComponentXml"]); %#ok<AGROW>

    if options.Verbose
        fprintf("%-22s %-58s src=%d\n", target, values.vlnv, sourceCount);
    end
end

report = struct;
report.summary = vertcat(rows{:});
report.failures = failures;
report.passed = isempty(failures) && ~isempty(rows);
report.part = options.Part;
report.packageRoot = string(packageRoot);
% Packaging proves catalog usability only. It is not synthesis, not timing
% closure, and not a hardware claim.
report.synthesized = false;
report.catalogVerified = report.passed;

if options.WriteCsv && ~isempty(rows)
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    writetable(report.summary, fullfile(options.OutputDirectory, ...
        "simulink-m3-ip-packaging.csv"));
end

if options.Verbose
    fprintf("\n");
    if ~isempty(rows)
        disp(report.summary);
    end
    if report.passed
        fprintf("Each IP was re-read from a clean project and instantiated " + ...
            "from the rebuilt catalog. Packaging only: no synthesis, no " + ...
            "timing, no hardware claim.\n");
    else
        fprintf("FAILURES:\n  %s\n", strjoin(failures, newline+"  "));
    end
end
end

function definition = ipDefinition(target)
%IPDEFINITION Catalog identity of one generated target.
%
% The top names follow RUN_HDL_GENERATION's ModulePrefix. The IP names are
% deliberately spelled out rather than derived from the prefix: a catalog
% entry is a published identity and should not silently change if a prefix
% is retuned.
switch target
    case "fft-correlator-fixed"
        definition = entry("lora_fft_DUT", "lora_fft_correlator", ...
            "LoRa FFT correlator", ...
            "Generated fixed-point CSS FFT correlator and peak detector");
    case "blind-detector"
        definition = entry("lora_blind_DUT", "lora_blind_detector", ...
            "LoRa blind packet detector", ...
            "Generated preamble and sync-word detector on the symbol stream");
    case "acquisition"
        definition = entry("lora_acq_DUT", "lora_acquisition", ...
            "LoRa acquisition FSM", ...
            "Generated acquisition state machine and sample-grid realignment");
    case "framing"
        definition = entry("lora_frame_DUT", "lora_framing", ...
            "LoRa packet framing", ...
            "Generated packet framing state machine with re-arming");
    case "sfd"
        definition = entry("lora_sfd_DUT", "lora_sfd_validation", ...
            "LoRa SFD validation", ...
            "Generated start-of-frame delimiter downchirp validation");
    case "toa-interpolator"
        definition = entry("lora_toa_DUT", "lora_toa_interpolator", ...
            "LoRa fractional ToA interpolator", ...
            "Generated fractional time-of-arrival peak interpolator");
    case "joint-timing-cfo"
        definition = entry("lora_sync_DUT", "lora_joint_sync", ...
            "LoRa joint timing and CFO estimator", ...
            "Generated joint timing and carrier-frequency-offset estimator");
    case "frequency-estimator"
        definition = entry("lora_freq_DUT", "lora_frequency_estimator", ...
            "LoRa carrier frequency estimator", ...
            "Generated registered carrier-frequency-only estimator");
    otherwise
        error("lora_sim:UnknownPackagingTarget", ...
            "No IP definition for %s", target);
end
end

function path = forwardSlashes(path)
%FORWARDSLASHES Windows path Vivado can consume without backslash escaping.
path = string(strrep(char(path), '', '/'));
end

function value = entry(top, name, displayName, description)
value = struct("top", top, "name", name, ...
    "displayName", displayName, "description", description);
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
values = struct("vlnv", "", "part", "", "top", "", ...
    "source_directory", "", "source_file_count", "", ...
    "generated_from", "", "component_xml", "");
lines = string(splitlines(strtrim(fileread(path))));
for k = 1:numel(lines)
    parts = split(lines(k), "=");
    if numel(parts) >= 2 && isfield(values, parts(1))
        values.(parts(1)) = strjoin(parts(2:end), "=");
    end
end
end

function text = tail(output, count)
lines = string(splitlines(string(output)));
lines = lines(max(1, numel(lines)-count+1):end);
text = strjoin(lines, newline);
end
