function report = run_hdl_generation(options)
%RUN_HDL_GENERATION Generate Verilog for the M2 DUTs and report resources.
%
% This is the first M3 step and it stops where the installed toolchain
% stops. It generates Verilog with HDL Coder and collects the resource
% utilization report that HDL Coder derives from the generated code.
%
% It does NOT synthesize and it does NOT cosimulate. The resource numbers
% below are HDL Coder's count of inferred operators, not a synthesis result,
% and must never be reported as LUT/FF/DSP/BRAM.
%
% For silicon numbers use RUN_SYNTHESIS, which drives Vivado out of context.
% For cycle-accurate HDL verification use RUN_HDL_COSIMULATION, which builds a
% temporary namespaced ToA core with Vivado XSim through HDL Verifier.
%
% Each target gets a unique ModulePrefix. Without it every generated
% subsystem is named DUT, which is valid out of context but prevents several
% generated cores from being compiled into one board-level Vivado design.
%
%   report = run_hdl_generation;
%   report = run_hdl_generation(WordLength=16, SpreadingFactor=7);

arguments
    % 20 since #32: at 16 the correlator's window was ~20..5000 input LSB and
    % weak board packets fell below it; the fraction bits set the floor.
    options.WordLength (1,1) double {mustBeInteger, mustBePositive} = 20
    % 40 since #34: |X|^2 for the peak search keeps every bit of the 20-bit
    % ScaleByM output squared; at 20 it was ufix20_E1 and weak symbols tied
    % at 0/2 and went to bin 0 (PER 1 at ~6 LSB rms noise on the board).
    options.PowerWordLength (1,1) double {mustBeInteger, mustBeNonnegative} = 40
    options.SpreadingFactor (1,1) double = 7
    options.SamplesPerChip (1,1) double = 8
    options.Targets (1,:) string = ["fft-correlator-fixed", ...
        "acquisition", "blind-detector", "framing", "sfd", ...
        "toa-interpolator", "joint-timing-cfo", ...
        "frequency-estimator"]
    options.TargetDirectory string = string.empty
    options.OutputDirectory string = string.empty
    options.WriteCsv (1,1) logical = true
    options.Verbose (1,1) logical = true
end

simulinkRoot = fileparts(mfilename("fullpath"));
repositoryRoot = fileparts(fileparts(simulinkRoot));
addpath(simulinkRoot);
addpath(fullfile(repositoryRoot, "model", "matlab"));
if isempty(options.TargetDirectory)
    options.TargetDirectory = string(fullfile(repositoryRoot, "fpga", ...
        "generated"));
end
if isempty(options.OutputDirectory)
    options.OutputDirectory = string(fullfile(repositoryRoot, "docs", "data"));
end

if ~license("test", "Simulink_HDL_Coder")
    error("lora_sim:NoHdlCoderLicense", ...
        "HDL Coder is licensed as Simulink_HDL_Coder and is not available");
end

targets = struct([]);
entry = struct;
entry.name = "fft-correlator-fixed";
entry.modulePrefix = "lora_fft_";
entry.builder = @() build_fft_correlator_model( ...
    SpreadingFactor=options.SpreadingFactor, ...
    SamplesPerChip=options.SamplesPerChip, DataType="fixed", ...
    WordLength=options.WordLength, PowerWordLength=options.PowerWordLength, ...
    IncludeVerificationTaps=false, ...
    ModelName="lora_fft_correlator_gen");
targets = [targets; entry];

entry = struct;
entry.name = "acquisition";
entry.modulePrefix = "lora_acq_";
entry.builder = @() build_acquisition_model( ...
    SpreadingFactor=options.SpreadingFactor, ...
    ModelName="lora_acquisition_gen");
targets = [targets; entry];

entry = struct;
entry.name = "blind-detector";
entry.modulePrefix = "lora_blind_";
entry.builder = @() build_blind_detector_model( ...
    SpreadingFactor=options.SpreadingFactor, ...
    ModelName="lora_blind_detector_gen");
targets = [targets; entry];

entry = struct;
entry.name = "framing";
entry.modulePrefix = "lora_frame_";
entry.builder = @() build_framing_model(ModelName="lora_framing_gen");
targets = [targets; entry];

entry = struct;
entry.name = "sfd";
entry.modulePrefix = "lora_sfd_";
entry.builder = @() build_sfd_model( ...
    SpreadingFactor=options.SpreadingFactor, ModelName="lora_sfd_gen");
targets = [targets; entry];

entry = struct;
entry.name = "toa-interpolator";
entry.modulePrefix = "lora_toa_";
entry.builder = @() build_toa_interpolator_model( ...
    ModelName="lora_toa_interpolator_gen");
targets = [targets; entry];

entry = struct;
entry.name = "joint-timing-cfo";
entry.modulePrefix = "lora_sync_";
entry.builder = @() build_joint_sync_model( ...
    SpreadingFactor=options.SpreadingFactor, ...
    SamplesPerChip=options.SamplesPerChip, ...
    ModelName="lora_joint_sync_gen");
targets = [targets; entry];

entry = struct;
entry.name = "frequency-estimator";
entry.modulePrefix = "lora_freq_";
entry.builder = @() build_frequency_estimator_model( ...
    SpreadingFactor=options.SpreadingFactor, ...
    SamplesPerChip=options.SamplesPerChip, ...
    ModelName="lora_frequency_estimator_gen");
targets = [targets; entry];

targetNames = string({targets.name});
unknown = setdiff(options.Targets, targetNames);
if ~isempty(unknown)
    error("lora_sim:UnknownHdlTarget", "Unknown HDL target: %s", ...
        strjoin(unknown, ", "));
end
targets = targets(ismember(targetNames, options.Targets));

rows = {};
failures = strings(0, 1);

for k = 1:numel(targets)
    target = targets(k);
    info = target.builder();
    cleanup = onCleanup(@() closeGeneratedModel(info.modelName));
    if ~bdIsLoaded(info.modelName)
        load_system(info.modelPath);
    end
    assignStimulus(info);

    targetDirectory = fullfile(options.TargetDirectory, target.name);
    if isfolder(targetDirectory)
        rmdir(targetDirectory, "s");
    end
    mkdir(targetDirectory);

    hdlset_param(char(info.modelName), "TargetLanguage", "Verilog");
    hdlset_param(char(info.modelName), "TargetDirectory", ...
        char(targetDirectory));
    hdlset_param(char(info.modelName), "ModulePrefix", ...
        char(target.modulePrefix));
    hdlset_param(char(info.modelName), "ResourceReport", "on");
    hdlset_param(char(info.modelName), "GenerateHDLTestBench", "off");
    if target.name == "fft-correlator-fixed"
        % Output registers on the long arithmetic chains, outside the two
        % accumulator loops (AccumSum/AccumDelay, SpectrumSum/SpectrumDelay),
        % so the function is unchanged and HDL Coder's delay balancing
        % aligns the parallel paths. At WordLength 20 the unpipelined core
        % missed the board clock by 0.446 ns on FFT_N -> ScaleByM ->
        % MagnitudeSquared -> Confidence divisor (28 levels) and on
        % resetIn -> Multiply -> AccumDelay (#32, 2026-09-28).
        dut = char(info.dutPath);
        hdlset_param([dut '/Multiply'], "OutputPipeline", 1);
        hdlset_param([dut '/ScaleByM'], "OutputPipeline", 1);
        hdlset_param([dut '/MagnitudeSquared'], "OutputPipeline", 2);
        hdlset_param([dut '/GuardedSum'], "OutputPipeline", 1);
    end

    generated = 0;
    failure = "";
    try
        makehdl(char(info.dutPath));
        files = dir(fullfile(targetDirectory, "**", "*.v"));
        generated = numel(files);
    catch err
        failure = string(err.identifier)+": "+string(err.message);
    end

    resources = readResourceReport(targetDirectory);
    rows{end+1} = table(string(target.name), string(target.modulePrefix), ...
        string(info.dutPath), options.SpreadingFactor, options.SamplesPerChip, ...
        options.WordLength, generated, resources.multipliers, ...
        resources.adders, resources.registers, resources.registerBits, ...
        resources.rams, resources.multiplexers, resources.ioBits, ...
        resources.pipelineLatency, failure, ...
        VariableNames=["Target", "ModulePrefix", "Dut", "SF", "L", ...
        "WordLength", "VerilogFiles", "Multipliers", "AddersSubtractors", ...
        "Registers", "RegisterBits", "RAMs", "Multiplexers", "IoBits", ...
        "AddedPipelineLatency", "Failure"]); %#ok<AGROW>

    if failure ~= ""
        failures(end+1, 1) = target.name+": "+failure; %#ok<AGROW>
    elseif generated == 0
        failures(end+1, 1) = target.name+": no Verilog produced"; %#ok<AGROW>
    end
    if options.Verbose
        fprintf("%-22s prefix=%-12s files=%-3d mult=%-5s add=%-5s reg=%-6s ram=%-5s latency=%-4s %s\n", ...
            target.name, target.modulePrefix, generated, ...
            num2str(resources.multipliers), num2str(resources.adders), ...
            num2str(resources.registers), num2str(resources.rams), ...
            num2str(resources.pipelineLatency), failure);
    end
    clear cleanup;
end

report = struct;
report.summary = vertcat(rows{:});
report.failures = failures;
report.passed = isempty(failures);
report.targetDirectory = options.TargetDirectory;
report.synthesized = false;
report.cosimulated = false;

if options.WriteCsv
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    writetable(report.summary, fullfile(options.OutputDirectory, ...
        "simulink-m3-hdl-generation.csv"));
end

if options.Verbose
    fprintf("\n");
    disp(report.summary);
    if report.passed
        fprintf("Verilog generated with unique module prefixes. Operator " + ...
            "counts, not synthesis results -- run run_synthesis for " + ...
            "LUT/FF/DSP/BRAM.\n");
    else
        fprintf("FAILURES:\n  %s\n", strjoin(failures, newline+"  "));
    end
end
end

function resources = readResourceReport(targetDirectory)
%READRESOURCEREPORT Operator counts and added pipeline latency from HDL Coder.
%
% These come from HDL Coder's generic resource report ("bill of materials"),
% which counts operators inferred from the generated code. They are NOT
% synthesis results and must never be reported as LUT/FF/DSP/BRAM.
%
% PipelineLatency is the extra latency HDL Coder's delay balancing adds on
% top of the model, so hardware latency is the model latency plus this.
resources = struct("multipliers", NaN, "adders", NaN, "registers", NaN, ...
    "registerBits", NaN, "rams", NaN, "multiplexers", NaN, ...
    "ioBits", NaN, "pipelineLatency", NaN);

bom = dir(fullfile(targetDirectory, "**", "*bill_of_materials.html"));
if ~isempty(bom)
    text = flattenReport(fullfile(bom(1).folder, bom(1).name));
    summary = extractBetween(text, "Summary", "Detailed Report");
    if isempty(summary)
        summary = string(text);
    else
        summary = summary(1);
    end
    resources.multipliers = scalarAfter(summary, "Multipliers");
    resources.adders = scalarAfter(summary, "Adders/Subtractors");
    resources.registers = scalarAfter(summary, "Registers");
    resources.registerBits = scalarAfter(summary, "Total 1-Bit Registers");
    resources.rams = scalarAfter(summary, "RAMs");
    resources.multiplexers = scalarAfter(summary, "Multiplexers");
    resources.ioBits = scalarAfter(summary, "I/O Bits");
end

delays = dir(fullfile(targetDirectory, "**", "*delay_balancing.html"));
if ~isempty(delays)
    text = flattenReport(fullfile(delays(1).folder, delays(1).name));
    tokens = regexp(text, "/DUT/\w+\s+(\d+)\s+\d+", "tokens");
    if ~isempty(tokens)
        values = cellfun(@(c) str2double(c{1}), tokens);
        resources.pipelineLatency = max(values);
    end
end
end

function text = flattenReport(path)
text = fileread(path);
text = regexprep(text, "<[^>]*>", " ");
text = string(regexprep(text, "\s+", " "));
end

function value = scalarAfter(text, label)
value = NaN;
pattern = regexptranslate("escape", label)+"\s+([0-9]+)";
token = regexp(text, pattern, "tokens", "once");
if ~isempty(token)
    value = str2double(token{1});
end
end

function assignStimulus(info)
%ASSIGNSTIMULUS Minimal base-workspace stimulus so the model can compile.
samples = 8;
timeAxis = (0:samples-1).';
assignin("base", "stimulusIq", ...
    timeseries(complex(zeros(samples, 1)), timeAxis));
assignin("base", "stimulusValid", timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusReset", timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusResyncValid", ...
    timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusResyncSkip", ...
    timeseries(zeros(samples, 1, "uint32"), timeAxis));
binDataType = "uint16";
if isfield(info, "binDataType")
    binDataType = info.binDataType;
end
assignin("base", "stimulusUpBin", ...
    timeseries(zeros(samples, 1, binDataType), timeAxis));
assignin("base", "stimulusMagnitudeBefore", ...
    timeseries(ones(samples, 1, "uint32"), timeAxis));
assignin("base", "stimulusMagnitudePeak", ...
    timeseries(2*ones(samples, 1, "uint32"), timeAxis));
assignin("base", "stimulusMagnitudeAfter", ...
    timeseries(ones(samples, 1, "uint32"), timeAxis));
assignin("base", "stimulusTripletValid", ...
    timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusDownBin", ...
    timeseries(zeros(samples, 1, binDataType), timeAxis));
assignin("base", "stimulusBinValid", timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusSymbolIndex", ...
    timeseries(zeros(samples, 1, "uint16"), timeAxis));
assignin("base", "stimulusSymbolValid", ...
    timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusSyncWord", ...
    timeseries(zeros(samples, 1, "uint8"), timeAxis));
assignin("base", "stimulusPreambleBin", ...
    timeseries(zeros(samples, 1, "uint16"), timeAxis));
assignin("base", "stimulusPreambleDetected", ...
    timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusSyncValid", timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusSfdValid", timeseries(false(samples, 1), timeAxis));
assignin("base", "stimulusHeaderSymbols", ...
    timeseries(zeros(samples, 1, "uint16"), timeAxis));
assignin("base", "stimulusPayloadSymbols", ...
    timeseries(zeros(samples, 1, "uint16"), timeAxis));
set_param(info.modelName, StopTime=num2str(samples-1));
end

function closeGeneratedModel(modelName)
if bdIsLoaded(modelName)
    set_param(modelName, Dirty="off");
    close_system(modelName, 0);
end
end
