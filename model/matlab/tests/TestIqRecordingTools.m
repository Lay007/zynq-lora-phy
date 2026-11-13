classdef TestIqRecordingTools < matlab.unittest.TestCase
    % lora_iq_snr, lora_iq_set_snr and lora_iq_identify against synthetic
    % frequency-hopping recordings (lora_iq_synth) whose SNR and LoRa
    % parameters are known.

    methods (Test)
        function snrIsAccurateOverTheRange(testCase)
            for snr = [10 20 40]
                [z, t] = lora_iq_synth(snr);
                r = quiet_snr(z, Fs=8e6, Nfft=512, Passband=3.5e6);

                testCase.verifyNumElements(r.snr_db, numel(t.channels_hz), ...
                    sprintf("one dwell per hop at %d dB", snr));
                testCase.verifyEqual(sort(r.fc_hz), sort(t.channels_hz), "AbsTol", 50e3);
                testCase.verifyEqual(r.snr_db, snr * ones(size(r.snr_db)), "AbsTol", 0.2, ...
                    sprintf("SNR at %d dB", snr));
                testCase.verifyEqual(r.noise_dbfs_in_bw, t.noise_dbfs_in_bw, "AbsTol", 0.1);
            end
        end

        function defaultsAtFortyMegahertz(testCase)
            % the recorder's rate and the function's default STFT and passband
            [z, t] = lora_iq_synth(20, Fs=40e6, Channels=[-8 0 8]*1e6, PacketsPerDwell=2);
            r = quiet_snr(z, Fs=40e6);

            testCase.verifyNumElements(r.snr_db, 3);
            testCase.verifyEqual(r.snr_db, [20 20 20], "AbsTol", 0.2);
            testCase.verifyEqual(r.dur_ms, 1e3 * t.dwell_s * [1 1 1], "AbsTol", 2);
        end

        function noiseAloneGivesNoDwell(testCase)
            rs = RandStream("mt19937ar", "Seed", 3);
            z = 300 * complex(randn(rs, 1.6e6, 1), randn(rs, 1.6e6, 1));
            r = quiet_snr(z, Fs=8e6, Nfft=512, Passband=3.5e6);

            testCase.verifyEmpty(r.snr_db);
        end

        function setSnrReachesTheRequestedValue(testCase)
            z = lora_iq_synth(40);
            evalc("y = lora_iq_set_snr(z, 15, Fs=8e6);");
            r = quiet_snr(y, Fs=8e6, Nfft=512, Passband=3.5e6);

            testCase.verifyNumElements(r.snr_db, 5);
            testCase.verifyEqual(r.snr_db, 15 * ones(1, 5), "AbsTol", 0.3);
        end

        function identifiesAnImplicitHeaderPacket(testCase)
            % ELRS-like: SF7, 500 kHz, preamble 7, implicit header, 8 bytes, CR 4/7
            [z, t] = lora_iq_synth(10);
            id = quiet_identify(z);

            verify_common(testCase, id, t);
            testCase.verifyEqual(id.header, "implicit");
            testCase.verifyEqual(id.period_ms, 1e3 * t.period_s, "AbsTol", 0.2);
            testCase.verifyTrue(any(id.implicit.payload_bytes == t.payload_bytes & ...
                id.implicit.cr == "4/" + (4 + t.coding_rate) & id.implicit.crc == t.crc), ...
                "the true payload is among the candidates");
        end

        function confirmsAnImplicitPayloadByItsCrc(testCase)
            [z, t] = lora_iq_synth(15, SF=8, Preamble=8, SyncWord=hex2dec("34"), ...
                PayloadBytes=12, CodingRate=1, Crc=true, Period=25e-3);
            id = quiet_identify(z);

            verify_common(testCase, id, t);
            testCase.verifyEqual(id.confirmed, [12 1 1]);
        end

        function decodesAnExplicitHeader(testCase)
            [z, t] = lora_iq_synth(15, ExplicitHeader=true, Crc=true, PayloadBytes=10, ...
                CodingRate=2, Period=15e-3);
            id = quiet_identify(z);

            verify_common(testCase, id, t);
            testCase.verifyEqual(id.header, "explicit");
            testCase.verifyTrue(id.decoded.crcValid);
            testCase.verifyNumElements(id.decoded.payload, 10);
        end

        function separatesModesWithTheSameChirpRate(testCase)
            % SF9 at 250 kHz sweeps at the rate of SF11 at 500 kHz; the occupied
            % bandwidth decides
            [z, t] = lora_iq_synth(15, SF=9, BW=250e3, Preamble=10, PayloadBytes=6, ...
                CodingRate=4, Period=80e-3, PacketsPerDwell=2, Channels=[0 1.2e6]);
            id = quiet_identify(z);

            verify_common(testCase, id, t);
        end
    end
end

function r = quiet_snr(z, varargin)
evalc("r = lora_iq_snr(z, varargin{:}, Duration=1, Plot=false);");
end

function id = quiet_identify(z)
evalc("id = lora_iq_identify(z, Fs=8e6, Duration=1);");
end

function verify_common(testCase, id, t)
testCase.verifyEqual(id.bw_hz, t.bw_hz);
testCase.verifyEqual(id.sf, t.sf);
testCase.verifyEqual(id.preamble, t.preamble);
testCase.verifyEqual(id.sync_word, t.sync_word);
testCase.verifyEqual(id.payload_symbols, t.payload_symbols);
testCase.verifyEqual(id.airtime_ms, 1e3 * t.airtime_s, "AbsTol", 0.05);
testCase.verifyEqual(id.cfo_hz, 0, "AbsTol", t.bw_hz / 2^t.sf);
end
