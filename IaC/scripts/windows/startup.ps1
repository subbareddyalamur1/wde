<powershell>
# Set execution policy and error preference
Set-ExecutionPolicy Unrestricted -Force
$ErrorActionPreference = "Stop"

# Template variables
$CUSTOMER_NAME = "${customer_name}"
$CUSTOMER_ORG = "${customer_org}"
$CUSTOMER_ENV = "${customer_env}"
$APP_NAME = "${app_name}"
$AD_DOMAIN = "${domain}"
$AD_CREDENTAILS_SECRET_ARN = "${ad_credentials_secret_arn}"
$AD_WORKGROUP = "${ad_workgroup}"

# Initialize logging
Start-Transcript -Path "C:\Windows\Temp\userdata_log.log" -Append

# Function to write logs
function Write-Log {
    param(
        [string]$Message,
        [string]$EventType = "Information"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - [$EventType] - $Message"
    
    # Write to log file
    $logFile = "C:\Windows\Temp\userdata_log.txt"
    $logMessage | Out-File -FilePath $logFile -Append
    
    # Write to Event Log
    $source = "WDEUserData"
    $eventLog = "Application"
    
    # Create event source if it doesn't exist
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        [System.Diagnostics.EventLog]::CreateEventSource($source, $eventLog)
    }
    
    Write-EventLog -LogName $eventLog -Source $source -EventId 1000 -EntryType $EventType -Message $Message
}

# Function to install prerequisites
function Install-Prerequisites {
    try {
        Write-Log "Starting installation for customer: $CUSTOMER_NAME, org: $CUSTOMER_ORG, env: $CUSTOMER_ENV"
        
        # Create DoNotDelete directory
        New-Item -ItemType Directory -Force -Path "C:\DoNotDelete" | Out-Null

        # install CloudWatch agent
        Invoke-WebRequest -Uri https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi -OutFile C:\amazon-cloudwatch-agent.msi
        Start-Process -FilePath C:\amazon-cloudwatch-agent.msi -ArgumentList '/quiet' -Wait
        Write-Log "CloudWatch agent installed successfully"

        # install AWS CLI if not already installed
        if (-not (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
            Write-Log "Installing AWS CLI..."
            $installerPath = "C:\AWSCLIV2.msi"
            Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $installerPath
            Start-Process -FilePath msiexec.exe -Args "/i $installerPath /quiet" -Wait
            Remove-Item $installerPath
            Write-Log "AWS CLI installed successfully"
        }

        #install RSAT-AD-PowerShell if not already installed
        if (-not (Get-WindowsFeature RSAT-AD-PowerShell)) {
            Write-Log "Installing RSAT-AD-PowerShell..."
            Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools
            Write-Log "RSAT-AD-PowerShell installed successfully"
        }
        Write-Log "Prerequisites installed successfully"
    }
    catch {
        Write-Log "Error installing prerequisites: $_" -EventType "Error"
        throw
    }
}

# Function to join AD domain
function Join-ADDomain {
    param()
    try {
        if ($AD_DOMAIN) {
            Write-Log "Attempting to join domain: $AD_DOMAIN"
            # Get domain join credentials from AWS Secrets Manager
            $secret = Get-SECSecretValue -SecretId $AD_CREDENTAILS_SECRET_ARN | Select-Object -ExpandProperty SecretString | ConvertFrom-Json
            $username = $secret.UserId
            $password = $secret.Password | ConvertTo-SecureString -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($username, $password)
            
            # Check if computer is already domain joined
            $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
            if ($computerSystem.PartOfDomain) {
                $currentDomain = $computerSystem.Domain
                Write-Log "Computer is currently joined to domain: $currentDomain"
                Write-Log "Removing computer from current domain..."
                
                # Remove from current domain
                Remove-Computer -UnjoinDomainCredential $credential -Force
                
                Write-Log "Successfully removed from domain: $currentDomain"
            }
            
            Write-Log "Joining new domain: $AD_DOMAIN"
            Add-Computer -DomainName $AD_DOMAIN -Credential $credential -Force -Restart
        }
    }
    catch {
        Write-Log "Error with domain operations: $_" -EventType "Error"
        throw
    }
}

# Function to set local administrator password
function Set-LocalAdminPassword {
    try {
        Write-Log "Setting local administrator password..."
        
        # Get admin credentials from AWS Secrets Manager
        $secret = Get-SECSecretValue -SecretId $AD_CREDENTAILS_SECRET_ARN | Select-Object -ExpandProperty SecretString | ConvertFrom-Json
        $adminPassword = $secret.Password | ConvertTo-SecureString -AsPlainText -Force
        
        # Get local administrator account
        $adminAccount = Get-LocalUser -Name "Administrator"
        
        # Set password
        $adminAccount | Set-LocalUser -Password $adminPassword -PasswordNeverExpires $true
        Write-Log "Local administrator password updated successfully"
        
        # Enable administrator account if disabled
        if (-not $adminAccount.Enabled) {
            Enable-LocalUser -Name "Administrator"
            Write-Log "Local administrator account enabled"
        }
    }
    catch {
        Write-Log "Error setting local administrator password: $_" -EventType "Error"
        throw
    }
}

# Function to set Windows hostname
function Set-WindowsHostname {
    param()
    try {
        # Get IMDSv2 token
        $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
        
        # Get instance ID
        $instanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Method GET -Uri "http://169.254.169.254/latest/meta-data/instance-id"  
        
        # Extract the last two characters from instance ID
        $instanceNumber = $instanceId.Substring($instanceId.Length - 2)
        
        # Get first letter of environment
        $envPrefix = $CUSTOMER_ENV.Substring(0,1)
        
        # Construct hostname
        $hostname = "$envPrefix-$APP_NAME-$CUSTOMER_NAME-$instanceNumber".ToLower()
        
        # Remove any special characters and ensure hostname meets Windows requirements
        $hostname = $hostname -replace '[^a-zA-Z0-9-]', ''
        if ($hostname.Length -gt 15) {
            $hostname = $hostname.Substring(0, 15)
        }
        
        Write-Log "Setting hostname to: $hostname"
        Rename-Computer -NewName $hostname -Force
        
        Write-Log "Hostname set successfully"
    }
    catch {
        Write-Log "Error setting hostname: $_" -EventType "Error"
        throw
    }
}

# Function to create metrics collection script
function New-MetricsScript {
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
        $activeSessions = ($quserOutput).Count
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

    # write script to file
    Set-Content -Path "C:\DoNotDelete\ActiveUsersWatcher.ps1" -Value $scriptContent -Encoding UTF8
    Write-Log "Created metrics script at C:\DoNotDelete\ActiveUserWatcher.ps1"
}

# Function to create scheduled task
function Register-MetricsTask {
    try {
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File C:\DoNotDelete\ActiveUsersWatcher.ps1"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $settings = New-ScheduledTaskSettingsSet -Hidden
        $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -TaskName "ActiveUsersWatcher" -Description "Monitor active user sessions" -Principal $principal
        Write-Log "Created scheduled task 'ActiveUsersWatcher'"
    }
    catch {
        Write-Log "Error creating scheduled task: $_" -EventType "Error"
        throw
    }
}

# Function to create domain cleanup script
function UnJoin-ADDomainTask {
    param(
        [string]$AD_CREDENTIALS_SECRET_ARN
    )
    try {
        $scriptPath = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Shutdown\Shutdown-UnJoin.ps1"
        $scriptDirectory = Split-Path -Path $scriptPath -Parent
        if (-not (Test-Path $scriptDirectory)) {
            try {
                New-Item -ItemType Directory -Force -Path $scriptDirectory | Out-Null
            } catch {
                Write-Log "Error creating directory: $_" -EventType "Error"
                throw
            }
        }

        $scriptContent = @"
# Domain unjoin script
`$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string]`$Message,
        [string]`$EventType = "Information"
    )
    
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    `$logMessage = "`$timestamp - [`$EventType] - `$Message"
    
    # Write to log file
    `$logFile = "C:\Windows\Temp\domain-unjoin.txt"
    `$logMessage | Out-File -FilePath `$logFile -Append
    
    # Write to Event Log
    `$source = "WDEUserData"
    `$eventLog = "Application"
    
    if (-not [System.Diagnostics.EventLog]::SourceExists(`$source)) {
        [System.Diagnostics.EventLog]::CreateEventSource(`$source, `$eventLog)
    }
    
    Write-EventLog -LogName `$eventLog -Source `$source -EventId 1000 -EntryType `$EventType -Message `$Message
}

try {
    Write-Log "Starting domain cleanup"
    
    # Check if machine is domain-joined
    `$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
    if (-not `$computerSystem.PartOfDomain) {
        Write-Log "Machine is not domain-joined. Exiting."
        return
    }
    
    `$currentDomain = `$computerSystem.Domain
    Write-Log "Current domain: `$currentDomain"
    
    # Get credentials from AWS Secrets Manager
    Import-Module AWSPowerShell
    `$secret = Get-SECSecretValue -SecretId "$AD_CREDENTIALS_SECRET_ARN" | 
        Select-Object -ExpandProperty SecretString | 
        ConvertFrom-Json
        
    `$username = `$secret.UserID + "@" + `$secret.Domain
    `$password = `$secret.Password | ConvertTo-SecureString -AsPlainText -Force
    `$credential = New-Object System.Management.Automation.PSCredential(`$username, `$password)
    
    Write-Log "Removing computer from domain"
    Remove-Computer -UnjoinDomainCredential `$credential -Force
    
    Write-Log "Successfully removed from domain"
} catch {
    Write-Log "Error during domain cleanup: `$_" -EventType "Error"
    throw
}
"@
        # Create script file
        Set-Content -Path $scriptPath -Value $scriptContent
        
        # Enable GPO to run the script during shutdown
        $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown\0\0"
        if (-not (Test-Path $registryPath -PathType Container)) {
            New-Item -Path $registryPath -Force | Out-Null
        }
        Set-ItemProperty -Path $registryPath -Name "Script" -Value "Shutdown-UnJoin.ps1"
        Set-ItemProperty -Path $registryPath -Name "Parameters" -Value ""
        Set-ItemProperty -Path $registryPath -Name "IsPowershell" -Value 1

        # Force group policy update
        gpupdate /force | Out-Null
        
        Write-Log "UnJoin-ADDomain script added to shutdown scripts successfully"
    } catch {
        Write-Log "Error creating UnJoin-ADDomain script: $_" -EventType "Error"
        throw
    }
}

function Reboot-Computer {
    try {
        Write-Log "Rebooting computer..."
        Restart-Computer -Force
    } catch {
        Write-Log "Error rebooting computer: $_" -EventType "Error"
        throw
    }
}

# Main execution block
try {
    Install-Prerequisites
    Set-WindowsHostname
    Set-LocalAdminPassword
    New-MetricsScript
    Register-MetricsTask
    UnJoin-ADDomainTask -AD_CREDENTIALS_SECRET_ARN $AD_CREDENTAILS_SECRET_ARN
    Join-ADDomain
    Reboot-Computer
} catch {
    Write-Log "Error occurred during user data execution: $_" -EventType "Error"
    throw
} finally {
    Stop-Transcript
}
</powershell>
<persist>true</persist>