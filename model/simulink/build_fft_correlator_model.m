function info = build_fft_correlator_model(options)
%BUILD_FFT_CORRELATOR_MODEL Generate the streaming CSS FFT-correlator model.
%
% The `.slx` is never edited by hand and is never committed. This script is
% the source of the model: delete the file and call the function again to
% get an equivalent design.
%
%   info = build_fft_correlator_model;
%   info = build_fft_correlator_model(SpreadingFactor=9, SamplesPerChip=2);
%   info = build_fft_correlator_model(DataType="fixed", WordLength=16);
%
% Architecture inside the `DUT` subsystem, matching
% LORA_PHY.FFT_CORRELATOR_STAGES one comparison point at a time:
%
%   iqIn/validIn (already the DUT sample type; the harness quantizes)
%     -> InputFraming        symbol boundary from a mod-M sample counter
%     -> FFT_M               dsphdl.FFT, length M, natural order, unnormalized
%     -> BinCounter          bin index q, feedback gate, partition valid
%     -> RomReal/RomImag     conj(fft(reference)) as two ROMs addressed by q
%     -> Multiply            product = fftM .* conjReferenceSpectrum
%     -> AccumSum/AccumDelay y[q] = product[q] + y[q-N], an N-deep comb
%     -> FFT_N               dsphdl.FFT, length N, on the last N accumulator
%                            outputs of each symbol
%     -> ScaleByM            1/M, an exact power-of-two shift
%     -> MagnitudeSquared    |.|^2
%     -> SpectrumSum         running sum of the N magnitudes of one symbol
%     -> PeakTracker         first-maximum bin and its value
%     -> Confidence          peak / max(spectrumSum, peak, floor)
%     -> TimestampFifo       sample index of each symbol's first sample,
%                            queued from the boundary to the decision
%
% resetIn clears the three counters and both streaming FFTs. The accumulator
% delay line and the peak tracker need no reset: the comb feedback is gated
% off for the first N bins of a symbol and the peak tracker re-initializes at
% bin 0, so neither can read pre-reset state once the counters restart.
%
% The accumulators are primitive blocks rather than MATLAB Function code so
% that every fixed-point output type, rounding mode, and overflow policy is
% an explicit block setting. Only counters and the argmax comparison, which
% never change word length, live in MATLAB Function blocks.
%
% SpreadingFactor and SamplesPerChip are compile-time, as frozen in
% docs/simulink-m2-interfaces.md: they set both FFT lengths and the ROM
% depth. A different configuration is a different generated model.

arguments
    options.SpreadingFactor (1,1) double {mustBeInteger} = 7
    options.SamplesPerChip (1,1) double {mustBeInteger} = 8
    options.DataType (1,1) string {mustBeMember(options.DataType, ...
        ["double", "fixed"])} = "double"
    options.WordLength (1,1) double {mustBeInteger, mustBePositive} = 16
    options.GuardBits (1,1) double {mustBeInteger, mustBeNonnegative} = 1
    options.PowerWordLength (1,1) double {mustBeInteger, mustBeNonnegative} = 0
    options.Rounding (1,1) string = "Floor"
    options.Overflow (1,1) string = "Saturate"
    options.Ranges struct = struct.empty
    options.IncludeVerificationTaps (1,1) logical = true
    options.ModelName (1,1) string = "lora_fft_correlator"
    options.OutputDirectory (1,1) string = lora_sim.generated_directory
    options.Save (1,1) logical = true
end

config = lora_phy.css_config(options.SpreadingFactor, options.SamplesPerChip);
n = config.symbolCount;
m = config.samplesPerSymbol;
modelName = options.ModelName;
modelPath = fullfile(options.OutputDirectory, modelName+".slx");

isFixed = options.DataType == "fixed";
if isFixed
    types = lora_sim.fixed_point_types(config.spreadingFactor, ...
        config.samplesPerChip, WordLength=options.WordLength, ...
        GuardBits=options.GuardBits, PowerWordLength=options.PowerWordLength, ...
        Rounding=options.Rounding, ...
        Overflow=options.Overflow, Ranges=options.Ranges);
else
    types = struct.empty;
end

if bdIsLoaded(modelName)
    set_param(modelName, Dirty="off");
    close_system(modelName, 0);
end
if isfile(modelPath)
    delete(modelPath);
end

new_system(modelName);
% A plain try/catch rather than onCleanup: clearing an onCleanup guard at the
% end of the function runs its action, which would close the very model the
% caller is about to simulate.
try
    info = populateModel(modelName, config, isFixed, types, options, modelPath);
catch err
    closeIfLoaded(modelName);
    rethrow(err);
end
end

function info = populateModel(modelName, config, isFixed, types, options, modelPath)
n = config.symbolCount;
m = config.samplesPerSymbol;

referenceChirp = lora_phy.reference_chirp(config);
conjReferenceSpectrum = conj(fft(referenceChirp));

workspace = get_param(modelName, "ModelWorkspace");
assignin(workspace, "SF", config.spreadingFactor);
assignin(workspace, "L", config.samplesPerChip);
assignin(workspace, "N", n);
assignin(workspace, "M", m);
assignin(workspace, "refConjReal", real(conjReferenceSpectrum));
assignin(workspace, "refConjImag", imag(conjReferenceSpectrum));

buildDut(modelName, n, m, isFixed, types, options.IncludeVerificationTaps);
buildHarness(modelName, isFixed, types, options.IncludeVerificationTaps);

set_param(modelName, ...
    SolverType="Fixed-step", Solver="FixedStepDiscrete", ...
    FixedStep="1", StartTime="0", StopTime="1000", ...
    SaveOutput="off", SaveTime="off", SaveFormat="Array", ...
    SignalLogging="off", ReturnWorkspaceOutputs="on");

% The reference ROM is quantized on purpose and the resulting error is
% measured by the regression, so the per-coefficient warning is noise.
set_param(modelName, ParameterPrecisionLossMsg="none");

if options.Save
    if ~isfolder(options.OutputDirectory)
        mkdir(options.OutputDirectory);
    end
    save_system(modelName, modelPath);
end

info = struct;
info.modelName = modelName;
info.modelPath = string(modelPath);
info.dutPath = modelName+"/DUT";
info.spreadingFactor = config.spreadingFactor;
info.samplesPerChip = config.samplesPerChip;
info.symbolCount = n;
info.samplesPerSymbol = m;
info.conjReferenceSpectrum = conjReferenceSpectrum;
info.dataType = options.DataType;
info.types = types;
info.includeVerificationTaps = options.IncludeVerificationTaps;
info.outputVariables = harnessVariables(options.IncludeVerificationTaps);
end

function closeIfLoaded(modelName)
if bdIsLoaded(modelName)
    set_param(modelName, Dirty="off");
    close_system(modelName, 0);
end
end

function names = harnessVariables(includeTaps)
%HARNESSVARIABLES DUT output order. Production outputs come first so that
% dropping the verification taps does not renumber anything before them.
arguments
    includeTaps (1,1) logical = true
end
names = [ ...
    "symbolIndex"; "symbolValid"; "confidence"; "peakMagnitudeSquared"; ...
    "spectrumSum"; "symbolBoundary"; ...
    "symbolSampleCount"; "timestampValid"; ...
    "binPower"; "binIndex"; "binValid"];
if includeTaps
    names = [names; ...
        "stageFftM"; "stageProduct"; "stagePartition"; "stageFftN"; ...
        "stageMagnitudeSquared"; ...
        "fftMValid"; "partitionValid"; "fftNValid"];
end
end

function buildHarness(modelName, isFixed, types, includeTaps)
%BUILDHARNESS Stimulus sources, input quantizer, and logging outside the DUT.

add_block("simulink/Sources/From Workspace", modelName+"/StimulusIq", ...
    Position=[40 100 160 140]);
set_param(modelName+"/StimulusIq", VariableName="stimulusIq", ...
    SampleTime="1", Interpolate="off", ...
    OutputAfterFinalValue="Setting to zero");

add_block("simulink/Sources/From Workspace", modelName+"/StimulusValid", ...
    Position=[40 170 160 210]);
set_param(modelName+"/StimulusValid", VariableName="stimulusValid", ...
    SampleTime="1", Interpolate="off", ...
    OutputAfterFinalValue="Setting to zero");

% Quantizing here rather than inside the DUT keeps the HDL boundary free of
% a floating-point conversion while producing identical numbers.
add_block("simulink/Signal Attributes/Data Type Conversion", ...
    modelName+"/QuantizeInput", Position=[200 100 260 140]);
applyType(modelName+"/QuantizeInput", isFixed, types, "input", "double");

add_block("simulink/Sources/From Workspace", modelName+"/StimulusReset", ...
    Position=[40 240 160 280]);
set_param(modelName+"/StimulusReset", VariableName="stimulusReset", ...
    SampleTime="1", Interpolate="off", ...
    OutputAfterFinalValue="Setting to zero");

add_block("simulink/Sources/From Workspace", ...
    modelName+"/StimulusResyncValid", Position=[40 310 160 350]);
set_param(modelName+"/StimulusResyncValid", ...
    VariableName="stimulusResyncValid", SampleTime="1", Interpolate="off", ...
    OutputAfterFinalValue="Setting to zero");

add_block("simulink/Sources/From Workspace", ...
    modelName+"/StimulusResyncSkip", Position=[40 380 160 420]);
set_param(modelName+"/StimulusResyncSkip", ...
    VariableName="stimulusResyncSkip", SampleTime="1", Interpolate="off", ...
    OutputAfterFinalValue="Holding final value");

add_line(modelName, "StimulusIq/1", "QuantizeInput/1", autorouting="on");
add_line(modelName, "QuantizeInput/1", "DUT/1", autorouting="on");
add_line(modelName, "StimulusValid/1", "DUT/2", autorouting="on");
add_line(modelName, "StimulusReset/1", "DUT/3", autorouting="on");
add_line(modelName, "StimulusResyncValid/1", "DUT/4", autorouting="on");
add_line(modelName, "StimulusResyncSkip/1", "DUT/5", autorouting="on");

names = harnessVariables(includeTaps);
for k = 1:numel(names)
    block = modelName+"/Log_"+names(k);
    top = 40+(k-1)*45;
    add_block("simulink/Sinks/To Workspace", block, ...
        Position=[520 top 640 top+35]);
    set_param(block, VariableName=names(k), SaveFormat="Array", ...
        SampleTime="-1", MaxDataPoints="inf");
    add_line(modelName, sprintf("DUT/%d", k), "Log_"+names(k)+"/1", ...
        autorouting="on");
end
end

function buildDut(modelName, n, m, isFixed, types, includeTaps)
%BUILDDUT Streaming correlator with production and verification outputs.

dut = modelName+"/DUT";
add_block("simulink/Ports & Subsystems/Subsystem", dut, ...
    Position=[260 90 420 760]);
delete_line(dut, "In1/1", "Out1/1");
delete_block(dut+"/In1");
delete_block(dut+"/Out1");

addInport(dut, "iqIn", 1, [40 100]);
addInport(dut, "validIn", 2, [40 170]);
addInport(dut, "resetIn", 3, [40 240]);
% Appended rather than inserted: ports 1..3 keep their numbers, so every
% existing regression and its stimulus stay valid unchanged.
addInport(dut, "resyncValid", 4, [40 310]);
addInport(dut, "resyncSkip", 5, [40 380]);

% Reset only has to clear the counters and the two FFTs. The accumulator
% delay line and the peak tracker are self-flushing: the comb feedback is
% gated off for the first N bins of a symbol and the peak tracker
% re-initializes at bin 0, so neither can read pre-reset state once the
% counters restart. TestSimulinkReset pins that property.

% The DUT input port carries the sample type directly. The quantizer lives
% in the harness: in hardware the ADC already delivers fixed-point samples,
% and a float-to-fixed conversion inside the DUT is rejected by checkhdl.

% --- symbol framing on the input stream -----------------------------------
add_block("simulink/User-Defined Functions/MATLAB Function", ...
    dut+"/InputFraming", Position=[170 160 300 220]);
lora_sim.set_function_script(dut+"/InputFraming", [
    "function [symbolBoundary, sampleCount, gatedValid] = fcn(validIn, resetIn, resyncValid, resyncSkip)"
    "%#codegen"
    "% First input sample of every M-sample symbol window, plus the"
    "% free-running PL sample counter that timestamps it."
    "%"
    "% Realignment works by dropping samples, not by loading a phase. The"
    "% streaming FFT frames on its own count of valid samples, so writing a"
    "% different value into a counter here would move the boundary flag and"
    "% the timestamps while leaving the FFT framing exactly where it was --"
    "% measured, and the symbol bins did not budge. Withholding s samples"
    "% from the processing chain shifts the whole window grid by s relative"
    "% to the stream, which is the thing that was wanted."
    "%"
    "% counter stays in lockstep with the FFT frame phase because both"
    "% advance only on gatedValid. sampleCount is deliberately not gated: it"
    "% timestamps the PL stream rather than the packet, and skipping samples"
    "% in it would break the monotonic count TDoA depends on."
    "%"
    "% Mechanism, not policy. Choosing s belongs to the front-end that owns"
    "% the detector; for a preamble at bin d the required advance is"
    "% chipsToBoundary*L = mod(-d, N)*L."
    "persistent counter samples skip"
    "if isempty(counter)"
    "    counter = uint32(0);"
    "    samples = uint64(0);"
    "    skip = uint32(0);"
    "end"
    "if resetIn"
    "    counter = uint32(0);"
    "    samples = uint64(0);"
    "    skip = uint32(0);"
    "end"
    "symbolBoundary = false;"
    "sampleCount = samples;"
    "gatedValid = false;"
    "if validIn"
    "    if resyncValid && skip == uint32(0)"
    "        skip = resyncSkip;"
    "    end"
    "    if skip > uint32(0)"
    "        skip = skip - uint32(1);"
    "    else"
    "        gatedValid = true;"
    "        symbolBoundary = counter == uint32(0);"
    "        if counter >= uint32(" + (m-1) + ")"
    "            counter = uint32(0);"
    "        else"
    "            counter = counter + uint32(1);"
    "        end"
    "    end"
    "    samples = samples + uint64(1);"
    "end"
    "end"]);
add_line(dut, "validIn/1", "InputFraming/1", autorouting="on");
add_line(dut, "resetIn/1", "InputFraming/2", autorouting="on");
add_line(dut, "resyncValid/1", "InputFraming/3", autorouting="on");
add_line(dut, "resyncSkip/1", "InputFraming/4", autorouting="on");

% --- M-point streaming FFT -------------------------------------------------
add_block("simulink/User-Defined Functions/MATLAB System", dut+"/FFT_M", ...
    Position=[200 80 300 140]);
set_param(dut+"/FFT_M", System="dsphdl.FFT");
set_param(dut+"/FFT_M", FFTLength=num2str(m), BitReversedOutput="off", ...
    BitReversedInput="off", Normalize="off", ResetInputPort="on");
if isFixed
    set_param(dut+"/FFT_M", RoundingMethod=char(types.rounding));
end
add_line(dut, "iqIn/1", "FFT_M/1", autorouting="on");
% Gated, not raw: this is the line that actually moves the window grid.
% Withholding samples here is what shifts the FFT framing relative to the
% incoming stream, and InputFraming's counter tracks it because both
% advance on the same signal.
add_line(dut, "InputFraming/3", "FFT_M/2", autorouting="on");
add_line(dut, "resetIn/1", "FFT_M/3", autorouting="on");

% --- frequency bin counter and partition control ---------------------------
add_block("simulink/User-Defined Functions/MATLAB Function", ...
    dut+"/BinCounter", Position=[350 70 480 160]);
lora_sim.set_function_script(dut+"/BinCounter", [
    "function [binIndex, feedbackGate, partitionValid] = fcn(fftValid, resetIn)"
    "%#codegen"
    "% Natural-order frequency bin index q of the M-point FFT output."
    "% feedbackGate opens the comb feedback once q >= N."
    "% partitionValid marks the final N accumulator outputs of a symbol."
    "persistent counter"
    "if isempty(counter)"
    "    counter = uint32(0);"
    "end"
    "if resetIn"
    "    counter = uint32(0);"
    "end"
    "binIndex = counter;"
    "feedbackGate = counter >= uint32(" + n + ");"
    "partitionValid = fftValid && counter >= uint32(" + (m-n) + ");"
    "if fftValid"
    "    if counter == uint32(" + (m-1) + ")"
    "        counter = uint32(0);"
    "    else"
    "        counter = counter + uint32(1);"
    "    end"
    "end"
    "end"]);
add_line(dut, "FFT_M/2", "BinCounter/1", autorouting="on");
add_line(dut, "resetIn/1", "BinCounter/2", autorouting="on");

% --- conjugated reference spectrum ROMs ------------------------------------
add_block("simulink/Lookup Tables/Direct Lookup Table (n-D)", ...
    dut+"/RomReal", Position=[520 60 620 110]);
set_param(dut+"/RomReal", NumberOfTableDimensions="1", ...
    Table="refConjReal", InputsSelectThisObjectFromTable="Element", ...
    TableIsInput="off", DiagnosticForOutOfRangeInput="Error");
add_block("simulink/Lookup Tables/Direct Lookup Table (n-D)", ...
    dut+"/RomImag", Position=[520 130 620 180]);
set_param(dut+"/RomImag", NumberOfTableDimensions="1", ...
    Table="refConjImag", InputsSelectThisObjectFromTable="Element", ...
    TableIsInput="off", DiagnosticForOutOfRangeInput="Error");
if isFixed
    set_param(dut+"/RomReal", TableDataTypeStr=char(types.reference.expression));
    set_param(dut+"/RomImag", TableDataTypeStr=char(types.reference.expression));
end
add_line(dut, "BinCounter/1", "RomReal/1", autorouting="on");
add_line(dut, "BinCounter/1", "RomImag/1", autorouting="on");

add_block("simulink/Math Operations/Real-Imag to Complex", ...
    dut+"/RomComplex", Position=[660 80 720 150]);
set_param(dut+"/RomComplex", Input="Real and imag");
add_line(dut, "RomReal/1", "RomComplex/1", autorouting="on");
add_line(dut, "RomImag/1", "RomComplex/2", autorouting="on");

% --- reference multiply ----------------------------------------------------
add_block("simulink/Math Operations/Product", dut+"/Multiply", ...
    Position=[770 80 820 140]);
set_param(dut+"/Multiply", Inputs="2", Multiplication="Element-wise(.*)");
applyType(dut+"/Multiply", isFixed, types, "product");
add_line(dut, "FFT_M/1", "Multiply/1", autorouting="on");
add_line(dut, "RomComplex/1", "Multiply/2", autorouting="on");

% --- frequency partition accumulation --------------------------------------
% y[q] = product[q] + gate(q) * y[q-N]. The delay line advances only on
% valid FFT output, so gaps in the stream cannot corrupt the alignment.
add_block("simulink/Math Operations/Sum", dut+"/AccumSum", ...
    Position=[880 80 920 140]);
set_param(dut+"/AccumSum", Inputs="++");
applyType(dut+"/AccumSum", isFixed, types, "accumulator");

add_block("simulink/Discrete/Delay", dut+"/AccumDelay", ...
    Position=[980 170 1040 230]);
set_param(dut+"/AccumDelay", DelayLength=num2str(n), ShowEnablePort="on", ...
    InitialCondition="complex(0,0)");

add_block("simulink/Sources/Constant", dut+"/AccumZero", ...
    Position=[820 260 870 290]);
set_param(dut+"/AccumZero", Value="complex(0,0)");
if isFixed
    set_param(dut+"/AccumZero", ...
        OutDataTypeStr=char(types.accumulator.expression));
else
    set_param(dut+"/AccumZero", OutDataTypeStr="double");
end

add_block("simulink/Signal Routing/Switch", dut+"/FeedbackGate", ...
    Position=[900 190 940 250]);
set_param(dut+"/FeedbackGate", Criteria="u2 > Threshold", Threshold="0.5");

add_line(dut, "Multiply/1", "AccumSum/1", autorouting="on");
add_line(dut, "FeedbackGate/1", "AccumSum/2", autorouting="on");
add_line(dut, "AccumSum/1", "AccumDelay/1", autorouting="on");
add_line(dut, "FFT_M/2", "AccumDelay/2", autorouting="on");
add_line(dut, "AccumDelay/1", "FeedbackGate/1", autorouting="on");
add_line(dut, "BinCounter/2", "FeedbackGate/2", autorouting="on");
add_line(dut, "AccumZero/1", "FeedbackGate/3", autorouting="on");

% --- N-point streaming FFT -------------------------------------------------
add_block("simulink/User-Defined Functions/MATLAB System", dut+"/FFT_N", ...
    Position=[1080 70 1180 140]);
set_param(dut+"/FFT_N", System="dsphdl.FFT");
set_param(dut+"/FFT_N", FFTLength=num2str(n), BitReversedOutput="off", ...
    BitReversedInput="off", Normalize="off", ResetInputPort="on");
if isFixed
    set_param(dut+"/FFT_N", RoundingMethod=char(types.rounding));
end
add_line(dut, "AccumSum/1", "FFT_N/1", autorouting="on");
add_line(dut, "BinCounter/3", "FFT_N/2", autorouting="on");
add_line(dut, "resetIn/1", "FFT_N/3", autorouting="on");

add_block("simulink/Math Operations/Gain", dut+"/ScaleByM", ...
    Position=[1240 80 1290 120]);
set_param(dut+"/ScaleByM", Gain="1/M");
applyType(dut+"/ScaleByM", isFixed, types, "fftN");
add_line(dut, "FFT_N/1", "ScaleByM/1", autorouting="on");

add_block("simulink/Math Operations/Math Function", ...
    dut+"/MagnitudeSquared", Position=[1340 80 1400 120]);
set_param(dut+"/MagnitudeSquared", Operator="magnitude^2");
% |X|^2 is kept at magnitudeWide for the peak search (#34); the spectrum sum
% and the confidence divider take the narrower magnitudeSquared, so the
% divider and the core latency do not change with PowerWordLength. With
% PowerWordLength equal to WordLength both conversions are identities.
applyType(dut+"/MagnitudeSquared", isFixed, types, "magnitudeWide");
add_line(dut, "ScaleByM/1", "MagnitudeSquared/1", autorouting="on");

add_block("simulink/Signal Attributes/Data Type Conversion", ...
    dut+"/MagNarrow", Position=[1440 140 1490 170]);
applyType(dut+"/MagNarrow", isFixed, types, "magnitudeSquared", "double");
add_line(dut, "MagnitudeSquared/1", "MagNarrow/1", autorouting="on");

% --- spectrum sum ----------------------------------------------------------
add_block("simulink/User-Defined Functions/MATLAB Function", ...
    dut+"/OutputBinCounter", Position=[1340 200 1470 270]);
lora_sim.set_function_script(dut+"/OutputBinCounter", [
    "function [binIndex, sumGate] = fcn(magValid, resetIn)"
    "%#codegen"
    "% Bin index within the N-point spectrum of one symbol."
    "persistent counter"
    "if isempty(counter)"
    "    counter = uint32(0);"
    "end"
    "if resetIn"
    "    counter = uint32(0);"
    "end"
    "binIndex = counter;"
    "sumGate = counter > uint32(0);"
    "if magValid"
    "    if counter == uint32(" + (n-1) + ")"
    "        counter = uint32(0);"
    "    else"
    "        counter = counter + uint32(1);"
    "    end"
    "end"
    "end"]);
add_line(dut, "FFT_N/2", "OutputBinCounter/1", autorouting="on");
add_line(dut, "resetIn/1", "OutputBinCounter/2", autorouting="on");

add_block("simulink/Math Operations/Sum", dut+"/SpectrumSum", ...
    Position=[1520 80 1560 140]);
set_param(dut+"/SpectrumSum", Inputs="++");
applyType(dut+"/SpectrumSum", isFixed, types, "spectrumSum");

add_block("simulink/Discrete/Delay", dut+"/SpectrumDelay", ...
    Position=[1620 300 1680 360]);
set_param(dut+"/SpectrumDelay", DelayLength="1", ShowEnablePort="on", ...
    InitialCondition="0");

add_block("simulink/Sources/Constant", dut+"/SpectrumZero", ...
    Position=[1450 400 1500 430]);
set_param(dut+"/SpectrumZero", Value="0");
if isFixed
    set_param(dut+"/SpectrumZero", ...
        OutDataTypeStr=char(types.spectrumSum.expression));
else
    set_param(dut+"/SpectrumZero", OutDataTypeStr="double");
end

add_block("simulink/Signal Routing/Switch", dut+"/SpectrumGate", ...
    Position=[1540 320 1580 380]);
set_param(dut+"/SpectrumGate", Criteria="u2 > Threshold", Threshold="0.5");

add_line(dut, "MagNarrow/1", "SpectrumSum/1", autorouting="on");
add_line(dut, "SpectrumGate/1", "SpectrumSum/2", autorouting="on");
add_line(dut, "SpectrumSum/1", "SpectrumDelay/1", autorouting="on");
add_line(dut, "FFT_N/2", "SpectrumDelay/2", autorouting="on");
add_line(dut, "SpectrumDelay/1", "SpectrumGate/1", autorouting="on");
add_line(dut, "OutputBinCounter/2", "SpectrumGate/2", autorouting="on");
add_line(dut, "SpectrumZero/1", "SpectrumGate/3", autorouting="on");

% --- peak, argmax, and confidence ------------------------------------------
add_block("simulink/User-Defined Functions/MATLAB Function", ...
    dut+"/PeakTracker", Position=[1620 60 1760 160]);
lora_sim.set_function_script(dut+"/PeakTracker", [
    "function [symbolIndex, peakValue, symbolValid] = fcn(magSq, magValid, binIndex)"
    "%#codegen"
    "% Strict > keeps the first maximum, matching MATLAB max() tie-breaking."
    "% No arithmetic here changes word length, so the fixed-point type"
    "% simply flows through from magSq."
    "persistent bestValue bestIndex"
    "if isempty(bestValue)"
    "    bestValue = zeros('like', magSq);"
    "    bestIndex = uint32(0);"
    "end"
    "symbolValid = false;"
    "if magValid"
    "    if binIndex == uint32(0)"
    "        bestValue = magSq;"
    "        bestIndex = binIndex;"
    "    elseif magSq > bestValue"
    "        bestValue = magSq;"
    "        bestIndex = binIndex;"
    "    end"
    "    symbolValid = binIndex == uint32(" + (n-1) + ");"
    "end"
    "symbolIndex = bestIndex;"
    "peakValue = bestValue;"
    "end"]);
add_line(dut, "MagnitudeSquared/1", "PeakTracker/1", autorouting="on");
add_line(dut, "FFT_N/2", "PeakTracker/2", autorouting="on");
add_line(dut, "OutputBinCounter/1", "PeakTracker/3", autorouting="on");

add_block("simulink/Sources/Constant", dut+"/SumFloor", ...
    Position=[1620 430 1680 460]);
if isFixed
    set_param(dut+"/SumFloor", ...
        Value=sprintf("2^%d", -types.spectrumSum.fractionLength), ...
        OutDataTypeStr=char(types.spectrumSum.expression));
else
    set_param(dut+"/SumFloor", Value="eps", OutDataTypeStr="double");
end

% max(spectrumSum, peak, floor). At the decision instant the running sum
% already contains the peak, so this equals MATLAB's max(sum, eps) exactly.
% On the intermediate cycles of a symbol it keeps the ratio at or below one,
% which is what stops the fixed-point divider from saturating on values that
% are never sampled.
add_block("simulink/Math Operations/MinMax", dut+"/GuardedSum", ...
    Position=[1740 400 1790 460]);
set_param(dut+"/GuardedSum", Function="max", Inputs="3");
add_line(dut, "SpectrumSum/1", "GuardedSum/1", autorouting="on");
add_block("simulink/Signal Attributes/Data Type Conversion", ...
    dut+"/PeakNarrow", Position=[1690 200 1730 230]);
applyType(dut+"/PeakNarrow", isFixed, types, "magnitudeSquared", "double");
add_line(dut, "PeakTracker/2", "PeakNarrow/1", autorouting="on");
add_line(dut, "PeakNarrow/1", "GuardedSum/2", autorouting="on");
add_line(dut, "SumFloor/1", "GuardedSum/3", autorouting="on");

add_block("simulink/Math Operations/Divide", dut+"/Confidence", ...
    Position=[1850 380 1900 440]);
set_param(dut+"/Confidence", Inputs="*/");
% HDL Coder accepts only Zero or Simplest rounding on a divide, and requires
% saturation. Confidence is a ratio of non-negative values, so rounding
% toward zero is identical to the Floor used everywhere else.
applyType(dut+"/Confidence", isFixed, types, "confidence", ...
    "Inherit: Inherit via internal rule", "Zero");
add_line(dut, "PeakNarrow/1", "Confidence/1", autorouting="on");
add_line(dut, "GuardedSum/1", "Confidence/2", autorouting="on");

% --- timestamp metadata ----------------------------------------------------
% The sample index of a symbol's first sample is captured at the boundary and
% queued until that symbol's decision emerges, which is hundreds to thousands
% of cycles later. A short circular buffer is enough because the pipeline
% holds only a couple of symbols at a time; a fixed delay line would have to
% be re-sized for every SF/L.
add_block("simulink/User-Defined Functions/MATLAB Function", ...
    dut+"/TimestampFifo", Position=[1620 520 1780 620]);
lora_sim.set_function_script(dut+"/TimestampFifo", [
    "function [symbolSampleCount, timestampValid] = fcn(sampleCount, symbolBoundary, symbolValid, resetIn)"
    "%#codegen"
    "persistent queue writeIndex readIndex"
    "depth = uint32(8);"
    "if isempty(queue)"
    "    queue = zeros(8, 1, 'uint64');"
    "    writeIndex = uint32(0);"
    "    readIndex = uint32(0);"
    "end"
    "if resetIn"
    "    queue = zeros(8, 1, 'uint64');"
    "    writeIndex = uint32(0);"
    "    readIndex = uint32(0);"
    "end"
    "if symbolBoundary"
    "    queue(writeIndex + uint32(1)) = sampleCount;"
    "    writeIndex = mod(writeIndex + uint32(1), depth);"
    "end"
    "symbolSampleCount = uint64(0);"
    "timestampValid = false;"
    "if symbolValid"
    "    symbolSampleCount = queue(readIndex + uint32(1));"
    "    readIndex = mod(readIndex + uint32(1), depth);"
    "    timestampValid = true;"
    "end"
    "end"]);
add_line(dut, "InputFraming/2", "TimestampFifo/1", autorouting="on");
add_line(dut, "InputFraming/1", "TimestampFifo/2", autorouting="on");
add_line(dut, "PeakTracker/3", "TimestampFifo/3", autorouting="on");
add_line(dut, "resetIn/1", "TimestampFifo/4", autorouting="on");

% --- outputs ---------------------------------------------------------------
addOutport(dut, "symbolIndex", 1, [1990 60], "PeakTracker/1");
addOutport(dut, "symbolValid", 2, [1990 110], "PeakTracker/3");
addOutport(dut, "confidence", 3, [1990 160], "Confidence/1");
addOutport(dut, "peakMagnitudeSquared", 4, [1990 210], "PeakTracker/2");
addOutport(dut, "spectrumSum", 5, [1990 260], "SpectrumSum/1");
addOutport(dut, "symbolBoundary", 6, [1990 310], "InputFraming/1");
addOutport(dut, "symbolSampleCount", 7, [1990 360], "TimestampFifo/1");
addOutport(dut, "timestampValid", 8, [1990 410], "TimestampFifo/2");
% The per-bin power stream the peak search sees (#36): |X|^2 at magnitudeWide,
% its bin within the symbol, and its valid -- the same three signals as the
% PeakTracker's inputs, so delay balancing keeps them aligned with each other.
% A preamble detector outside the core accumulates it over several windows.
addOutport(dut, "binPower", 9, [1990 440], "MagnitudeSquared/1");
addOutport(dut, "binIndex", 10, [1990 460], "OutputBinCounter/1");
addOutport(dut, "binValid", 11, [1990 470], "FFT_N/2");

if includeTaps
    addOutport(dut, "stageFftM", 12, [1990 480], "FFT_M/1");
    addOutport(dut, "stageProduct", 13, [1990 530], "Multiply/1");
    addOutport(dut, "stagePartition", 14, [1990 580], "AccumSum/1");
    addOutport(dut, "stageFftN", 15, [1990 630], "ScaleByM/1");
    addOutport(dut, "stageMagnitudeSquared", 16, [1990 680], ...
        "MagnitudeSquared/1");
    addOutport(dut, "fftMValid", 17, [1990 730], "FFT_M/2");
    addOutport(dut, "partitionValid", 18, [1990 780], "BinCounter/3");
    addOutport(dut, "fftNValid", 19, [1990 830], "FFT_N/2");
end

set_param(dut, TreatAsAtomicUnit="on");
end

function applyType(blockPath, isFixed, types, field, doubleType, rounding)
%APPLYTYPE Output type, rounding, and overflow policy for one boundary.
arguments
    blockPath (1,1) string
    isFixed (1,1) logical
    types
    field (1,1) string
    doubleType (1,1) string = "Inherit: Inherit via internal rule"
    rounding (1,1) string = ""
end
if ~isFixed
    set_param(blockPath, OutDataTypeStr=char(doubleType));
    return;
end
if rounding == ""
    rounding = types.rounding;
end
type = types.(field);
set_param(blockPath, OutDataTypeStr=char(type.expression), ...
    RndMeth=char(rounding));
if ismember("SaturateOnIntegerOverflow", fieldnames( ...
        get_param(blockPath, "DialogParameters")))
    if types.saturate
        set_param(blockPath, SaturateOnIntegerOverflow="on");
    else
        set_param(blockPath, SaturateOnIntegerOverflow="off");
    end
end
end

function addInport(parent, name, portNumber, position)
block = parent+"/"+name;
add_block("simulink/Sources/In1", block, ...
    Position=[position(1) position(2) position(1)+30 position(2)+20]);
set_param(block, Port=num2str(portNumber));
end

function addOutport(parent, name, portNumber, position, sourcePort)
block = parent+"/"+name;
add_block("simulink/Sinks/Out1", block, ...
    Position=[position(1) position(2) position(1)+30 position(2)+20]);
set_param(block, Port=num2str(portNumber));
add_line(parent, sourcePort, name+"/1", autorouting="on");
end
