#!/bin/bash

# Define variables
BACKUP_DIR="/opt/dd-conf-backup"
LOG_FILE="/var/log/datadog_installation.log"

# Function for logging
log_message() {
    local message="$1"
    local level="${2:-INFO}"  # Default level is INFO
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to display usage
usage() {
    echo "Usage: $0 [-d] -k DD_API_KEY -s DD_SITE -e CUSTOMER_ENV -o CUSTOMER_ORG -n CUSTOMER_NAME -t SERVER_TYPE"
    echo "  -d: Destroy/Uninstall Datadog Agent"
    echo "  -k: Datadog API Key"
    echo "  -s: Datadog Site (default: datadoghq.com)"
    echo "  -e: Customer Environment"
    echo "  -o: Customer Organization"
    echo "  -n: Customer Name"
    echo "  -t: Server Type"
    exit 1
}

# Function to cleanup Datadog installation
cleanup_datadog() {
    log_message "Starting Datadog Agent cleanup..." "INFO"

    # Stop and disable all Datadog services
    log_message "Stopping Datadog services..." "INFO"
    local services=("datadog-agent" "datadog-agent-process" "datadog-agent-trace" "datadog-agent-security" "datadog-agent-sysprobe")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            systemctl stop "$service"
            systemctl disable "$service"
            log_message "Stopped and disabled $service" "INFO"
        fi
    done

    # Remove dd-agent from docker group
    log_message "Removing dd-agent from Docker group..." "INFO"
    gpasswd -d dd-agent docker || true

    # Backup existing configuration if requested
    if [ "$1" = "backup" ]; then
        log_message "Backing up Datadog configuration..." "INFO"
        BACKUP_TIME=$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR="${BACKUP_DIR}_${BACKUP_TIME}"
        mkdir -p "$BACKUP_DIR"
        if [ -d "/etc/datadog-agent" ]; then
            cp -r /etc/datadog-agent/* "$BACKUP_DIR/" || log_message "Failed to backup some configuration files" "WARN"
            log_message "Configuration backed up to $BACKUP_DIR" "INFO"
        fi
    fi

    # Remove Datadog Agent package
    log_message "Removing Datadog Agent package..." "INFO"
    if command -v yum >/dev/null 2>&1; then
        yum remove -y datadog-agent
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y datadog-agent
    else
        log_message "Package manager not found" "ERROR"
        exit 1
    fi

    # Remove Datadog directories and files
    log_message "Removing Datadog directories and files..." "INFO"
    rm -rf /etc/datadog-agent
    rm -rf /opt/datadog-agent
    rm -rf /var/log/datadog
    rm -f /etc/systemd/system/datadog-agent*
    rm -f /etc/systemd/system/multi-user.target.wants/datadog-agent*

    # Reload systemd
    log_message "Reloading systemd..." "INFO"
    systemctl daemon-reload

    log_message "Datadog Agent cleanup completed successfully" "INFO"
    exit 0
}

# Function to set correct ownership and permissions
setup_permissions() {
    local file_path="$1"
    local perm="$2"
    log_message "Setting up permissions for $file_path" "INFO"
    
    if [ -e "$file_path" ]; then
        if chown dd-agent:dd-agent "$file_path" && chmod "$perm" "$file_path"; then
            log_message "Permissions set successfully for $file_path" "INFO"
            return 0
        else
            log_message "Failed to set permissions for $file_path" "ERROR"
            return 1
        fi
    else
        log_message "File $file_path does not exist" "ERROR"
        return 1
    fi
}

# Parse command line arguments
DESTROY=false
while getopts "dk:s:e:o:n:t:" opt; do
    case $opt in
        d) DESTROY=true ;;
        k) DD_API_KEY="$OPTARG" ;;
        s) DD_SITE="$OPTARG" ;;
        e) CUSTOMER_ENV="$OPTARG" ;;
        o) CUSTOMER_ORG="$OPTARG" ;;
        n) CUSTOMER_NAME="$OPTARG" ;;
        t) SERVER_TYPE="$OPTARG" ;;
        ?) usage ;;
    esac
done

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
   log_message "This script must be run as root" "ERROR"
   exit 1
fi

# Handle destroy option
if [ "$DESTROY" = true ]; then
    log_message "Destroy option selected" "INFO"
    cleanup_datadog "backup"
    exit 0
fi

# Validate required parameters for installation
if [ -z "$DD_API_KEY" ] || [ -z "$CUSTOMER_ENV" ] || [ -z "$CUSTOMER_ORG" ] || [ -z "$CUSTOMER_NAME" ] || [ -z "$SERVER_TYPE" ]; then
    log_message "Missing required parameters" "ERROR"
    usage
fi

# Set default value for DD_SITE if not provided
DD_SITE=${DD_SITE:-"datadoghq.com"}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log_message "=== Starting new Datadog Agent installation ===" "INFO"

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
   log_message "This script must be run as root" "ERROR"
   exit 1
fi

log_message "Starting Datadog Agent installation and configuration..." "INFO"

# Install the Datadog Agent
log_message "Installing the Datadog Agent..." "INFO"
if DD_API_KEY=$DD_API_KEY DD_SITE=$DD_SITE bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)"; then
    log_message "Datadog Agent installation completed successfully" "INFO"
else
    log_message "Failed to install Datadog Agent" "ERROR"
    exit 1
fi

# Take a backup of the Datadog configuration
log_message "Backing up existing Datadog configuration..." "INFO"
mkdir -p "$BACKUP_DIR"
if cp -r /etc/datadog-agent/datadog.yaml "$BACKUP_DIR"; then
    log_message "Configuration backup created successfully at $BACKUP_DIR" "INFO"
else
    log_message "Failed to create configuration backup" "ERROR"
    exit 1
fi

# Update Datadog configuration
log_message "Updating Datadog configuration..." "INFO"
cat > /etc/datadog-agent/datadog.yaml <<EOL
api_key: $DD_API_KEY
check_runners: 4
cmd.check.fullsketches: false
config_providers:
- name: docker
  polling: true
container_collect_all: true
containerd_namespace: []
containerd_namespaces: []
inventories_configuration_enabled: true
listeners:
- name: docker
logs:
  enabled: true
logs_config:
  api_key: $DD_API_KEY
  container_collect_all: true
logs_enabled: true
network:
  enabled: false
network_config:
  enabled: false
orchestrator_explorer:
  collector_discovery:
    enabled: true
  container_scrubbing:
    enabled: true
process_config:
  container_collection:
    enabled: false
  enabled: true
  event_collection:
    enabled: true
    interval: 10s
    store:
      max_items: 200
      max_pending_pulls: 10
      max_pending_pushes: 10
      stats_interval: 20
  process_collection:
    enabled: true
  process_discovery:
    enabled: true
profiling_enabled: true
proxy:
  http: ""
  https: ""
  no_proxy:
  - 169.254.169.254
python_version: "3"
runtime_security_config:
  enabled: false
security_config:
  enabled: false
service_monitoring_config:
  enabled: true
site: $DD_SITE
system_probe_config:
  process_config:
    enabled: true
tracemalloc_debug: false
tags:
  - environment: $CUSTOMER_ENV
  - organization: $CUSTOMER_ORG
  - customer_name: $CUSTOMER_NAME
  - server_type: $SERVER_TYPE
EOL
log_message "Datadog configuration file updated successfully" "INFO"

# Set permissions for datadog.yaml
setup_permissions "/etc/datadog-agent/datadog.yaml" 640 || exit 1

# Create auth_token file
log_message "Creating auth_token file..." "INFO"
AUTH_TOKEN_FILE="/etc/datadog-agent/auth_token"

if [ ! -f "$AUTH_TOKEN_FILE" ]; then
    if openssl rand -hex 32 > "$AUTH_TOKEN_FILE" 2>/dev/null; then
        setup_permissions "$AUTH_TOKEN_FILE" 600 || exit 1
        log_message "Auth token file created successfully" "INFO"
    else
        log_message "Failed to create auth token file" "ERROR"
        exit 1
    fi
else
    log_message "Auth token file exists, updating permissions" "INFO"
    setup_permissions "$AUTH_TOKEN_FILE" 600 || exit 1
fi

# Enable the process module
log_message "Enabling the system probe and process module..." "INFO"
cat > /etc/datadog-agent/system-probe.yaml <<EOL
system_probe_config:
  enabled: true
  process_config:
    enabled: true
EOL
log_message "System probe configuration updated successfully" "INFO"

# Set permissions for system-probe.yaml
setup_permissions "/etc/datadog-agent/system-probe.yaml" 600 || exit 1

# Create and set permissions for environment file
touch /etc/datadog-agent/environment
setup_permissions "/etc/datadog-agent/environment" 600 || exit 1

# Clear any existing agent state
log_message "Clearing existing agent state..." "INFO"
rm -f /opt/datadog-agent/run/*.pid || true
rm -f /var/run/datadog-agent/*.pid || true

# Stop all Datadog services
log_message "Stopping Datadog services..." "INFO"
systemctl stop datadog-agent datadog-agent-process datadog-agent-trace datadog-agent-security || true
systemctl stop datadog-agent-sysprobe || true

# Start services in correct order
log_message "Starting Datadog services..." "INFO"
if systemctl start datadog-agent-sysprobe; then
    log_message "System probe service started successfully" "INFO"
    sleep 2
    if systemctl start datadog-agent; then
        log_message "Datadog agent started successfully" "INFO"
    else
        log_message "Failed to start Datadog agent" "ERROR"
        exit 1
    fi
else
    log_message "Failed to start system probe service" "ERROR"
    exit 1
fi

# Add dd-agent to the docker group
log_message "Adding dd-agent to the Docker group..." "INFO"
if usermod -a -G docker dd-agent; then
    log_message "dd-agent added to Docker group successfully" "INFO"
else
    log_message "Failed to add dd-agent to Docker group" "ERROR"
    exit 1
fi

# Enable syslog monitoring
log_message "Configuring syslog monitoring..." "INFO"
mkdir -p /etc/datadog-agent/conf.d/syslog.d
cat > /etc/datadog-agent/conf.d/syslog.d/conf.yaml <<EOL
logs:
  - path: /var/log/messages
    source: syslog
    type: file
  - path: /var/log/debug.log
    source: debug
    type: file
  - path: /var/log/error.log
    source: error
    type: file
  - path: /var/log/startup.log
    source: startup
    type: file
EOL
if chown -R dd-agent:dd-agent /etc/datadog-agent/conf.d/syslog.d; then
    log_message "Syslog configuration updated successfully" "INFO"
else
    log_message "Failed to update syslog configuration" "ERROR"
    exit 1
fi

# Set ACL for log files
for log_file in "/var/log/messages" "/var/log/error.log" "/var/log/debug.log"; do
    if [ -f "$log_file" ]; then
        if setfacl -m u:dd-agent:r "$log_file"; then
            log_message "ACL updated successfully for $log_file" "INFO"
        else
            log_message "Failed to update ACL for $log_file" "ERROR"
            exit 1
        fi
    else
        touch "$log_file"
        chmod 644 "$log_file"
        if setfacl -m u:dd-agent:r "$log_file"; then
            log_message "Created and set ACL for $log_file" "INFO"
        else
            log_message "Failed to create and set ACL for $log_file" "ERROR"
            exit 1
        fi
    fi
done

# Restart the Datadog Agent
log_message "Restarting the Datadog Agent..." "INFO"
if systemctl restart datadog-agent; then
    log_message "Datadog Agent restarted successfully" "INFO"
else
    log_message "Failed to restart Datadog Agent" "ERROR"
    exit 1
fi
if systemctl enable datadog-agent; then
    log_message "Datadog Agent enabled successfully" "INFO"
else
    log_message "Failed to enable Datadog Agent" "ERROR"
    exit 1
fi

# Verify the installation
log_message "Performing verification steps..." "INFO"
sleep 10
if systemctl is-active datadog-agent; then
    log_message "Datadog Agent status verified successfully" "INFO"
else
    log_message "Failed to verify Datadog Agent status" "ERROR"
    exit 1
fi
if datadog-agent configcheck; then
    log_message "Datadog Agent configuration verified successfully" "INFO"
else
    log_message "Failed to verify Datadog Agent configuration" "ERROR"
    exit 1
fi
if datadog-agent status; then
    log_message "Datadog Agent status verified successfully" "INFO"
else
    log_message "Failed to verify Datadog Agent status" "ERROR"
    exit 1
fi

log_message "Datadog Agent installation and configuration completed successfully!" "INFO"