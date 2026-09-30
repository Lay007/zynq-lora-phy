set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir "../../.."]]

if {[info exists ::env(ZYNQ_SDR_COURSE_ROOT)]} {
  set course_root [file normalize $::env(ZYNQ_SDR_COURSE_ROOT)]
} else {
  set course_root [file normalize [file join $repo_root "../zynq-sdr-course"]]
}

set course_shell_dir [file join $course_root hardware 7020_ad936x_sdr hdl course_bpsk_fmcomms2_zc702]
set vendor_dir [file join $course_root hardware 7020_ad936x_sdr hdl adi_fmcomms2_reference]
set axi_gpreg_dir [file join $vendor_dir library axi_gpreg]

set required_inputs [list \
  [file join $course_shell_dir vendor_system_bd_clg400.tcl] \
  [file join $course_shell_dir system_top.v] \
  [file join $course_shell_dir system_constr.xdc] \
  [file join $axi_gpreg_dir component.xml] \
  [file join $vendor_dir projects scripts adi_env.tcl]]
foreach required_file $required_inputs {
  if {![file exists $required_file]} {
    puts "ERROR: missing pinned course/vendor input: $required_file"
    puts "Set ZYNQ_SDR_COURSE_ROOT to the zynq-sdr-course checkout if needed."
    exit 2
  }
}

# Keep custom module references in the top-level synthesis run.
set ADI_USE_OOC_SYNTHESIS 0
set ADI_USE_INCR_COMP 0
source [file join $vendor_dir projects scripts adi_env.tcl]
source [file join $vendor_dir projects scripts adi_board.tcl]
source [file join $vendor_dir projects scripts adi_project_xilinx.tcl]

set required_vivado_version "2021.1"
if {[string compare [version -short] $required_vivado_version] != 0} {
  puts "ERROR: Vivado version mismatch; expected $required_vivado_version, got [version -short]."
  exit 2
}

set project_name "lora_receiver_clg400"
set project_root [file normalize [file join $repo_root fpga build clg400-board]]
set expected_root [file normalize [file join $repo_root fpga build]]
set project_system_dir [file join $project_root "${project_name}.srcs/sources_1/bd/system"]

# This is the only destructive step: remove exactly the ignored generated
# project directory after checking it remains below fpga/build.
if {[string first "${expected_root}/" "${project_root}/"] != 0} {
  puts "ERROR: refusing to replace project outside $expected_root: $project_root"
  exit 2
}
if {[file exists $project_root]} {
  file delete -force $project_root
}
file mkdir $project_root
create_project $project_name $project_root -part xc7z020clg400-2 -force

set lib_dirs $ad_hdl_dir/library
if {$ad_hdl_dir ne $ad_ghdl_dir} {
  lappend lib_dirs $ad_ghdl_dir/library
}
set_property ip_repo_paths $lib_dirs [current_fileset]
update_ip_catalog
if {![info exists ::env(ADI_DISABLE_MESSAGE_SUPPRESION)]} {
  source [file join $vendor_dir projects scripts adi_xilinx_msg.tcl]
}
set_param messaging.defaultLimit 2000

set fft_dir [file join $repo_root fpga generated fft-correlator-fixed lora_fft_correlator_gen]
set source_files [concat [lsort [glob -nocomplain [file join $fft_dir *.v]]] [list \
  [file join $repo_root fpga generated blind-detector lora_blind_detector_gen lora_blind_BlindDetector.v] \
  [file join $repo_root fpga generated toa-interpolator lora_toa_interpolator_gen lora_toa_ToaInterpolator.v] \
  [file join $repo_root fpga wrappers fft_correlator_route_top.v] \
  [file join $repo_root fpga wrappers lora_detector_timestamp_align.v] \
  [file join $repo_root fpga wrappers lora_detector_timestamp_path.v] \
  [file join $repo_root fpga wrappers lora_cfo_derotator.v] \
  [file join $repo_root fpga wrappers lora_fft_detector_timestamp_path.v] \
  [file join $repo_root fpga wrappers lora_iq_history_buffer.v] \
  [file join $repo_root fpga wrappers lora_reference_chirp_rom.v] \
  [file join $repo_root fpga wrappers lora_matched_filter_mac.v] \
  [file join $repo_root fpga wrappers lora_peak_triplet_capture.v] \
  [file join $repo_root fpga wrappers lora_matched_filter_search.v] \
  [file join $repo_root fpga wrappers lora_joint_chirp_grid_controller.v] \
  [file join $repo_root fpga wrappers lora_symbol_grid_resync.v] \
  [file join $repo_root fpga wrappers lora_timestamp_metadata_join.v] \
  [file join $repo_root fpga wrappers lora_axi_lite_status.v] \
  [file join $repo_root fpga wrappers lora_async_sample_fifo.v] \
  [file join $repo_root fpga wrappers lora_packet_toa_receiver_top.v] \
  [file join $script_dir lora_symbol_trace_buffer.v] \
  [file join $script_dir lora_decision_history_buffer.v] \
  [file join $script_dir lora_clg400_gpreg_bridge.v] \
  [file join $repo_root fpga rom lora_sf7_l8_reference_q10.mem] \
  [file join $vendor_dir library common ad_iobuf.v] \
  [file join $course_shell_dir system_top.v]]]

foreach src $source_files {
  if {![file exists $src]} {
    puts "ERROR: missing LoRa board source: $src"
    exit 2
  }
  add_files -norecurse -fileset sources_1 $src
}
set_property verilog_define LORA_NAMESPACED_GENERATED [current_fileset]

add_files -norecurse -fileset constrs_1 [file join $course_shell_dir system_constr.xdc]

create_bd_design "system"
source [file join $script_dir system_bd.tcl]
save_bd_design
validate_bd_design
set_property synth_checkpoint_mode None [get_files "$project_system_dir/system.bd"]
generate_target {synthesis implementation} [get_files "$project_system_dir/system.bd"]
make_wrapper -files [get_files "$project_system_dir/system.bd"] -top
import_files -force -norecurse -fileset sources_1 [file join $project_system_dir hdl system_wrapper.v]

set_property top system_top [current_fileset]
update_compile_order -fileset sources_1
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $script_dir lora_overlay_timing.xdc] [get_runs impl_1]

puts "Project created: [file join $project_root ${project_name}.xpr]"
puts "Next: source [file join $script_dir build_bitstream.tcl]"
