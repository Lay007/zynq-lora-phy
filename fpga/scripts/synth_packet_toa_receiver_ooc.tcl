# Out-of-context synthesis gate for the complete portable IQ-to-AXI receiver.
#
# vivado -mode batch -source synth_packet_toa_receiver_ooc.tcl -tclargs \
#   <repoRoot> <part> <periodNs> <outFile>

if {$argc != 4} {
    puts "ERROR expected 4 arguments, got $argc"
    exit 1
}
set repoRoot [file normalize [lindex $argv 0]]
set part     [lindex $argv 1]
set period   [lindex $argv 2]
set outFile  [file normalize [lindex $argv 3]]

set fftDir [file join $repoRoot fpga generated fft-correlator-fixed lora_fft_correlator_gen]
set blindFile [file join $repoRoot fpga generated blind-detector lora_blind_detector_gen lora_blind_BlindDetector.v]
set toaFile [file join $repoRoot fpga generated toa-interpolator lora_toa_interpolator_gen lora_toa_ToaInterpolator.v]
set wrapperDir [file join $repoRoot fpga wrappers]
set files [concat [glob -nocomplain -directory $fftDir *.v] [list \
    $blindFile \
    $toaFile \
    [file join $wrapperDir fft_correlator_route_top.v] \
    [file join $wrapperDir lora_detector_timestamp_align.v] \
    [file join $wrapperDir lora_detector_timestamp_path.v] \
    [file join $wrapperDir lora_fft_detector_timestamp_path.v] \
    [file join $wrapperDir lora_preamble_accumulator.v] \
    [file join $wrapperDir lora_iq_history_buffer.v] \
    [file join $wrapperDir lora_reference_chirp_rom.v] \
    [file join $wrapperDir lora_matched_filter_mac.v] \
    [file join $wrapperDir lora_peak_triplet_capture.v] \
    [file join $wrapperDir lora_matched_filter_search.v] \
    [file join $wrapperDir lora_joint_chirp_grid_controller.v] \
    [file join $wrapperDir lora_symbol_grid_resync.v] \
    [file join $wrapperDir lora_timestamp_metadata_join.v] \
    [file join $wrapperDir lora_axi_lite_status.v] \
    [file join $wrapperDir lora_packet_toa_receiver_top.v]]]

foreach path $files {
    if {![file exists $path]} {
        puts "ERROR missing receiver source: $path"
        exit 1
    }
}
file mkdir [file dirname $outFile]

create_project -in_memory -part $part
add_files $files
set_property verilog_define LORA_NAMESPACED_GENERATED [current_fileset]
set_property top lora_packet_toa_receiver_top [current_fileset]

set xdc [file join [file dirname $outFile] receiver_ooc_probe.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
close $fh
read_xdc $xdc

cd $repoRoot
synth_design -top lora_packet_toa_receiver_top -part $part \
    -mode out_of_context -flatten_hierarchy rebuilt

set util [report_utilization -return_string]
proc cell_count {report row} {
    set pattern "\\|\\s+${row}\\S*\\s+\\|\\s+(\\d+)\\s+\\|"
    if {[regexp $pattern $report -> value]} {
        return $value
    }
    return -1
}
set luts  [cell_count $util "Slice LUTs"]
set regs  [cell_count $util "Slice Registers"]
set bram  [cell_count $util "Block RAM Tile"]
set dsp   [cell_count $util "DSPs"]
set carry [cell_count $util "CARRY4"]

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
set wns nan
set achieved nan
set fmax nan
if {[llength $paths] > 0} {
    set candidate [get_property SLACK [lindex $paths 0]]
    if {[string is double -strict $candidate]} {
        set wns $candidate
        set achieved [expr {$period - $wns}]
        if {$achieved > 0} {
            set fmax [expr {1000.0 / $achieved}]
        }
    }
}

report_utilization -hierarchical -file [file join [file dirname $outFile] receiver-utilization-hierarchical.rpt]
report_timing_summary -file [file join [file dirname $outFile] receiver-timing-summary.rpt]

set fh [open $outFile w]
puts $fh "part=$part"
puts $fh "top=lora_packet_toa_receiver_top"
puts $fh "probe_period_ns=$period"
puts $fh "luts=$luts"
puts $fh "registers=$regs"
puts $fh "bram_tiles=$bram"
puts $fh "dsps=$dsp"
puts $fh "carry4=$carry"
puts $fh "wns_ns=$wns"
puts $fh "achieved_period_ns=$achieved"
puts $fh "fmax_mhz=$fmax"
close $fh

puts "SYNTH_OK top=lora_packet_toa_receiver_top part=$part luts=$luts regs=$regs bram=$bram dsp=$dsp fmax=$fmax"
exit 0
