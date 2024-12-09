#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

declare -r LOG_FILE="/var/log/startup.log"
declare -r SSM_AGENT_URL="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm"
declare -r AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"

# Parameters passed from Terraform
AD_WORKGROUP="${ad_workgroup}"
AD_DOMAIN="${ad_domain}"
AD_CREDENTAILS_SECRET_ARN="${ad_credentails_secret_arn}"
DATADOG_API_KEY="${datadog_api_key}"
CUSTOMER_NAME="${customer_name}"
CUSTOMER_ORG="${customer_org}"
CUSTOMER_ENV="${customer_env}"
APP_NAME="${app_name}"

handle_error() {
    echo "[ERROR] ${2} (Exit Code: ${1})" >&2
    exit "${1}"
}
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${1}" | tee -a "${LOG_FILE}"
}



# Function to install Datadog Agent
install_datadog_agent() {
    log "Starting Datadog Agent installation..."
    BACKUP_DIR="/opt/dd-conf-backup"
    # Install Datadog Agent
    DD_SITE="datadoghq.com"   # Replace with actual site if different
    DD_AGENT_MAJOR_VERSION=7 DD_API_KEY=$DATADOG_API_KEY DD_SITE=$DD_SITE bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)" || handle_error $? "Datadog Agent installation failed"   

    log "Datadog Agent installation completed."

    # Take a backup of the Datadog configuration
    log "Backing up existing Datadog configuration..."
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/datadog-agent/* "$BACKUP_DIR/" || handle_error $? "Datadog configuration backup failed"   
    log "Configuration backed up to $BACKUP_DIR"

    # Update Datadog configuration
    log "Updating Datadog configuration..."
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
  - server_type: $APP_NAME
EOL
    log "Datadog configuration file updated successfully"

    # Set permissions for datadog.yaml
    setup_permissions "/etc/datadog-agent/datadog.yaml" 640 || exit 1

    # create auth token file
    log "creating auth token file"
    AUTH_TOKEN_FILE="/etc/datadog-agent/auth_token"
    if [ ! -f "$AUTH_TOKEN_FILE" ]; then
        if openssl rand -hex 32 > "$AUTH_TOKEN_FILE" 2>/dev/null; then
            setup_permissions "$AUTH_TOKEN_FILE" 600 || exit 1
            log "Auth token file created successfully"
        else
            log "Failed to create auth token file"
            exit 1
        fi
    else
        log "Auth token file exists, updating permissions"
        setup_permissions "$AUTH_TOKEN_FILE" 600 || exit 1
    fi

    # Enable the process module
    log "Enabling the system probe and process module..."
    cat > /etc/datadog-agent/system-probe.yaml <<EOL
system_probe_config:
    enabled: true
    process_config:
        enabled: true
EOL
    log "System probe configuration updated successfully"

    # Set permissions for system-probe.yaml
    setup_permissions "/etc/datadog-agent/system-probe.yaml" 600 || exit 1

    # Create and set permissions for environment file
    touch /etc/datadog-agent/environment
    setup_permissions "/etc/datadog-agent/environment" 600 || exit 1

    # Clear any existing agent state
    log "Clearing existing agent state..."
    rm -f /opt/datadog-agent/run/*.pid || true
    rm -f /var/run/datadog-agent/*.pid || true

    # Stop all Datadog services
    log "Stopping Datadog services..."
    systemctl stop datadog-agent datadog-agent-process datadog-agent-trace datadog-agent-security || true
    systemctl stop datadog-agent-sysprobe || true

    # Start services in correct order
    log "Starting Datadog services..."
    if systemctl start datadog-agent-sysprobe; then
        log "System probe service started successfully"
        sleep 2
        if systemctl start datadog-agent; then
            log "Datadog agent started successfully"
        else
            log "Failed to start Datadog agent" "ERROR"
            exit 1
        fi
    else
        log "Failed to start system probe service" "ERROR"
        exit 1
    fi

    # Add dd-agent to the docker group
    log "Adding dd-agent to the Docker group..."
    if usermod -a -G docker dd-agent; then
        log "dd-agent added to Docker group successfully"
    else
        log "Failed to add dd-agent to Docker group" "ERROR"
        exit 1
    fi

    # Enable syslog monitoring
    log "Configuring syslog monitoring..."
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
        log "Syslog configuration updated successfully"
    else
        log "Failed to update syslog configuration" "ERROR"
        exit 1
    fi

    # Set ACL for log files
    for log_file in "/var/log/messages" "/var/log/error.log" "/var/log/debug.log"; do
        if [ -f "$log_file" ]; then
            if setfacl -m u:dd-agent:r "$log_file"; then
                log "ACL updated successfully for $log_file"
            else
                log "Failed to update ACL for $log_file" "ERROR"
                exit 1
            fi
        else
            touch "$log_file"
            chmod 644 "$log_file"
            if setfacl -m u:dd-agent:r "$log_file"; then
                log "Created and set ACL for $log_file"
            else
                log "Failed to create and set ACL for $log_file" "ERROR"
                exit 1
            fi
        fi
    done

    # Restart the Datadog Agent
    log "Restarting the Datadog Agent..."
    if systemctl restart datadog-agent; then
        log "Datadog Agent restarted successfully"
    else
        log "Failed to restart Datadog Agent" "ERROR"
        exit 1
    fi
    if systemctl enable datadog-agent; then
        log "Datadog Agent enabled successfully"
    else
        log "Failed to enable Datadog Agent" "ERROR"
        exit 1
    fi

    # Verify the installation
    log "Performing verification steps..."
    sleep 10
    if systemctl is-active datadog-agent; then
        log "Datadog Agent status verified successfully"
    else
        log "Failed to verify Datadog Agent status" "ERROR"
        exit 1
    fi
    if datadog-agent configcheck; then
        log "Datadog Agent configuration verified successfully"
    else
        log "Failed to verify Datadog Agent configuration" "ERROR"
        exit 1
    fi
    if datadog-agent status; then
        log "Datadog Agent status verified successfully"
    else
        log "Failed to verify Datadog Agent status" "ERROR"
        exit 1
    fi

    log "Datadog Agent installation and configuration completed successfully!"
}

# Function to set up file permissions
setup_permissions() {
    local file="$1"
    local perms="$2"
    
    if ! chmod "$perms" "$file"; then
        log "Failed to set permissions $perms on $file"
        return 1
    fi
    
    if ! chown dd-agent:dd-agent "$file"; then
        log "Failed to set ownership on $file"
        return 1
    fi
    
    return 0
}

set_hostname() {
    # Get the first letter of environment
    local env_prefix="${CUSTOMER_ENV:0:1}"
    
    # Get availability zone and its last letter
    local az=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    local az_suffix="${az: -1}"
    
    # Convert customer org to lowercase and remove spaces
    local org=$(echo "${CUSTOMER_ORG}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    # Construct hostname
    local hostname="${env_prefix}-guac-${org}-${az_suffix}"
    
    # Set the hostname
    hostnamectl set-hostname "${hostname}"
    echo "${hostname}" > /etc/hostname
    
    # Make hostname available immediately in current shell
    export HOSTNAME="${hostname}"
    hostname "${hostname}"
    
    log "Hostname set to: ${hostname}"
    
    # Verify the change
    local current_hostname=$(hostname)
    if [ "${current_hostname}" != "${hostname}" ]; then
        handle_error 1 "Failed to set hostname. Expected: ${hostname}, Got: ${current_hostname}"
    fi
}

install_packages() {
    yum install -y "$@" || handle_error $? "Failed to install packages: $*"
}

setup_services() {
    local service=$1
    systemctl daemon-reload
    systemctl enable "${service}"
    systemctl restart "${service}" || handle_error $? "Failed to restart ${service}"
}

install_aws_cli() {
    if ! command -v aws &>/dev/null; then
        log "Installing AWS CLI..."
        curl "${AWS_CLI_URL}" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        ./aws/install
    rm -rf aws awscliv2.zip
fi
}

setup_docker() {
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin jq
    mkdir -p /var/run
    setup_services docker
    
    [ -S /var/run/docker.sock ] && chmod 666 /var/run/docker.sock
    groupadd -f docker
    usermod -aG docker ec2-user root
}

main() {
    exec 1> >(tee -a "${LOG_FILE}")
    exec 2> >(tee -a "${LOG_FILE}" >&2)
    # Ensure log file exists
    sudo touch $LOG_FILE
    sudo chmod 666 $LOG_FILE
    log "Starting setup..."
    set_hostname
    yum update -y
    install_packages unzip
    install_packages "${SSM_AGENT_URL}"
    setup_services amazon-ssm-agent
    install_aws_cli
    install_datadog_agent
    yum clean all
    rm -rf /var/cache/yum
    yum clean metadata packages
    install_packages realmd openldap-clients krb5-workstation chrony sssd-tools sssd adcli \
        samba-common samba-common-tools oddjob oddjob-mkhomedir wget telnet strace bind-utils \
        traceroute net-tools gcc python3 python3-devel python3-pip python3-setuptools postgresql \
        glibc-headers glibc-devel yum-utils
    setup_services chronyd
    setup_docker
    log "Setup completed successfully!"
}

main
