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
# Set-PSDebug -Trace 1

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


Write-Host "=== Installing App Mesh ===" -ForegroundColor Cyan
# ACE needs to be built from source on Windows
$aceUrl = "https://github.com/laoshanxi/app-mesh/releases/download/2.1.2/appmesh_2.1.2_windows_x64.exe"
Save-File $aceUrl appmesh_2.1.2_windows_x64.exe
7z x .\appmesh_2.1.2_windows_x64.exe -oC:\local\appmesh

ls "C:\local\appmesh"
C:\local\appmesh\bin\nssm.exe install AppMeshService "C:\local\appmesh\bin\appsvc.exe"
C:\local\appmesh\bin\nssm.exe set AppMeshService Start SERVICE_AUTO_START
C:\local\appmesh\bin\nssm.exe start AppMeshService
sleep 3
ls "C:\local\appmesh"
& "C:\local\appmesh\bin\appc.exe" ls