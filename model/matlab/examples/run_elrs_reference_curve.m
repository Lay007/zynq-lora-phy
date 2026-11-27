function curve = run_elrs_reference_curve(options)
%RUN_ELRS_REFERENCE_CURVE Detection and decoding of the reference receiver vs in-band SNR.
%   CURVE = RUN_ELRS_REFERENCE_CURVE() runs the stream receiver on packets in
%   the mode found in the ELRS recording (SF7, 500 kHz, preamble 7, sync 0x12,
%   CR 4/7) over white noise. The SNR is in the LoRa bandwidth, as LORA_IQ_SNR
%   and LORA_IQ_SET_SNR define it, so the curve compares directly with a
%   detector run on copies of a recording made by LORA_IQ_SET_SNR.
%
%   Each point is written to the CSV file as soon as it is done, so a long run
%   that is interrupted keeps its points.

arguments
    options.SnrDb (:,1) double = (-14:-4).'
    options.PacketsPerPoint (1,1) double {mustBeInteger, mustBePositive} = 100
    options.Output (1,1) string = ""
end

config = lora_phy.phy_config(7, 2, 3);
bandwidthHz = 500e3;
curve = table;
for point = 1:numel(options.SnrDb)
    snrBw = options.SnrDb(point);
    % the simulator sets the noise over Fs = samplesPerChip * BW
    current = lora_phy.simulate_lora_stream_performance( ...
        snrBw-10*log10(config.samplesPerChip), config, ...
        PacketsPerPoint=options.PacketsPerPoint, BandwidthHz=bandwidthHz, ...
        PreambleSymbols=7, PayloadLength=12, InterPacketGapSeconds=1e-3, ...
        RandomSeed=1000+round(10*(snrBw+50)));
    row = table(snrBw, current.Transmissions, current.AcquiredPackets, ...
        current.Transmissions-current.PacketErrors, ...
        current.FalseAlarmCandidates, current.FalseLoRaReceptions, ...
        'VariableNames', ["SNR_BW_dB", "Transmissions", "Detected", ...
        "Decoded", "FalseAlarmCandidates", "FalseLoRaReceptions"]);
    curve = [curve; row]; %#ok<AGROW>
    fprintf("SNR %5.1f dB in %.0f kHz: detected %d/%d, decoded %d\n", ...
        snrBw, bandwidthHz/1e3, row.Detected, row.Transmissions, row.Decoded);
    if options.Output ~= ""
        writetable(curve, options.Output);
    end
end
end
