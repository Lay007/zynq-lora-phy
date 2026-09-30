function types = fixed_point_types(spreadingFactor, samplesPerChip, options)
%FIXED_POINT_TYPES Explicit word lengths and policies for every DUT boundary.
%
% Integer bits come from measured range analysis over the committed golden
% vectors (LORA_SIM.STAGE_RANGES) plus GuardBits of headroom. The word
% length is the swept parameter, so the fraction length is whatever is left
% after the integer part.
%
% Chosen boundaries, matching the M2 plan:
%
%   input                complex ADC-facing sample
%   reference            conjugated reference-spectrum ROM
%   product              complex multiply result
%   accumulator          frequency partition accumulation
%   fftN                 second FFT after the exact 1/M scale
%   magnitudeSquared     |.|^2 as it enters the spectrum sum and confidence
%   magnitudeWide        |.|^2 as the peak search and the peak output see it
%   spectrumSum          confidence denominator
%   confidence           peak / spectrumSum
%
% The two FFT output widths are NOT chosen here. dsphdl.FFT runs
% unnormalized, so its output word length is its input word length plus
% log2(FFTLength) with the fraction length unchanged. That is recorded in
% the returned struct as a derived value.
%
% Policy for every chosen boundary is a single pair, applied uniformly so
% that a sweep changes one variable at a time:
%   rounding  = Floor      (truncation; cheapest in HDL, no bias correction)
%   overflow  = Saturate   (never wrap; a wrap would move the argmax)

arguments
    spreadingFactor (1,1) double
    samplesPerChip (1,1) double
    options.WordLength (1,1) double {mustBeInteger, mustBePositive} = 16
    options.GuardBits (1,1) double {mustBeInteger, mustBeNonnegative} = 1
    % Word length of |X|^2 where the argmax is taken (#34). 0 keeps it at
    % WordLength. The range-derived integer part is the same, so a longer
    % word only adds fraction bits: at 20 bits |X|^2 was ufix20_E1, which
    % spans ~30 dB of input amplitude and quantized weak symbols to 0/2 --
    % every tie went to bin 0.
    options.PowerWordLength (1,1) double {mustBeInteger, mustBeNonnegative} = 0
    options.Rounding (1,1) string = "Floor"
    options.Overflow (1,1) string = "Saturate"
    options.Ranges struct = struct.empty
end

% Range analysis normally comes from the committed synthetic acceptance
% vectors. The real-IQ regression supplies its own ranges instead, because
% the integer bits must follow the stimulus the design will actually see.
if isempty(options.Ranges)
    ranges = lora_sim.stage_ranges(spreadingFactor, samplesPerChip);
else
    ranges = options.Ranges;
end
wordLength = options.WordLength;
guard = options.GuardBits;

types = struct;
types.wordLength = wordLength;
types.guardBits = guard;
types.rounding = options.Rounding;
types.overflow = options.Overflow;
types.saturate = options.Overflow == "Saturate";
types.ranges = ranges;

types.input = signedType(ranges.input, wordLength, guard);
types.reference = signedType(ranges.conjReferenceSpectrum, wordLength, guard);
types.product = signedType(ranges.product, wordLength, guard);
types.accumulator = signedType(ranges.partition, wordLength, guard);
types.fftN = signedType(ranges.fftN, wordLength, guard);
types.magnitudeSquared = unsignedType(ranges.magnitudeSquared, wordLength, guard);
powerWordLength = options.PowerWordLength;
if powerWordLength == 0
    powerWordLength = wordLength;
end
types.magnitudeWide = unsignedType(ranges.magnitudeSquared, powerWordLength, guard);
types.spectrumSum = unsignedType(ranges.spectrumSum, wordLength, guard);
% Confidence is a ratio in (0,1]. One integer bit represents 1.0 exactly.
types.confidence = unsignedType(1, wordLength, guard);

% Derived, not chosen: dsphdl.FFT grows by log2(FFTLength) bits.
symbolCount = 2^spreadingFactor;
samplesPerSymbol = symbolCount*samplesPerChip;
types.fftMOutputWordLength = types.input.wordLength+log2(samplesPerSymbol);
types.fftNOutputWordLength = types.accumulator.wordLength+log2(symbolCount);
end

function type = signedType(maximumMagnitude, wordLength, guard)
integerBits = requiredIntegerBits(maximumMagnitude)+guard;
type = makeType(true, wordLength, integerBits+1);
end

function type = unsignedType(maximumMagnitude, wordLength, guard)
integerBits = requiredIntegerBits(maximumMagnitude)+guard;
type = makeType(false, wordLength, integerBits);
end

function bits = requiredIntegerBits(maximumMagnitude)
if maximumMagnitude <= 0
    bits = 0;
    return;
end
bits = max(0, ceil(log2(maximumMagnitude)));
end

function type = makeType(isSigned, wordLength, occupiedBits)
fractionLength = wordLength-occupiedBits;
type = struct;
type.signed = isSigned;
type.wordLength = wordLength;
type.fractionLength = fractionLength;
type.integerBits = occupiedBits;
type.expression = sprintf("fixdt(%d,%d,%d)", double(isSigned), ...
    wordLength, fractionLength);
if isSigned
    type.name = sprintf("sfix%d_En%d", wordLength, fractionLength);
else
    type.name = sprintf("ufix%d_En%d", wordLength, fractionLength);
end
end
