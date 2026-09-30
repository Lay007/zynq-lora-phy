[CmdletBinding()]
param(
    # The verified course boot set (from the board-evidence archive); required.
    [Parameter(Mandatory = $true)][string]$BaselineDir,
    # Kernel image for the selected board boot set; no sibling layout assumed.
    [Parameter(Mandatory = $true)][string]$KernelImage,
    [string]$Bitstream = '',
    [string]$Xsa = '',
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Bitstream)) {
    $Bitstream = Join-Path $PSScriptRoot '..\..\build\clg400-board\lora_receiver_clg400.runs\impl_1\system_top.bit'
}
if ([string]::IsNullOrWhiteSpace($Xsa)) {
    $Xsa = Join-Path $PSScriptRoot '..\..\build\clg400-board\lora_receiver_clg400.sdk\system_top.xsa'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot '..\..\build\clg400-board\boot-set-board-b'
}

$expectedBaseline = [ordered]@{
    'BOOT.bin'          = 'fc095df262c79578a236b21e67e58296e6f1cfe177779d5ee29854eae01f8368'
    'devicetree.dtb'    = 'b94c6495c7acfe8e65a72b6007da7fbbbd50b4483d5204fa01d613f71065f9d2'
    'uramdisk.image.gz' = '17c32edfb5eee20963f6f5feaca8547241d6ce102b51ebbffb03a758c9170471'
    'uEnv.txt'          = 'd0b02c2545cba4c8cda1d31173ef175990ff385b9f184b09684e897ec22ea193'
}
$expectedKernel = 'e675f26c955d76bccaacc14943619be44b45fcf06a52e9e6faebaada40f06f34'
$expectedBitstream = '8c39730d9f5d6f7732d0e143e010c2efebfd310d2f82454ad8656977e1a2cc17'
$expectedXsa = 'e497c61f2756cd992da4b3f58e9bd92986c4eb29e458a045742f18a8c553acfb'

function Resolve-ExistingFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Sha256([string]$Path, [string]$Expected, [string]$Label) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch: expected $Expected, got $actual ($Path)"
    }
    return $actual
}

$baselineRoot = (Resolve-Path -LiteralPath $BaselineDir).Path
$kernelPath = Resolve-ExistingFile $KernelImage 'Kernel image'
$bitstreamPath = Resolve-ExistingFile $Bitstream 'CLG400 bitstream'
$xsaPath = Resolve-ExistingFile $Xsa 'CLG400 XSA'
$outputPath = [System.IO.Path]::GetFullPath($OutputDir)

if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to overwrite an existing boot set: $outputPath"
}

$sourceFiles = [ordered]@{}
foreach ($entry in $expectedBaseline.GetEnumerator()) {
    $sourcePath = Resolve-ExistingFile (Join-Path $baselineRoot $entry.Key) "Baseline $($entry.Key)"
    [void](Assert-Sha256 $sourcePath $entry.Value "Baseline $($entry.Key)")
    $sourceFiles[$entry.Key] = $sourcePath
}
[void](Assert-Sha256 $kernelPath $expectedKernel 'Kernel image')
[void](Assert-Sha256 $bitstreamPath $expectedBitstream 'CLG400 bitstream')
[void](Assert-Sha256 $xsaPath $expectedXsa 'CLG400 XSA')

$uEnv = Get-Content -LiteralPath $sourceFiles['uEnv.txt'] -Raw
if ($uEnv -notmatch '(?m)^bitstream_image=system_top\.bit\s*$' -or
    $uEnv -notmatch '(?m)^kernel_image=uImage\s*$' -or
    $uEnv -notmatch '(?m)^loadbitstream=.*fpga loadb') {
    throw 'The validated uEnv.txt does not describe the expected SD cold-boot flow.'
}

[void](New-Item -ItemType Directory -Path $outputPath)
foreach ($name in $sourceFiles.Keys) {
    Copy-Item -LiteralPath $sourceFiles[$name] -Destination (Join-Path $outputPath $name)
}
Copy-Item -LiteralPath $kernelPath -Destination (Join-Path $outputPath 'uImage')
Copy-Item -LiteralPath $bitstreamPath -Destination (Join-Path $outputPath 'system_top.bit')

$copiedNames = @(
    'BOOT.bin',
    'system_top.bit',
    'uImage',
    'devicetree.dtb',
    'uramdisk.image.gz',
    'uEnv.txt'
)
$manifestFiles = foreach ($name in $copiedNames) {
    $path = Join-Path $outputPath $name
    $item = Get-Item -LiteralPath $path
    $source = if ($name -eq 'system_top.bit') {
        $bitstreamPath
    } elseif ($name -eq 'uImage') {
        $kernelPath
    } else {
        $sourceFiles[$name]
    }
    [ordered]@{
        file = $name
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        inherited_from = $source
    }
}

$manifest = [ordered]@{
    kind = 'development-sd-boot-set'
    status = 'UNQUALIFIED -- offline build only; not yet cold-booted on hardware'
    target = [ordered]@{
        board = 'ZynqSDR Z7020 CLG400 board B'
        part = 'xc7z020clg400-2'
        receiver = 'LoRa SF7/BW125, L=8, 1 Msps'
    }
    deployment_rules = @(
        'Use only a cloned or spare FAT32 SD card.',
        'Select SD boot mode and perform a cold power cycle.',
        'Do not overwrite QSPI.',
        'Do not hot-load this bitstream into a running course Linux image.'
    )
    files = $manifestFiles
    build_artifacts_not_copied_to_sd = @(
        [ordered]@{
            file = $xsaPath
            bytes = (Get-Item -LiteralPath $xsaPath).Length
            sha256 = $expectedXsa
        }
    )
    offline_evidence = [ordered]@{
        post_route_wns_ns = 0.064
        post_route_whs_ns = 0.031
        routing_errors = 0
        drc_errors = 0
        drc_critical_warnings = 0
        warning_boundary = 'Inherited ADI/generated-HDL BRAM asynchronous-control warnings and DSP48 pipeline recommendations remain; hardware qualification is open.'
    }
    provenance_note = 'The archived board-b-course set omitted uImage. The selected kernel is the byte-identical course sd_image copy and has the same SHA-256 as the original board image course_sd_boardB/uImage.'
    generated_utc = [DateTime]::UtcNow.ToString('o')
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$manifestText = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText((Join-Path $outputPath 'manifest.json'), $manifestText + "`n", $utf8NoBom)

$readme = @"
CLG400 LoRa receiver development SD boot set

STATUS: UNQUALIFIED. This directory was assembled and checksum-verified offline.
It has not yet been cold-booted on board B and is not hardware evidence.

Copy these six payload files to the root of a cloned or spare FAT32 SD card:
  BOOT.bin
  system_top.bit
  uImage
  devicetree.dtb
  uramdisk.image.gz
  uEnv.txt

Then select SD boot mode and cold-power-cycle board B with a serial console
attached. Do not write QSPI and do not hot-load system_top.bit into a running
Linux image. Keep the known-good course card unchanged.

Expected first identity read after Linux boots:
  devmem 0x79040004 32  ->  0x4c4f5241

The full provenance and SHA-256 values are in manifest.json.
"@
[System.IO.File]::WriteAllText((Join-Path $outputPath 'README_FIRST.txt'), $readme, $utf8NoBom)

Write-Output "Packaged unqualified board-B boot set: $outputPath"
$manifestFiles | ForEach-Object {
    Write-Output ("  {0,-20} {1,9} bytes  {2}" -f $_.file, $_.bytes, $_.sha256)
}
Write-Output 'No card, QSPI, or running board was modified.'
