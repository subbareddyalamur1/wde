<powershell>
# Set execution policy and error preference
Set-ExecutionPolicy Unrestricted -Force
$ErrorActionPreference = "Stop"

# Initialize logging
Start-Transcript -Path "C:\Windows\Temp\userdata_log.txt" -Append

try {
    # Create DoNotDelete directory
    New-Item -ItemType Directory -Force -Path "C:\DoNotDelete" | Out-Null

    # install CloudWatch agent
    Invoke-WebRequest -Uri https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi -OutFile C:\amazon-cloudwatch-agent.msi
    Start-Process -FilePath C:\amazon-cloudwatch-agent.msi -ArgumentList '/quiet' -Wait

    # install AWS CLI if not already installed
    if (-not (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
        Write-Host "Installing AWS CLI..."
        $installerPath = "C:\AWSCLIV2.msi"
        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $installerPath
        Start-Process -FilePath msiexec.exe -Args "/i $installerPath /quiet" -Wait
        Remove-Item $installerPath
    }

    $scriptContent = @'
function Write-Log {
    param($Message)
    
    $logDir = "C:\DoNotDelete"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    
    $logFile = "C:\DoNotDelete\metrics.log"
    
    # Check if log file exists and is older than 30 days
    if (Test-Path $logFile) {
        $logAge = (Get-Date) - (Get-Item $logFile).CreationTime
        if ($logAge.Days -ge 30) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $archiveFile = "C:\DoNotDelete\metrics_$timestamp.log"
            Move-Item -Path $logFile -Destination $archiveFile -Force
            
            # Clean up archives older than 30 days
            Get-ChildItem -Path "C:\DoNotDelete\metrics_*.log" | 
                Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-30) } | 
                Remove-Item -Force
        }
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

try {
    Write-Log "Starting metric collection..."

    if (-not (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
        throw "AWS CLI is not installed"
    }

    Write-Log "Checking AWS credentials..."
    $credCheck = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" sts get-caller-identity 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AWS credentials check failed: $credCheck"
    }
    Write-Log "AWS credentials check result: $credCheck"

    Write-Log "Checking CloudWatch permissions..."
    $permCheck = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" cloudwatch list-metrics --namespace AWS/EC2 --max-items 1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "CloudWatch permission check failed: $permCheck"
    }
    Write-Log "CloudWatch permission check passed"

    Write-Log "Getting IMDSv2 token..."
    $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
    
    Write-Log "Getting instance ID..."
    $instanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Method GET -Uri "http://169.254.169.254/latest/meta-data/instance-id"
    Write-Log "Instance ID: $instanceId"

    Write-Log "Getting region..."
    $region = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Method GET -Uri "http://169.254.169.254/latest/meta-data/placement/region"
    Write-Log "Region: $region"

    Write-Log "Getting Auto Scaling Group name..."
    $asgName = ""
    $tags = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ec2 describe-tags --region $region --filters "Name=resource-id,Values=$instanceId" "Name=key,Values=aws:autoscaling:groupName" | ConvertFrom-Json
    if ($tags.Tags.Count -gt 0) {
        $asgName = $tags.Tags[0].Value
        Write-Log "Auto Scaling Group name: $asgName"
    } else {
        Write-Log "Instance is not part of an Auto Scaling Group"
    }

    Write-Log "Getting active sessions..."
    $activeSessions = 0
    $quserOutput = quser 2>&1
    if ($LASTEXITCODE -eq 0) {
        $activeSessions = ($quserOutput | Where-Object { $_ -match 'Active' }).Count
    }
    Write-Log "Active sessions: $activeSessions"

    Write-Log "Sending metric..."
    
    # Format dimensions in key=value format
    $dimensions = "InstanceId=$instanceId"
    if ($asgName) {
        $dimensions = "$dimensions,AutoScalingGroupName=$asgName"
    }
    
    Write-Log "Dimensions: $dimensions"
    
    $result = aws cloudwatch put-metric-data `
        --region $region `
        --namespace Custom/WindowsMetrics `
        --metric-name ActiveUserSessions `
        --value $activeSessions `
        --unit Count `
        --dimensions "$dimensions" 2>&1
    
    $exitCode = $LASTEXITCODE

    Write-Log "Command exit code: $exitCode"
    Write-Log "Command output: $result"

    if ($exitCode -ne 0) {
        throw "Failed to send metric: $result"
    }

} catch {
    $errorMessage = $_.Exception.Message
    Write-Log "ERROR: $errorMessage"
    Write-Log "Stack Trace: $($_.Exception.StackTrace)"
    throw
}
'@

    # write above script to a file
    Set-Content -Path "C:\DoNotDelete\ActiveUsersWatcher.ps1" -Value $scriptContent -Encoding UTF8
    Write-Host "Created metrics script at C:\DoNotDelete\ActiveUserWatcher.ps1"

    # create scheduled task with SYSTEM account
    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File C:\DoNotDelete\ActiveUsersWatcher.ps1"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -Hidden
    $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -TaskName "ActiveUsersWatcher" -Description "Monitor active user sessions" -Principal $principal
    Write-Host "Created scheduled task 'ActiveUsersWatcher'"

} catch {
    Write-Host "Error occurred during user data execution: $_"
    throw
} finally {
    Stop-Transcript
}
</powershell>
<persist>true</persist>