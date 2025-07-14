#!/usr/bin/env powershell
################################################################################
## Windows MSVC Build Environment Setup Script for App-Mesh
## This script installs all dependencies needed to build the C++/Go application
################################################################################

# Ensure script runs with admin privileges
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator. Exiting..."
    exit 1
}

# Set error handling
$ErrorActionPreference = "Stop"
Set-PSDebug -Trace 1

# Architecture detection and validation
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "arm64" }
    "AMD64" { "amd64" }
    default { 
        Write-Warning "Unknown architecture: $env:PROCESSOR_ARCHITECTURE. Defaulting to amd64"
        "amd64" 
    }
}

Write-Host "Detected architecture: $architecture" -ForegroundColor Green

# Create working directory
$ROOTDIR = "$env:TEMP\appmesh-build-setup"
$SRC_DIR = (Get-Location).Path
New-Item -ItemType Directory -Force -Path $ROOTDIR
cd $ROOTDIR

# Function to download files
function Save-File {
    param($url, $output)
    Write-Host "Downloading $url..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing
}

# Function to extract archives
function Expand-File {
    param($archive, $destination)
    Write-Host "Extracting $archive..." -ForegroundColor Yellow
    Expand-Archive -Path $archive -DestinationPath $destination -Force
}

# Optimized Perl finder with caching
$script:PerlPath = $null
function Find-Perl {
    if ($script:PerlPath) { return $script:PerlPath }
    
    $possiblePaths = @(
        "C:\vcpkg\downloads\tools\perl\*\perl\bin", # from vcpkg
        "C:\Perl*\bin",                             # stardand installation
        "C:\Strawberry\perl\bin",                   # Strawberry Perl
        "$env:ProgramFiles\Perl\bin",               # ActivePerl
        "${env:ProgramFiles(x86)}\Perl\bin"         # ActivePerl (x86)
    )
    
    foreach ($pathPattern in $possiblePaths) {
        $perlExe = Get-ChildItem -Path $pathPattern -Filter "perl.exe" -Recurse -ErrorAction SilentlyContinue | 
        Select-Object -First 1
        if ($perlExe) {
            $script:PerlPath = $perlExe.Directory.FullName
            Write-Host "Found Perl in: $script:PerlPath" -ForegroundColor Green
            return $script:PerlPath
        }
    }
    return $null
}

Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    refreshenv
}

Write-Host "Installing Visual Studio Build Tools..." -ForegroundColor Cyan
# Install Visual Studio 2022 Build Tools with C++ workload
choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621"

Write-Host "Installing CMake, Git, Wget, 7zip..." -ForegroundColor Cyan
choco install -y cmake
choco install -y git
choco install -y wget
choco install -y 7zip

# Refresh environment variables to ensure new tools are available
Write-Host "=== Refreshing environment variables ===" -ForegroundColor Cyan
refreshenv
$tools = @('cmake', 'git', 'wget', '7z')
foreach ($tool in $tools) {
    if (!(Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "Tool $tool not found in PATH. Please ensure it is installed correctly." -ForegroundColor Red
    }
}

Write-Host "=== Installing vcpkg Package Manager ===" -ForegroundColor Cyan
if (!(Test-Path "C:\vcpkg")) {
    git clone https://github.com/Microsoft/vcpkg.git C:\vcpkg
    C:\vcpkg\bootstrap-vcpkg.bat
    C:\vcpkg\vcpkg.exe integrate install
}
$env:VCPKG_ROOT = "C:\vcpkg"

Write-Host "=== Installing OpenSSL ===" -ForegroundColor Cyan
C:\vcpkg\vcpkg.exe install openssl:x64-windows

Write-Host "=== Installing Boost Libraries ===" -ForegroundColor Cyan
C:\vcpkg\vcpkg.exe install boost:x64-windows

Write-Host "=== Installing Crypto++ ===" -ForegroundColor Cyan
C:\vcpkg\vcpkg.exe install cryptopp:x64-windows

Write-Host "=== Installing cURL ===" -ForegroundColor Cyan
C:\vcpkg\vcpkg.exe install curl:x64-windows

Write-Host "=== Installing yaml-cpp ===" -ForegroundColor Cyan
C:\vcpkg\vcpkg.exe install yaml-cpp:x64-windows

Write-Host "=== Installing ACE Framework ===" -ForegroundColor Cyan
# ACE needs to be built from source on Windows
$aceUrl = "https://github.com/DOCGroup/ACE_TAO/releases/download/ACE%2BTAO-7_1_2/ACE-7.1.2.tar.gz"
Save-File $aceUrl ACE-7.1.2.tar.gz
tar zxvf ACE-7.1.2.tar.gz
$acePath = Get-ChildItem -Directory -Name "*ACE_wrappers*" | Select-Object -First 1
cd $acePath

# Add perl dir to PATH
$perlPath = Find-Perl
if ($perlPath) {
    $env:PATH = "$perlPath;$env:PATH"
}
else {
    Write-Host "No Perl installation found. Installing Perl..." -ForegroundColor Yellow
    choco install -y strawberryperl
    $perlPath = Find-Perl
    if (!$perlPath) {
        Write-Error "Failed to install and locate Perl"
        exit 1
    }
}

# Build ACE
$env:ACE_ROOT = "$PWD"
$env:PATH = "$env:ACE_ROOT\bin;$env:PATH"
$env:SSL_ROOT = "C:\vcpkg\installed\x64-windows"

# Create ACE config files
@"
#define ACE_HAS_STANDARD_CPP_LIBRARY 1
#define ACE_HAS_STDCPP_STL_INCLUDES 1
#define ACE_LACKS_PRAGMA_ONCE 1
#define ACE_HAS_SSL 1
#include "ace/config-win32.h"
"@ | Out-File -FilePath "$env:ACE_ROOT\ace\config.h" -Encoding ascii

# Creating default.features and re-run MPC to add support for building the ACE_SSL library
Write-Host "Creating default.features to enable SSL..." -ForegroundColor Yellow
Add-Content "$env:ACE_ROOT\bin\MakeProjectCreator\config\default.features" "ssl=1"
Add-Content "$env:ACE_ROOT\bin\MakeProjectCreator\config\default.features" "openssl11=1"
perl .\bin\mwc.pl -type vs2019 ACE.mwc

# Patch ACE project files to use VS2022 toolset
Write-Host "Patching ACE project files to use VS2022 toolset..." -ForegroundColor Yellow
Get-ChildItem -Path "$env:ACE_ROOT" -Recurse -Filter *.vcxproj | ForEach-Object {
    (Get-Content $_.FullName) -replace '<PlatformToolset>v142</PlatformToolset>', '<PlatformToolset>v143</PlatformToolset>' | Set-Content $_.FullName
}

# Build ACE using MSVC
cd "$env:ACE_ROOT"
& "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
& "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" ACE.sln /t:ACE /p:Configuration=Release /p:Platform=x64 /maxcpucount
& "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" ACE.sln /t:SSL /p:Configuration=Release /p:Platform=x64 /maxcpucount

# Install ACE libraries
New-Item -ItemType Directory -Force -Path "C:\local\include\"
Copy-Item -Recurse "$env:ACE_ROOT\ace" "C:\local\include\" -Force
New-Item -ItemType Directory -Force -Path "C:\local\lib\"
Copy-Item "$env:ACE_ROOT\lib\*" "C:\local\lib\" -Force
# List installed ACE libraries
Write-Host "Installed ACE libraries:" -ForegroundColor Green
Get-ChildItem -Path "C:\local\lib\" | ForEach-Object {
    Write-Host $_.Name -ForegroundColor White
}

cd $ROOTDIR

Write-Host "=== Installing nlohmann/json ===" -ForegroundColor Cyan
$jsonUrl = "https://github.com/nlohmann/json/releases/download/v3.11.3/include.zip"
Save-File $jsonUrl "json-include.zip"
Expand-File "json-include.zip" "json-temp"
New-Item -ItemType Directory -Force -Path "C:\local\include"
Copy-Item -Recurse "json-temp\include\nlohmann" "C:\local\include\" -Force

Write-Host "=== Installing Go ===" -ForegroundColor Cyan
if (!(Get-Command go -ErrorAction SilentlyContinue)) {
    $goVersion = "1.23.8"
    $goArch = if ($architecture -eq "arm64") { "arm64" } else { "amd64" }
    $goUrl = "https://go.dev/dl/go$goVersion.windows-$goArch.zip"
    Save-File $goUrl "go.zip"
    Expand-File "go.zip" "C:\"
    $env:PATH = "C:\go\bin;$env:PATH"
    [Environment]::SetEnvironmentVariable("PATH", $env:PATH, [EnvironmentVariableTarget]::Machine)
}

Write-Host "=== Installing Go Dependencies ===" -ForegroundColor Cyan
$env:GOBIN = "C:\local\bin"
New-Item -ItemType Directory -Force -Path $env:GOBIN

go env -w GOPROXY="https://goproxy.io,direct"
go env -w GOBIN="C:\local\bin"
go env -w GO111MODULE=on

go install github.com/cloudflare/cfssl/cmd/cfssl@latest
go install github.com/cloudflare/cfssl/cmd/cfssljson@latest
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest

Write-Host "=== Installing Header-only Libraries ===" -ForegroundColor Cyan
cd $ROOTDIR
# log4cpp
Save-File https://jaist.dl.sourceforge.net/project/log4cpp/log4cpp-1.1.x%20%28new%29/log4cpp-1.1/log4cpp-1.1.4.tar.gz log4cpp.tar.gz
tar -xvf log4cpp.tar.gz
cd log4cpp; mkdir build; cd build
# patch CMakeLists.txt to add cmake_minimum_required
$cmakeFile = "..\CMakeLists.txt"
if (Test-Path $cmakeFile) {
    $lines = Get-Content $cmakeFile
    if ($lines[0] -notmatch 'cmake_minimum_required') {
        # Insert the required line at the top
        $newLines = @("cmake_minimum_required(VERSION 3.10)") + $lines
        Set-Content $cmakeFile $newLines
        Write-Host "Patched: Inserted cmake_minimum_required at the top of $cmakeFile"
    }
    else {
        Write-Host "Already contains cmake_minimum_required"
    }
}
else {
    Write-Error "File not found: $cmakeFile"
}
cmake .. -Wno-dev -G "Visual Studio 17 2022" -A x64 -DCMAKE_INSTALL_PREFIX="C:/local"; cmake --build . --config Release; cmake --install . --config Release
cd $ROOTDIR

# Message Pack (use CMAKE_TOOLCHAIN_FILE to make sure can find boost)
git clone -b cpp_master --depth 1 https://github.com/msgpack/msgpack-c.git
cd msgpack-c; cmake . -G "Visual Studio 17 2022" -A x64 -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake -DCMAKE_INSTALL_PREFIX="C:/local"; cmake --install . --config Release
cd $ROOTDIR

# hashidsxx
git clone --depth=1 https://github.com/schoentoon/hashidsxx.git
Copy-Item -Recurse "hashidsxx" "C:\local\include\" -Force

# croncpp
git clone --depth=1 https://github.com/mariusbancila/croncpp.git
Copy-Item "croncpp\include\croncpp.h" "C:\local\include\" -Force

# wildcards
git clone --depth=1 https://github.com/laoshanxi/wildcards.git
Copy-Item -Recurse "wildcards\single_include" "C:\local\include\wildcards" -Force

# prometheus-cpp (header-only parts)
git clone --depth=1 https://github.com/jupp0r/prometheus-cpp.git
New-Item -ItemType Directory -Force -Path "C:\local\src\prometheus"
Copy-Item -Recurse "prometheus-cpp\core\src\*" "C:\local\src\prometheus\" -Force
Copy-Item -Recurse "prometheus-cpp\core\include\prometheus" "C:\local\include\" -Force

# Create prometheus export header
@"
#ifndef PROMETHEUS_CPP_CORE_EXPORT
#define PROMETHEUS_CPP_CORE_EXPORT
#endif
"@ | Out-File -FilePath "C:\local\include\prometheus\detail\core_export.h" -Encoding ascii

# jwt-cpp
git clone --depth=1 https://github.com/Thalhammer/jwt-cpp.git
Copy-Item -Recurse "jwt-cpp\include\jwt-cpp" "C:\local\include\" -Force

# Catch2
git clone --depth=1 -b v2.x https://github.com/catchorg/Catch2.git
Copy-Item "Catch2\single_include\catch2\catch.hpp" "C:\local\include\" -Force

Write-Host "=== Building LDAP-CPP ===" -ForegroundColor Cyan

Write-Host "=== Building QR Code Generator ===" -ForegroundColor Cyan
git clone --depth=1 https://github.com/nayuki/QR-Code-generator.git
cd "QR-Code-generator\cpp"
# Build using MSVC
cmd /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat`" && cl /EHsc /c qrcodegen.cpp && lib qrcodegen.obj /OUT:qrcodegencpp.lib"
Copy-Item "qrcodegen.hpp" "C:\local\include\" -Force
Copy-Item "qrcodegen.cpp" "C:\local\include\" -Force
Copy-Item "qrcodegencpp.lib" "C:\local\lib\" -Force
cd $ROOTDIR

Write-Host "=== Setting Environment Variables ===" -ForegroundColor Cyan
# Set permanent environment variables
$paths = @(
    "C:\local\bin",
    "C:\go\bin",
    "C:\vcpkg\installed\x64-windows\bin"
)

foreach ($path in $paths) {
    if ($env:PATH -notlike "*$path*") {
        $env:PATH = "$path;$env:PATH"
    }
}

[Environment]::SetEnvironmentVariable("PATH", $env:PATH, [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("VCPKG_ROOT", "C:\vcpkg", [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("ACE_ROOT", $env:ACE_ROOT, [EnvironmentVariableTarget]::Machine)

Write-Host "=== Creating CMake Toolchain File ===" -ForegroundColor Cyan
@"
# Windows MSVC Toolchain for App-Mesh
if(DEFINED CMAKE_TOOLCHAIN_FILE_INCLUDED)
    return()
endif()
set(CMAKE_TOOLCHAIN_FILE_INCLUDED TRUE)

set(CMAKE_SYSTEM_NAME Windows)

# Explicitly include vcpkg toolchain
include("C:/vcpkg/scripts/buildsystems/vcpkg.cmake")

# Set additional include and library paths
include_directories("C:/local/include")
link_directories("C:/local/lib")
list(PREPEND CMAKE_PREFIX_PATH "C:/local")

# C++ Standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimization flags
set(CMAKE_CXX_FLAGS_RELEASE_INIT "/O2 /Ob2 /DNDEBUG /MD")
set(CMAKE_C_FLAGS_RELEASE_INIT "/O2 /Ob2 /DNDEBUG /MD")

# Windows specific definitions
add_compile_definitions(
    WIN32
    _WIN32
    _WINDOWS
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

# Debugging output
message(STATUS "Toolchain CMAKE_PREFIX_PATH: ${CMAKE_PREFIX_PATH}")
"@ | Out-File -FilePath "C:\local\windows-toolchain.cmake" -Encoding utf8

Write-Host "=== Cleanup ===" -ForegroundColor Cyan
cd $SRC_DIR
Remove-Item -Recurse -Force $ROOTDIR -ErrorAction SilentlyContinue

# Final summary
Write-Host "=== Build Environment Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "To build your project, use:" -ForegroundColor Yellow
Write-Host "mkdir build && cd build" -ForegroundColor White
Write-Host "cmake .. -DCMAKE_TOOLCHAIN_FILE=C:\local\windows-toolchain.cmake -G Ninja" -ForegroundColor White
Write-Host "cmake --build ." -ForegroundColor White
Write-Host ""
Write-Host "Important paths:" -ForegroundColor Yellow
Write-Host "- Libraries: C:\local\lib" -ForegroundColor White
Write-Host "- Headers: C:\local\include" -ForegroundColor White
Write-Host "- Binaries: C:\local\bin" -ForegroundColor White
Write-Host "- vcpkg: C:\vcpkg" -ForegroundColor White
Write-Host ""
Write-Host "Please restart your terminal or run 'refreshenv' to use the new environment." -ForegroundColor Cyan