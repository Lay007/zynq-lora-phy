function report = run_hdl_cosimulation(options)
%RUN_HDL_COSIMULATION Compare generated ToA RTL with Simulink cycle by cycle.
%
% This is the executable M3 cosimulation gate. HDL Coder generates the
% namespaced Verilog, HDL Verifier replaces the DUT by a Vivado Simulator
% S-function, and the same registered stimulus is applied to both models.
%
%   report = run_hdl_cosimulation;
%   report = run_hdl_cosimulation( ...
%       VivadoPath=string(getenv("VIVADO_PATH")));

arguments
    options.VivadoPath (1,1) string = ...
        string(getenv("VIVADO_PATH"))
    options.WorkDirectory string = string.empty
    options.OutputDirectory string = string.empty
    options.WriteCsv (1,1) logical = true
    options.KeepWorkDirectory (1,1) logical = false
    options.Verbose (1,1) logical = true
end

simulinkRoot = fileparts(mfilename("fullpath"));
repositoryRoot = fileparts(fileparts(simulinkRoot));
addpath(simulinkRoot);

if isempty(options.OutputDirectory)
    options.OutputDirectory = string(fullfile(repositoryRoot, "docs", "data"));
end
if isempty(options.WorkDirectory)
    options.WorkDirectory = string(fullfile(tempdir, ...
        "zynq_lora_phy_toa_cosimulation"));
end

if ~license("test", "Simulink_HDL_Coder")
    error("lora_sim:NoHdlCoderLicense", "Simulink HDL Coder is unavailable");
end
if ~license("test", "EDA_Simulator_Link")
    error("lora_sim:NoHdlVerifierLicense", "HDL Verifier is unavailable");
end
if ~isfile(options.VivadoPath)
    error("lora_sim:VivadoNotFound", "Set VIVADO_PATH or pass VivadoPath; launcher not found: %s", ...
        options.VivadoPath);
end

if isfolder(options.WorkDirectory)
    rmdir(options.WorkDirectory, "s");
end
mkdir(options.WorkDirectory);
workCleanup = onCleanup(@() cleanWorkDirectory( ...
    options.WorkDirectory, options.KeepWorkDirectory));

modelName = "lora_toa_hdl_cosim_check";
targetDirectory = fullfile(options.WorkDirectory, modelName);
info = build_toa_interpolator_model( ...
    ModelName=modelName, OutputDirectory=options.WorkDirectory);
modelCleanup = onCleanup(@() closeModels(modelName));

% Include symmetric peaks, both offset signs, small operands and nearly
% full-scale operands. Requests are separated by more than the documented
% 38-cycle latency so every pulse must be accepted.
triplets = uint32([
    100,       200,       100
    100,       200,       150
    150,       200,       100
    1,         2,         1
    10000,     100000,    25000
    25000,     100000,    10000
    1677721,   16777216,  8388608
    8388608,   16777216,  1677721]);
caseCount = size(triplets, 1);
stride = info.latencyCycles+6;
simulationLength = (caseCount-1)*stride+info.latencyCycles+3;
[stimulus, requestCycles] = makeStimulus(triplets, simulationLength, stride);
assignStimulus(stimulus);

load_system(info.modelPath);
set_param(modelName, StopTime=num2str(simulationLength-1));
referenceOut = sim(modelName);
reference = collectOutputs(referenceOut);

hdlsetuptoolpath("ToolName", "Xilinx Vivado", ...
    "ToolPath", char(options.VivadoPath));
hdlset_param(modelName, "TargetLanguage", "Verilog");
hdlset_param(modelName, "TargetDirectory", char(targetDirectory));
hdlset_param(modelName, "ModulePrefix", "lora_toa_cosim_");
hdlset_param(modelName, "ResourceReport", "off");
hdlset_param(modelName, "GenerateHDLTestBench", "off");
hdlset_param(modelName, "SimulationTool", "Xilinx Vivado Simulator");

makehdl(char(info.dutPath));
makehdltb(char(info.dutPath), "GenerateHDLTestBench", "off", ...
    "GenerateCoSimModel", "Vivado Simulator");

cosimModelName = "gm_"+modelName+"_vs";
if ~bdIsLoaded(cosimModelName)
    error("lora_sim:CosimModelMissing", ...
        "HDL Verifier did not load %s", cosimModelName);
end
cosimModelPath = fullfile(targetDirectory, cosimModelName+".slx");
save_system(cosimModelName, cosimModelPath);

designFiles = dir(fullfile(targetDirectory, "**", ...
    "lora_toa_cosim_DUT.v"));
if isempty(designFiles)
    error("lora_sim:GeneratedVerilogMissing", ...
        "Generated ToA top-level Verilog was not found");
end
designDirectory = designFiles(1).folder;
previousDirectory = pwd;
directoryCleanup = onCleanup(@() cd(previousDirectory));
cd(designDirectory);
[status, output] = system(strjoin([
    "xvlog --work work lora_toa_cosim_ToaInterpolator.v lora_toa_cosim_DUT.v"
    "xelab lora_toa_cosim_DUT --timescale 1ps/1ps --override_timeunit --override_timeprecision -dll --snapshot design -debug wave"], " && "));
if status ~= 0
    error("lora_sim:XsimElaborationFailed", ...
        "Vivado XSim elaboration failed:\n%s", output);
end
if ~isfolder(fullfile(designDirectory, "xsim.dir", "design"))
    error("lora_sim:XsimSnapshotMissing", ...
        "Vivado XSim did not create xsim.dir/design");
end
set_param(cosimModelName, StopTime=num2str(simulationLength-1));
assignStimulus(stimulus);
cosimOut = sim(cosimModelName);
actual = collectOutputs(cosimOut);
clear directoryCleanup;
cd(previousDirectory);

failures = strings(0, 1);
if numel(reference.validCycles) ~= caseCount
    failures(end+1, 1) = sprintf("Simulink emitted %d/%d decisions", ...
        numel(reference.validCycles), caseCount);
end
if numel(actual.validCycles) ~= caseCount
    failures(end+1, 1) = sprintf("RTL emitted %d/%d decisions", ...
        numel(actual.validCycles), caseCount);
end
if ~isequal(reference.validCycles, actual.validCycles)
    failures(end+1, 1) = "RTL valid pulses differ from Simulink cycles";
end
if ~isequal(reference.offset, actual.offset)
    failures(end+1, 1) = "RTL fractional offsets differ from Simulink";
end
if ~isequal(reference.logPeak, actual.logPeak)
    failures(end+1, 1) = "RTL log-peak values differ from Simulink";
end

if isempty(actual.validCycles)
    firstLatency = NaN;
    maxLatency = NaN;
else
    latencies = actual.validCycles(:)-requestCycles(1:numel(actual.validCycles));
    firstLatency = latencies(1);
    maxLatency = max(latencies);
end
report = struct;
report.summary = table(caseCount, numel(actual.validCycles), ...
    firstLatency, maxLatency, isequal(reference.validCycles, actual.validCycles), ...
    isequal(reference.offset, actual.offset), ...
    isequal(reference.logPeak, actual.logPeak), ...
    string(options.VivadoPath), ...
    VariableNames=["Cases", "RtlDecisions", "FirstLatencyCycles", ...
    "MaxLatencyCycles", "ValidCyclesMatch", "OffsetsMatch", ...
    "LogPeaksMatch", "Simulator"]);
report.failures = failures;
report.passed = isempty(failures);
report.reference = reference;
report.actual = actual;
report.cosimModelPath = string(cosimModelPath);

if options.WriteCsv
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    writetable(report.summary, fullfile(options.OutputDirectory, ...
        "simulink-m3-hdl-cosimulation.csv"));
end

if options.Verbose
    disp(report.summary);
    if report.passed
        fprintf("Vivado XSim RTL matches Simulink cycle by cycle for %d ToA cases.\n", ...
            caseCount);
    else
        fprintf("FAILURES:\n  %s\n", strjoin(failures, newline+"  "));
    end
end

clear modelCleanup workCleanup;
closeModels(modelName);
cleanWorkDirectory(options.WorkDirectory, options.KeepWorkDirectory);
end

function [stimulus, requestCycles] = makeStimulus(triplets, length, stride)
time = (0:length-1).';
stimulus.before = zeros(length, 1, "uint32");
stimulus.peak = zeros(length, 1, "uint32");
stimulus.after = zeros(length, 1, "uint32");
stimulus.valid = false(length, 1);
indices = (0:size(triplets, 1)-1)*stride+1;
stimulus.before(indices) = triplets(:, 1);
stimulus.peak(indices) = triplets(:, 2);
stimulus.after(indices) = triplets(:, 3);
stimulus.valid(indices) = true;
stimulus.time = time;
requestCycles = indices(:)-1;
end

function assignStimulus(stimulus)
assignin("base", "stimulusMagnitudeBefore", ...
    timeseries(stimulus.before, stimulus.time));
assignin("base", "stimulusMagnitudePeak", ...
    timeseries(stimulus.peak, stimulus.time));
assignin("base", "stimulusMagnitudeAfter", ...
    timeseries(stimulus.after, stimulus.time));
assignin("base", "stimulusTripletValid", ...
    timeseries(stimulus.valid, stimulus.time));
end

function result = collectOutputs(out)
valid = logical(out.offsetValid(:));
result.validCycles = find(valid)-1;
result.offset = int32(out.offsetSamples(valid));
result.logPeak = int32(out.logPeak(valid));
end

function closeModels(modelName)
names = ["gm_"+modelName+"_vs", "gm_"+modelName, modelName];
for k = 1:numel(names)
    if bdIsLoaded(names(k))
        set_param(names(k), Dirty="off");
        close_system(names(k), 0);
    end
end
end

function cleanWorkDirectory(directory, keep)
if ~keep && isfolder(directory)
    rmdir(directory, "s");
end
end
