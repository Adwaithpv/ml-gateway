<#
.SYNOPSIS
    PowerShell build and management script for the ML Gateway project (Windows equivalent of Makefile).
.DESCRIPTION
    This script replaces the 'make' utility on Windows systems, allowing you to train models,
    build Docker images, deploy resources to Kubernetes, and test the ML Gateway.
.PARAMETER Target
    The task to run. Supported targets: all, train, build, deploy, test, retrain, clean. Defaults to 'all'.
.EXAMPLE
    .\run.ps1 train
.EXAMPLE
    .\run.ps1 build
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("all", "setup", "local", "stop", "train", "build", "deploy", "test", "retrain", "clean")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"

# Helper to print styled status banners
function Show-Banner {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n=== $Message ===" -ForegroundColor $Color
}

# Helper to dynamically find Minikube path
function Get-MinikubePath {
    if (Get-Command "minikube" -ErrorAction SilentlyContinue) {
        return "minikube"
    }
    if (Test-Path "D:\Minikube\minikube.exe") {
        return "D:\Minikube\minikube.exe"
    }
    return $null
}

# Helper to check if a command/executable exists in PATH or has Minikube fallback
function Test-CommandExists {
    param([string]$Name)
    if ([bool](Get-Command $Name -ErrorAction SilentlyContinue)) {
        return $true
    }
    if ($Name -eq "kubectl") {
        return [bool](Get-MinikubePath)
    }
    return $false
}

# Helper to invoke kubectl (either standalone or via Minikube fallback)
function Invoke-Kubectl {
    param([string[]]$Arguments)
    
    if (Get-Command "kubectl" -ErrorAction SilentlyContinue) {
        & kubectl $Arguments
    } else {
        $minikube = Get-MinikubePath
        if ($minikube) {
            $allArgs = @("kubectl", "--") + $Arguments
            & $minikube $allArgs
        } else {
            Write-Error "Kubectl is not available. Please install kubectl or minikube."
        }
    }
}

# Resolve Python executable
function Get-PythonPath {
    if (Test-Path "$PSScriptRoot\.venv\Scripts\python.exe") {
        return (Resolve-Path "$PSScriptRoot\.venv\Scripts\python.exe").Path
    }
    return "python"
}

# Target: train
function Run-Train {
    Show-Banner "Target: train" "Yellow"
    
    # Check if spam.csv exists, generate if needed
    $dataDir = Join-Path $PSScriptRoot "data"
    $csvPath = Join-Path $dataDir "spam.csv"
    $rawPath = Join-Path $dataDir "SMSSpamCollection"
    
    if (-not (Test-Path $csvPath)) {
        if (Test-Path $rawPath) {
            Write-Host "data/spam.csv not found. Automatically converting data/SMSSpamCollection to CSV format..." -ForegroundColor Gray
            try {
                # Convert tab-separated SMSSpamCollection to comma-separated CSV with headers label,text
                Import-Csv -Delimiter "`t" -Path $rawPath -Header "label", "text" | 
                    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                Write-Host "Successfully generated $csvPath" -ForegroundColor Green
            } catch {
                Write-Error "Failed to convert SMSSpamCollection to spam.csv: $_"
            }
        } else {
            Write-Error "Data file not found at $rawPath or $csvPath. Please make sure the dataset is available."
        }
    }

    $python = Get-PythonPath
    Write-Host "Using Python: $python" -ForegroundColor Gray

    $services = @("small", "medium", "large")
    foreach ($service in $services) {
        Show-Banner "Training $service model..." "Cyan"
        Push-Location "services/$service"
        try {
            & $python train.py
        } finally {
            Pop-Location
        }
    }
    Write-Host "`nAll models trained successfully!" -ForegroundColor Green
}

# Target: build
function Run-Build {
    Show-Banner "Target: build" "Yellow"
    
    # Check if spam.csv exists
    $dataDir = Join-Path $PSScriptRoot "data"
    $csvPath = Join-Path $dataDir "spam.csv"
    if (-not (Test-Path $csvPath)) {
        Write-Error "Dataset not found at $csvPath. Run '.\run.ps1 train' first."
        return
    }

    # Temporarily copy dataset to build contexts
    Write-Host "Staging dataset to service build contexts..." -ForegroundColor Gray
    Copy-Item $csvPath "services/small/spam.csv" -Force
    Copy-Item $csvPath "services/medium/spam.csv" -Force
    Copy-Item $csvPath "services/large/spam.csv" -Force
    
    try {
        Write-Host "Building services/small..." -ForegroundColor Cyan
        docker build -t ml-gateway/small:v1 services/small/
        
        Write-Host "Building services/medium..." -ForegroundColor Cyan
        docker build -t ml-gateway/medium:v1 services/medium/
        
        Write-Host "Building services/large..." -ForegroundColor Cyan
        docker build -t ml-gateway/large:v1 services/large/
        
        Write-Host "Building gateway..." -ForegroundColor Cyan
        docker build -t ml-gateway/gateway:v1 gateway/
    } finally {
        # Clean up temporary dataset copies
        Write-Host "Cleaning up service build contexts..." -ForegroundColor Gray
        Remove-Item "services/small/spam.csv" -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-Item "services/medium/spam.csv" -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-Item "services/large/spam.csv" -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    Write-Host "`nAll Docker images built successfully!" -ForegroundColor Green
}

# Target: deploy
function Run-Deploy {
    Show-Banner "Target: deploy" "Yellow"
    if (Test-CommandExists "kubectl") {
        Write-Host "Applying Kubernetes manifests..." -ForegroundColor Cyan
        Invoke-Kubectl @("apply", "-f", "k8s/")
    } else {
        Write-Warning "Neither kubectl nor minikube is installed/active. Skipping Kubernetes deployment."
        Write-Host "To run the services locally using Python instead, run: .\run.ps1 local" -ForegroundColor Yellow
    }
}

# Target: test
function Run-Test {
    Show-Banner "Target: test" "Yellow"
    
    # 1. Run gateway unit tests
    Write-Host "Running gateway unit tests..." -ForegroundColor Cyan
    $python = Get-PythonPath
    & $python -m unittest tests/test_gateway.py
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Gateway unit tests failed! Aborting dynamic endpoint testing."
        return
    }
    Write-Host "Gateway unit tests passed successfully!`n" -ForegroundColor Green
    
    # Dynamic port detection (prefer 8000 if active, otherwise fallback to 30080)
    $port = 8000
    $tcp = New-Object System.Net.Sockets.TcpClient
    $localStarted = $false
    
    try {
        $tcp.Connect("localhost", 8000)
        $tcp.Close()
        Write-Host "Detected active gateway on port 8000." -ForegroundColor Gray
    } catch {
        # Port 8000 is not active. Check if we should spin up local services temporarily for testing!
        Write-Host "Gateway on port 8000 is not active." -ForegroundColor Gray
        Write-Host "Spinning up local services temporarily for self-contained testing..." -ForegroundColor Cyan
        Run-Local
        $localStarted = $true
        
        Write-Host "Waiting 10 seconds for services to boot up..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
        
        # Double check if port 8000 is now active
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("localhost", 8000)
            $tcp.Close()
            Write-Host "Successfully booted local gateway on port 8000." -ForegroundColor Green
        } catch {
            Write-Warning "Local gateway failed to boot on port 8000. Falling back to port 30080 (Kubernetes NodePort)..."
            $port = 30080
        }
    }

    Write-Host "Testing gateway endpoints on port $port..." -ForegroundColor Cyan
    $classifyUrl = "http://localhost:$port/classify"
    $healthUrl = "http://localhost:$port/health"
    $modelsUrl = "http://localhost:$port/models"
    
    # 1. Test Classify
    try {
        Write-Host "1. Sending test request to /classify..." -ForegroundColor Gray
        $body = @{
            text = "Congratulations! You won a free prize"
            latency_budget_ms = 100
        } | ConvertTo-Json
        
        $response = Invoke-RestMethod -Uri $classifyUrl -Method Post -ContentType "application/json" -Body $body
        Write-Host "Response from /classify:" -ForegroundColor Green
        $response | ConvertTo-Json | Write-Host
    } catch {
        Write-Warning "Failed to call /classify: $_"
    }
    
    # 2. Test Health
    try {
        Write-Host "`n2. Checking gateway health..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri $healthUrl
        Write-Host "Response from /health:" -ForegroundColor Green
        $response | ConvertTo-Json | Write-Host
    } catch {
        Write-Warning "Failed to call /health: $_"
    }
    
    # 3. Test Models Health Status
    try {
        Write-Host "`n3. Checking downstream models health status..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri $modelsUrl
        Write-Host "Response from /models:" -ForegroundColor Green
        $response | ConvertTo-Json | Write-Host
    } catch {
        Write-Warning "Failed to call /models: $_"
    }
    
    # 4. Clean up if we temporarily started local services
    if ($localStarted) {
        Show-Banner "Tearing down temporary local services..." "Cyan"
        Stop-LocalServices
        Write-Host "Temporary local services stopped." -ForegroundColor Green
    }
}

# Target: retrain
function Run-Retrain {
    Show-Banner "Target: retrain" "Yellow"
    if (Test-CommandExists "kubectl") {
        Write-Host "Triggering retraining job in Kubernetes..." -ForegroundColor Cyan
        Invoke-Kubectl @("apply", "-f", "k8s/retrain-job.yaml")
    } else {
        Write-Error "Neither kubectl nor minikube is available. Retraining job can only be triggered in a Kubernetes cluster."
    }
}

# Target: clean
function Run-Clean {
    Show-Banner "Target: clean" "Yellow"
    
    if (Test-CommandExists "kubectl") {
        Write-Host "Deleting Kubernetes resources..." -ForegroundColor Cyan
        Invoke-Kubectl @("delete", "-f", "k8s/", "--ignore-not-found")
    } else {
        Write-Host "Neither kubectl nor minikube found. Skipping Kubernetes cleanup." -ForegroundColor Gray
    }
    
    if (Test-CommandExists "docker") {
        Write-Host "Removing Docker images..." -ForegroundColor Cyan
        $images = @("ml-gateway/small:latest", "ml-gateway/medium:latest", "ml-gateway/large:latest", "ml-gateway/gateway:latest")
        foreach ($img in $images) {
            try {
                docker rmi $img -f 2>$null
            } catch {
                # Ignore errors if images don't exist
            }
        }
    } else {
        Write-Host "docker not found. Skipping Docker image cleanup." -ForegroundColor Gray
    }
    
    # Optional: clean training model.pkl files
    Write-Host "Cleaning serialized models..." -ForegroundColor Cyan
    $services = @("small", "medium", "large")
    foreach ($service in $services) {
        $pklPath = "services/$service/model.pkl"
        if (Test-Path $pklPath) {
            Remove-Item $pklPath
            Write-Host "Removed $pklPath" -ForegroundColor Gray
        }
    }
    
    # Stop local running services
    Stop-LocalServices
    
    Write-Host "`nCleanup complete!" -ForegroundColor Green
}

# Target: setup
function Run-Setup {
    Show-Banner "Target: setup" "Yellow"
    
    if (-not (Test-Path "$PSScriptRoot\.venv")) {
        Write-Host "Creating virtual environment at .venv..." -ForegroundColor Cyan
        & python -m venv .venv
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create virtual environment."
        }
    }

    $python = Get-PythonPath
    
    # Try to find pip.exe in the same directory as Python
    $pip = "pip"
    if ($python.Contains("\.venv\")) {
        $pipPath = $python.Replace("python.exe", "pip.exe")
        if (Test-Path $pipPath) {
            $pip = $pipPath
        }
    }
    
    # Setup D-drive temporary directories to bypass C-drive disk space issue
    $tempDir = Join-Path $PSScriptRoot "temp"
    $cacheDir = Join-Path $tempDir "pip_cache"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    
    # Set temp environment variables for the current PowerShell session/process
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $env:TEMP = $tempDir
    $env:TMP = $tempDir
    
    try {
        Write-Host "Installing dependencies using $pip with custom cache/temp directories..." -ForegroundColor Cyan
        & $pip install --cache-dir $cacheDir -r services/small/requirements.txt
        & $pip install --cache-dir $cacheDir -r gateway/requirements.txt
        
        Write-Host "Pre-compiling virtual environment Python bytecode to prevent concurrency conflicts..." -ForegroundColor Cyan
        & $python -m compileall -q (Join-Path $PSScriptRoot ".venv")
    } finally {
        # Restore environment variables
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
    }
    
    Write-Host "`nDependencies setup complete!" -ForegroundColor Green
}

# Helper to track local PIDs
function Add-ProcessToTracker {
    param([string]$Name, [int]$ProcessId)
    $pidFile = Join-Path $PSScriptRoot "temp/pids.txt"
    ($Name + ":" + $ProcessId) | Out-File $pidFile -Append -Encoding UTF8
}

# Helper to stop tracked local services
function Stop-LocalServices {
    $pidFile = Join-Path $PSScriptRoot "temp/pids.txt"
    if (Test-Path $pidFile) {
        Write-Host "Stopping any running local services..." -ForegroundColor Cyan
        $lines = Get-Content $pidFile
        foreach ($line in $lines) {
            if ($line -match "^([^:]+):(\d+)$") {
                $name = $Matches[1]
                $procId = [int]$Matches[2]
                if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
                    Write-Host "Stopping $name service (PID $procId)..." -ForegroundColor Gray
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

# Target: stop
function Run-Stop {
    Show-Banner "Target: stop" "Yellow"
    Stop-LocalServices
    Write-Host "All local services stopped." -ForegroundColor Green
}

# Target: local
function Run-Local {
    Show-Banner "Target: local (Run ML Gateway locally)" "Yellow"
    
    $python = Get-PythonPath
    Write-Host "Using Python: $python" -ForegroundColor Gray
    
    # Ensure logs directory exists
    $tempDir = Join-Path $PSScriptRoot "temp"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    
    # 1. Stop any existing local services first
    Stop-LocalServices
    
    # 2. Start model services
    Write-Host "Starting model services..." -ForegroundColor Cyan
    
    $services = @(
        @{ Name = "small"; Port = 8001; Path = "services/small/app.py" },
        @{ Name = "medium"; Port = 8002; Path = "services/medium/app.py" },
        @{ Name = "large"; Port = 8003; Path = "services/large/app.py" }
    )
    
    foreach ($srv in $services) {
        Write-Host "Starting $($srv.Name) service on port $($srv.Port)..." -ForegroundColor Gray
        $stdoutFile = Join-Path $tempDir "$($srv.Name).stdout.log"
        $stderrFile = Join-Path $tempDir "$($srv.Name).stderr.log"
        $scriptPath = Join-Path $PSScriptRoot $srv.Path
        # Start python process in background with -O optimization, redirecting output to separate log files with explicit WorkingDirectory
        $proc = Start-Process -FilePath $python -ArgumentList @("-O", $scriptPath) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        Add-ProcessToTracker $srv.Name $proc.Id
        Start-Sleep -Seconds 2 # Stagger process start to prevent CPU/RAM race conditions and file collisions!
    }
    
    # 3. Start Gateway service
    Write-Host "Starting gateway service on port 8000..." -ForegroundColor Gray
    $gwStdoutFile = Join-Path $tempDir "gateway.stdout.log"
    $gwStderrFile = Join-Path $tempDir "gateway.stderr.log"
    Push-Location "$PSScriptRoot/gateway"
    try {
        $gwProc = Start-Process -FilePath $python -ArgumentList @("-O", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000") -WorkingDirectory "$PSScriptRoot/gateway" -WindowStyle Hidden -PassThru -RedirectStandardOutput $gwStdoutFile -RedirectStandardError $gwStderrFile
        Add-ProcessToTracker "gateway" $gwProc.Id
    } finally {
        Pop-Location
    }
    
    Write-Host "`nAll services started locally in the background!" -ForegroundColor Green
    Write-Host "Logs are being written to: $tempDir\" -ForegroundColor Gray
    Write-Host "You can test the local gateway using: .\run.ps1 test" -ForegroundColor Yellow
}

# Main Execution Routing
try {
    switch ($Target) {
        "all" {
            Run-Train
            Run-Build
            Run-Deploy
        }
        "setup" { Run-Setup }
        "local" { Run-Local }
        "stop" { Run-Stop }
        "train" { Run-Train }
        "build" { Run-Build }
        "deploy" { Run-Deploy }
        "test" { Run-Test }
        "retrain" { Run-Retrain }
        "clean" { Run-Clean }
    }
} catch {
    Write-Error "Execution failed: $_"
    exit 1
}
