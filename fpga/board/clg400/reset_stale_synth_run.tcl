# Reset a synth_1 run left stale by a hung Vivado launcher.
#
# Twice (the M6 and first M7 builds) build_bitstream.tcl hung right after
# synthesis without writing system_top.dcp: synth_1 reports its log with
# 0 errors, impl_1 is never created and three vivado.exe processes sit idle.
# The report_board_checkpoint.tcl path in the README needs the .dcp, so it
# does not apply. Stop the hung vivado.exe processes, run this script, then
# run build_bitstream.tcl again; it repeats synthesis from a clean run.
#
#   vivado -mode batch -nojournal -nolog -source fpga/board/clg400/reset_stale_synth_run.tcl

set repo_root [file normalize [file join [file dirname [info script]] "../../.."]]
set project_root [file join $repo_root fpga build clg400-board]
set xpr_path [file join $project_root "lora_receiver_clg400.xpr"]

open_project $xpr_path
puts "STATUS_BEFORE: [get_property STATUS [get_runs synth_1]]"
reset_run synth_1
puts "STATUS_AFTER: [get_property STATUS [get_runs synth_1]]"
close_project
