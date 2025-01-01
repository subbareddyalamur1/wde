param (
    [Parameter(Mandatory=$true)]
    [string]$CUSTOMER_NAME,
    
    [Parameter(Mandatory=$true)]
    [string]$CUSTOMER_ORG,
    
    [Parameter(Mandatory=$true)]
    [string]$CUSTOMER_ENV,
    
    [Parameter(Mandatory=$true)]
    [string]$APP_NAME,
    
    [Parameter(Mandatory=$true)]
    [string]$AD_DOMAIN,

    [Parameter(Mandatory=$true)]
    [string]$AD_OU_PATH,

    [Parameter(Mandatory=$true)]
    [string]$AD_CREDENTIALS_SECRET
)

# Set execution policy and error preference
Set-ExecutionPolicy Unrestricted -Force
$ErrorActionPreference = "Stop"
Import-Module AWSPowerShell


# Script-scoped variables
$Script:hostname = $null
$Script:ADCredentials = $null 

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

# Function to join AD domain
function Join-ADDomain {
    param()
    try {
        Write-Log "Attempting to join domain: $AD_DOMAIN"
        $username = $Script:ADCredentials.UserId
        $password = $Script:ADCredentials.Password | ConvertTo-SecureString -AsPlainText -Force
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
        Add-Computer -DomainName $AD_DOMAIN -OUPath $AD_OU_PATH -Credential $credential -NewName $Script:hostname -Force
        
        # Validate domain join
        Write-Log "Validating domain join..."
        $maxAttempts = 3
        $attempt = 1
        $joined = $false
        
        while (-not $joined -and $attempt -le $maxAttempts) {
            try {
                $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
                if ($computerSystem.PartOfDomain -and $computerSystem.Domain -eq $AD_DOMAIN) {
                    Write-Log "Successfully joined domain: $($computerSystem.Domain) with hostname: $Script:hostname"
                    $joined = $true
                    
                    # Test domain connectivity
                    $dcTest = Test-ComputerSecureChannel -Server $computerSystem.Domain
                    if (-not $dcTest) {
                        throw "Domain controller connection test failed"
                    }
                    Write-Log "Domain controller connection test successful"

                    # Force group policy update
                    Write-Log "Updating Group Policy..."
                    gpupdate /force | Out-Null
                } else {
                    throw "Computer is not joined to the expected domain: $AD_DOMAIN"
                }
            } catch {
                if ($attempt -eq $maxAttempts) {
                    Write-Log "Domain join validation failed after $maxAttempts attempts: $_" -EventType "Error"
                    throw
                }
                Write-Log "Domain join validation attempt $attempt failed: $_. Retrying in 10 seconds..." -EventType "Warning"
                Start-Sleep -Seconds 10
                $attempt++
            }
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
        $adminPassword = $Script:ADCredentials.Password | ConvertTo-SecureString -AsPlainText -Force
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
    try {
        Write-Log "Starting hostname configuration..."

        # Get IMDSv2 token
        $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token" -TimeoutSec 5

        # Get instance ID
        $instanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Method GET -Uri "http://169.254.169.254/latest/meta-data/instance-id" -TimeoutSec 5

        # Generate hostname
        $prefix = "$($CUSTOMER_ENV[0])"
        $suffix = $instanceId.Substring($instanceId.Length - 3)
        $Script:hostname = "$prefix-$CUSTOMER_ORG-$APP_NAME-$suffix".ToUpper()

        if ($Script:hostname.Length -gt 15) {
            $Script:hostname = $Script:hostname.Substring(0, 15)
            Write-Log "Hostname truncated to 15 characters: $Script:hostname" -EventType "Warning"
        }

        # Log current computer name
        Write-Log "Current computer name: $env:computername"
        Write-Log "Proposed hostname: $Script:hostname"

        # Set hostname
        if ($env:computername -ne $Script:hostname) {
            Write-Log "Setting hostname to: $Script:hostname"
            Rename-Computer -NewName $Script:hostname -Force -ErrorAction Stop
            Write-Log "Hostname configuration completed successfully"
            return $Script:hostname
        } else {
            Write-Log "Hostname is already set to: $Script:hostname"
            return $Script:hostname
        }
    } catch {
        Write-Log "Error during hostname configuration: $_" -EventType "Error"
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
    $permCheck = aws cloudwatch list-metrics --namespace AWS/EC2 --max-items 1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "CloudWatch permission check failed: $permCheck"
    }
    Write-Log "CloudWatch permission check passed"

    Write-Log "Getting IMDSv2 token..."
    $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "300"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
    
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
    $logDir = "C:\DoNotDelete"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
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
        
        # Check if the scheduled task already exists
        $taskExists = Get-ScheduledTask | Where-Object { $_.TaskName -eq "ActiveUsersWatcher" }
        if (-not $taskExists) {
            Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -TaskName "ActiveUsersWatcher" -Description "Monitor active user sessions" -Principal $principal
            Write-Log "Scheduled task 'ActiveUsersWatcher' created successfully."
        } else {
            Write-Log "Scheduled task 'ActiveUsersWatcher' already exists. Skipping creation."
        }
    }
    catch {
        Write-Log "Error creating scheduled task: $_" -EventType "Error"
        throw
    }
}

# Function to create domain unjoin script
function UnJoin-ADDomainTask {
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
    `$secret = Get-SECSecretValue -SecretId "$AD_CREDENTIALS_SECRET" | 
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
       
        Write-Log "UnJoin-ADDomain script added to shutdown scripts successfully"
    } catch {
        Write-Log "Error creating UnJoin-ADDomain script: $_" -EventType "Error"
        throw
    }
}

function Reboot-Computer {
    try {
        Write-Log "Scheduling computer restart in 60 seconds..."
        Start-Sleep -Seconds 60
        Restart-Computer -Force
        Write-Log "Restart command issued successfully"
    } catch {
        Write-Log "Error restarting computer: $_" -EventType "Error"
        throw
    }
}

function Prevent-Subsequent-Userdata-Execution {
    # Set registry key to prevent userdata execution on subsequent reboots
    Write-Log "Setting EC2Launch registry key to prevent future userdata execution..."
    if (-not (Test-Path "HKLM:\SOFTWARE\Amazon\EC2Launch")) {
        New-Item -Path "HKLM:\SOFTWARE\Amazon\EC2Launch" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Amazon\EC2Launch" -Name "ExecuteUserData" -Value 1 -Type DWord
    Write-Log "EC2Launch registry key set successfully"
}

function Get-ADCredentials {
    try {
        Write-Log "Retrieving credentials from Secrets Manager..."
        $Script:ADCredentials = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" secretsmanager get-secret-value `
            --secret-id $AD_CREDENTIALS_SECRET `
            --query SecretString `
            --output text | ConvertFrom-Json
        Write-Log "Credentials retrieved successfully"
    } catch {
        Write-Log "Failed to retrieve credentials: $_" -EventType "Error"
        throw
    }
}

function Mount-FSxDrive {
    try {
        Write-Log "Starting FSx drive mount process..."
        
        # Get FSx file system DNS name using AWS CLI and tags
        $fsxFilter = "Name=tag:Name,Values=$CUSTOMER_NAME-$CUSTOMER_ORG-$CUSTOMER_ENV-$APP_NAME* " + `
                    "Name=tag:CustomerName,Values=$CUSTOMER_NAME " + `
                    "Name=tag:CustomerOrg,Values=$CUSTOMER_ORG " + `
                    "Name=tag:CustomerEnv,Values=$CUSTOMER_ENV " + `
                    "Name=tag:AppName,Values=$APP_NAME"
        
        Write-Log "Querying FSx file system with filter: $fsxFilter"
        
        $fsxInfo = aws fsx describe-file-systems --filters $fsxFilter | ConvertFrom-Json
        
        if (-not $fsxInfo -or -not $fsxInfo.FileSystems -or $fsxInfo.FileSystems.Count -eq 0) {
            throw "No FSx file system found matching the specified tags"
        }
        
        $fsxDnsName = $fsxInfo.FileSystems[0].DNSName
        Write-Log "Found FSx DNS name: $fsxDnsName"
        
        # Check if P: drive already exists
        if (Test-Path "P:") {
            Write-Log "P: drive already exists. Removing existing mapping..."
            Remove-PSDrive -Name "P" -Force -ErrorAction SilentlyContinue
            Net Use P: /DELETE /Y
        }
        
        # Mount FSx share as P: drive
        Write-Log "Mounting FSx share as P: drive..."
        $mountCommand = "Net Use P: \\$fsxDnsName\share /PERSISTENT:YES"
        $result = Invoke-Expression $mountCommand
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully mounted FSx share as P: drive"
        } else {
            throw "Failed to mount FSx share. Net Use command returned: $result"
        }
        
        # Verify the mount
        if (Test-Path "P:") {
            Write-Log "Verified P: drive is accessible"
        } else {
            throw "P: drive is not accessible after mounting"
        }
    }
    catch {
        Write-Log "Error mounting FSx drive: $_" -EventType "Error"
        throw
    }
}

# Main execution block
try {
    # Check if script has already run
    $markerFile = "C:\DoNotDelete\startup_complete.marker"
    if (Test-Path $markerFile) {
        Write-Log "Startup script has already run. Exiting..."
        exit 0
    }
    Write-Log "Starting user data execution..."
    Write-Log "Customer Name: $CUSTOMER_NAME"
    Write-Log "Customer Organization: $CUSTOMER_ORG"
    Write-Log "Environment: $CUSTOMER_ENV"
    Write-Log "Application Name: $APP_NAME"
    Write-Log "Active Directory Domain: $AD_DOMAIN"
    Write-Log "AD Credentials Secret: $AD_CREDENTIALS_SECRET"

    Get-ADCredentials
    Set-LocalAdminPassword
    Set-WindowsHostname
    New-MetricsScript
    Register-MetricsTask
    UnJoin-ADDomainTask
    Join-ADDomain
    Mount-FSxDrive
    Prevent-Subsequent-Userdata-Execution
    
    # Create marker file to indicate successful execution
    New-Item -Path $markerFile -ItemType File -Force | Out-Null
    Write-Log "Created startup completion marker file"

    Reboot-Computer

    Write-Log "User data execution completed successfully"
} catch {
    Write-Log "Error occurred during user data execution: $_" -EventType "Error"
    throw
}
