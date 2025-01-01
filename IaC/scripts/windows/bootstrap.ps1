<powershell>
Set-ExecutionPolicy Unrestricted -Force
$ErrorActionPreference = "Stop"

# Template variables that will be replaced by Terraform
$CUSTOMER_NAME = "${customer_name}"
$CUSTOMER_ORG = "${customer_org}"
$CUSTOMER_ENV = "${customer_env}"
$APP_NAME = "${app_name}"
$AD_DOMAIN = "${domain}"
$AD_OU_PATH = "${ou_path}"
$WORKGROUP = "${workgroup}"
$AD_CREDENTIALS_SECRET = "${ad_credentials_secret}"
$S3_BUCKET = "${s3_bucket}"
$S3_KEY = "${s3_key}"

function Write-Log {
    param([string]$Message, [string]$EventType = "Information")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - [$EventType] - $Message"
    $logFile = "C:\Windows\Temp\bootstrap_log.txt"
    $logMessage | Out-File -FilePath $logFile -Append
}

try {
    Write-Log "Starting bootstrap process..."
    
    # Install AWS CLI if not present
    if (-not (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
        Write-Log "Installing AWS CLI..."
        $awsInstaller = "C:\Windows\Temp\AWSCLIV2.msi"
        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $awsInstaller
        Start-Process msiexec.exe -Wait -ArgumentList "/i $awsInstaller /quiet"
        Remove-Item $awsInstaller -Force
    }

    # Install ssm-agent if not present
    if (-not (Get-Service -Name "AmazonSSMAgent" -ErrorAction SilentlyContinue)) {
        Write-Log "Installing ssm-agent..."
        $ssmInstaller = "C:\Windows\Temp\amazon-ssm-agent.msi"
        Invoke-WebRequest -Uri "https://s3.amazonaws.com/ec2windows/latest/SSMAgent/latest/windows_amd64/amazon-ssm-agent.msi" -OutFile $ssmInstaller
        Start-Process msiexec.exe -Wait -ArgumentList "/i $ssmInstaller /quiet"
        Remove-Item $ssmInstaller -Force
    }

    # Install RSAT AD PowerShell
    if (-not (Get-WindowsFeature -Name "RSAT-AD-PowerShell").Installed) {
        Write-Log "Installing RSAT AD PowerShell..."
        Install-WindowsFeature -Name "RSAT-AD-PowerShell" -ErrorAction Stop
    }

    # Create scripts directory
    write-Log "Creating scripts directory..."
    $scriptsDir = "C:\Windows\Temp\Scripts"
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

    # Download and extract scripts
    Write-Log "Downloading scripts from S3..."
    $zipPath = Join-Path $scriptsDir "scripts.zip"
    & "C:\Program Files\Amazon\AWSCLIV2\aws" s3 cp "s3://$S3_BUCKET/$S3_KEY" $zipPath

    if (-not (Test-Path $zipPath)) {
        throw "Failed to download scripts from S3"
    }

    Write-Log "Extracting scripts..."
    Expand-Archive -Path $zipPath -DestinationPath $scriptsDir -Force

    $startupScript = Join-Path $scriptsDir "\startup.ps1"
    if (-not (Test-Path $startupScript)) {
        throw "startup.ps1 not found in extracted scripts"
    }

    Write-Log "Executing startup script..."
    
    # Execute startup script with parameters
    & $startupScript `
        -CUSTOMER_NAME $CUSTOMER_NAME `
        -CUSTOMER_ORG $CUSTOMER_ORG `
        -CUSTOMER_ENV $CUSTOMER_ENV `
        -APP_NAME $APP_NAME `
        -AD_DOMAIN $AD_DOMAIN `
        -AD_OU_PATH $AD_OU_PATH `
        -AD_CREDENTIALS_SECRET $AD_CREDENTIALS_SECRET

    Write-Log "Startup script execution completed"
} catch {
    Write-Log "Error during bootstrap: $_" -EventType "Error"
    throw
} 
</powershell>
<persist>true</persist>