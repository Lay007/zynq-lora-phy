SLStudio.Utils.RemoveHighlighting(get_param('lora_fft_correlator_gen', 'handle'));
SLStudio.Utils.RemoveHighlighting(get_param('gm_lora_fft_correlator_gen', 'handle'));
annotate_port('gm_lora_fft_correlator_gen/DUT/FFT_N', 0, 1, '');
annotate_port('lora_fft_correlator_gen/DUT/FFT_N', 0, 1, '');
annotate_port('gm_lora_fft_correlator_gen/DUT/FFT_N', 0, 1, '');
annotate_port('lora_fft_correlator_gen/DUT/FFT_N', 0, 1, '');
annotate_port('gm_lora_fft_correlator_gen/DUT/PeakTracker/PeakTracker_controlled/PeakTracker', 0, 1, '');
annotate_port('lora_fft_correlator_gen/DUT/PeakTracker', 0, 1, '');
