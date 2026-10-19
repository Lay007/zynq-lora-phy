# Package one generated LoRa core as a reusable Vivado IP.
#
#   vivado -mode batch -source package_ip.tcl -tclargs \
#     <srcDir> <part> <outDir> <top> <name> <version> <displayName> <description>
#
# The generated Verilog is the input, never the output: this script reads
# fpga/generated/<target> and writes a self-contained IP directory. Nothing
# under fpga/generated is modified, so regenerating from the Simulink model
# stays the only way to change the RTL.
#
# The IP is packaged with its sources *copied* into the output directory, so
# the result can be handed to another project or another machine without the
# repository. That is the property issue #7 asks for.
#
# Emits key=value lines so the caller never has to parse a Vivado report.

if {$argc != 8} {
    puts "ERROR expected 8 arguments, got $argc"
    exit 1
}
# set_property ip_repo_paths consumes backslash escapes, so a Windows path
# handed to it verbatim silently loads a different, nonexistent directory and
# the catalog check then fails for the wrong reason. file normalize returns
# forward slashes on Windows and leaves an already-normalised path alone.
set srcDir      [file normalize [lindex $argv 0]]
set part        [lindex $argv 1]
set outDir      [file normalize [lindex $argv 2]]
set top         [lindex $argv 3]
set ipName      [lindex $argv 4]
set ipVersion   [lindex $argv 5]
set displayName [lindex $argv 6]
set description [lindex $argv 7]

set vendor   "zynq-lora-phy-positioning"
set library   "lora"
set taxonomy "/Communication_&_Networking"

set files [glob -nocomplain -directory $srcDir *.v]
if {[llength $files] == 0} {
    puts "ERROR no Verilog in $srcDir"
    exit 1
}

proc module_exists {files moduleName} {
    set pattern [format {(?m)^\s*module\s+%s(?:\s|\(|#)} $moduleName]
    foreach path $files {
        set fh [open $path r]
        set text [read $fh]
        close $fh
        if {[regexp $pattern $text]} {
            return 1
        }
    }
    return 0
}

if {![module_exists $files $top]} {
    puts "ERROR top module $top does not exist in $srcDir"
    exit 1
}

file mkdir $outDir
# A packaging project has to exist on disk: ipx::package_project reads the
# fileset from the project, and an in-memory project has nowhere to copy the
# imported sources to.
set projectDir [file join $outDir .package_project]
file delete -force $projectDir
create_project -force ip_package $projectDir -part $part
add_files -norecurse -fileset sources_1 $files
set_property top $top [get_filesets sources_1]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $outDir -vendor $vendor -library $library \
    -taxonomy $taxonomy -import_files -force

set core [ipx::current_core]
set_property name         $ipName      $core
set_property version      $ipVersion   $core
set_property display_name $displayName $core
set_property description  $description $core
set_property vendor_display_name "Zynq LoRa PHY and Positioning" $core
set_property company_url \
    "https://github.com/Lay007/zynq-lora-phy" $core
set_property supported_families {zynq Production} $core

# The core is generated, so record where from. Without this an unpacked IP
# is indistinguishable from hand-written RTL, and the "never edit generated
# HDL" rule in CONTRIBUTING quietly loses its subject.
set generatedFrom "HDL Coder output of model/simulink, target directory [file tail $srcDir]"
ipx::add_user_parameter GENERATED_FROM $core
set generatedParam [ipx::get_user_parameters GENERATED_FROM -of_objects $core]
set_property value $generatedFrom $generatedParam
set_property value_format string $generatedParam

set_property core_revision 1 $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core

close_project

# package_project names its first xgui file after the top module, before the
# core is renamed. Leaving both behind would ship an IP whose directory
# contradicts its own component.xml.
foreach stale [glob -nocomplain -directory [file join $outDir xgui] *.tcl] {
    if {[file tail $stale] ne "${ipName}_v[string map {. _} $ipVersion].tcl"} {
        file delete -force $stale
    }
}

set componentFile [file join $outDir component.xml]
if {![file exists $componentFile]} {
    puts "ERROR packaging produced no component.xml in $outDir"
    exit 1
}

# Prove the packaged IP is usable, not merely written: open a fresh project
# that knows nothing but the output directory, and instantiate the IP from
# it. A component.xml that cannot be instantiated is not a deliverable.
set verifyDir [file join $outDir .verify_project]
file delete -force $verifyDir
create_project -force ip_verify $verifyDir -part $part
set_property ip_repo_paths $outDir [current_project]
update_ip_catalog -rebuild

set vlnv "${vendor}:${library}:${ipName}:${ipVersion}"
set found [get_ipdefs -quiet $vlnv]
if {[llength $found] == 0} {
    puts "ERROR $vlnv is not in the catalog rebuilt from $outDir"
    exit 1
}

if {[catch {create_ip -vlnv $vlnv -module_name ${ipName}_verify} err]} {
    puts "ERROR create_ip failed for $vlnv: $err"
    exit 1
}
set portCount [llength [ipx::get_bus_interfaces -of_objects $found -quiet]]
close_project
file delete -force $verifyDir
file delete -force $projectDir
# Vivado drops a scratch directory beside the working directory it was
# launched from. Leaving it inside the IP would ship tool state as if it were
# part of the core.
file delete -force [file join $outDir .Xil]

set fh [open [file join $outDir package_report.txt] w]
puts $fh "vlnv=$vlnv"
puts $fh "part=$part"
puts $fh "top=$top"
puts $fh "source_directory=[file tail $srcDir]"
puts $fh "source_file_count=[llength $files]"
puts $fh "generated_from=$generatedFrom"
puts $fh "component_xml=[file tail $componentFile]"
close $fh

puts "PACKAGE_OK vlnv=$vlnv top=$top files=[llength $files] out=$outDir"
exit 0
