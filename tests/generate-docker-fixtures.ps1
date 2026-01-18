# Docker-based Fixture Generator for atop-reports.sh (PowerShell Edition)
# Generates golden master fixtures for all supported OS versions

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$FIXTURES_DIR = Join-Path $SCRIPT_DIR "fixtures"
New-Item -ItemType Directory -Force -Path $FIXTURES_DIR | Out-Null

# Configuration matrix
$FIXTURES = @(
    @{OS = "ubuntu:18.04"; Version = "2.3.0"; Name = "v2.3.0-ubuntu18.04.raw"}
    @{OS = "ubuntu:20.04"; Version = "2.4.0"; Name = "v2.4.0-ubuntu20.04.raw"}
    @{OS = "ubuntu:22.04"; Version = "2.7.1"; Name = "v2.7.1-ubuntu22.04.raw"}
    @{OS = "debian:10"; Version = "2.4.0"; Name = "v2.4.0-debian10.raw"}
    @{OS = "debian:11"; Version = "2.6.0"; Name = "v2.6.0-debian11.raw"}
    @{OS = "debian:12"; Version = "2.8.1"; Name = "v2.8.1-debian12.raw"}
    @{OS = "debian:13"; Version = "2.11.1"; Name = "v2.11.1-debian13.raw"}
)


function Generate-Fixture {
    param(
        [string]$OSImage,
        [string]$ExpectedVersion,
        [string]$FixtureName
    )
    
    $FixturePath = Join-Path $FIXTURES_DIR $FixtureName
    
    Write-Host "[*] Generating: $FixtureName (OS: $OSImage, atop: $ExpectedVersion)" -ForegroundColor Cyan
    
    if (Test-Path $FixturePath) {
        $Size = (Get-Item $FixturePath).Length
        $SizeKB = [math]::Round($Size / 1KB, 1)
        Write-Host "    [*] Fixture exists ($SizeKB KB)" -ForegroundColor Yellow
        return $true
    }
    
    Write-Host "    [*] Pulling image: $OSImage..." -ForegroundColor Gray
    try {
        docker pull $OSImage 2>&1 | Out-Null
    }
    catch {
        Write-Host "    [X] Failed to pull image" -ForegroundColor Red
        return $false
    }
    
    Write-Host "    [*] Capturing 15-second snapshot..." -ForegroundColor Gray
    
    $scriptBlock = @"
apt-get update -qq >/dev/null 2>&1
apt-get install -y atop >/dev/null 2>&1
atop -P PRG,PRC,PRM,PRD,DSK 1 15
"@
    
    try {
        $output = $scriptBlock | docker run --rm -i $OSImage bash 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [X] Docker failed with exit code $($LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
        
        $output | Out-File -FilePath $FixturePath -Encoding UTF8 -Force
        
        if ((Get-Item $FixturePath).Length -lt 100) {
            Write-Host "    [X] Generated fixture is too small" -ForegroundColor Red
            Remove-Item $FixturePath -Force
            return $false
        }
        
        $Size = (Get-Item $FixturePath).Length
        $SizeKB = [math]::Round($Size / 1KB, 1)
        $LineCount = @(Get-Content $FixturePath | Measure-Object -Line).Lines
        
        Write-Host "    [OK] $FixtureName ($SizeKB KB, $LineCount lines)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    [X] Failed: $_" -ForegroundColor Red
        return $false
    }
}

# Main execution
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  atop-reports.sh Fixture Generator (Docker Windows Edition)" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check Docker availability
try {
    $dockerVersion = docker --version
    Write-Host "[*] Docker: $dockerVersion" -ForegroundColor Cyan
}
catch {
    Write-Host "[X] Docker not available or not running" -ForegroundColor Red
    exit 1
}

Write-Host ""

$SuccessCount = 0
$FailCount = 0

foreach ($fixture in $FIXTURES) {
    if (Generate-Fixture $fixture.OS $fixture.Version $fixture.Name) {
        $SuccessCount++
    }
    else {
        $FailCount++
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Summary: $SuccessCount generated, $FailCount failed" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($SuccessCount -gt 0) {
    Write-Host "Fixtures:" -ForegroundColor Green
    Write-Host ""
    Get-ChildItem (Join-Path $FIXTURES_DIR "*.raw") -ErrorAction SilentlyContinue | ForEach-Object {
        $kb = [math]::Round($_.Length / 1KB, 1)
        Write-Host "  [OK] $($_.Name) ($kb KB)" -ForegroundColor Green
    }
}

Write-Host ""
if ($FailCount -eq 0) {
    Write-Host "SUCCESS: All fixtures generated!" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "FAILED: $FailCount fixtures failed" -ForegroundColor Red
    exit 1
}
