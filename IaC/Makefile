# Variables
SHELL := /bin/bash
MY_IP := $(shell dig @resolver4.opendns.com myip.opendns.com +short -4)

# Required parameters validation only for init
ifneq ($(filter init,$(MAKECMDGOALS)),)
  ifeq ($(CUSTOMER_NAME),)
    $(error CUSTOMER_NAME is required for init. Usage: make init CUSTOMER_NAME=<name> CUSTOMER_ORG=<org> CUSTOMER_ENV=<env>)
  endif
  ifeq ($(CUSTOMER_ORG),)
    $(error CUSTOMER_ORG is required for init. Usage: make init CUSTOMER_NAME=<name> CUSTOMER_ORG=<org> CUSTOMER_ENV=<env>)
  endif
  ifeq ($(CUSTOMER_ENV),)
    $(error CUSTOMER_ENV is required for init. Usage: make init CUSTOMER_NAME=<name> CUSTOMER_ORG=<org> CUSTOMER_ENV=<env>)
  endif
endif

# Set input file path
INPUT_FILE := ../deployment_inputs/$(CUSTOMER_NAME)/$(CUSTOMER_ORG)/$(CUSTOMER_ENV)/inputs.yaml

# Default target
.PHONY: all
all: plan apply

# Copy inputs.yaml from deployment location
.PHONY: copy-inputs
copy-inputs:
	@echo "Copying inputs.yaml from $(INPUT_FILE)..."
	@if [ ! -f "$(INPUT_FILE)" ]; then \
		echo "Error: Input file not found at $(INPUT_FILE)"; \
		exit 1; \
	fi
	@cp $(INPUT_FILE) .

# Create backend.tf
.PHONY: create-backend
create-backend: copy-inputs
	@echo "Creating backend.tf..."
	@if [ ! -f inputs.yaml ]; then \
		echo "Error: inputs.yaml not found after copy. Something went wrong."; \
		exit 1; \
	fi
	@echo "terraform {" > backend.tf
	@echo "  backend \"s3\" {" >> backend.tf
	@echo "    bucket = \"$(shell grep tf_state_bucket_name inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "    key    = \"$(shell grep tf_state_path inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "    region = \"$(shell grep aws_region inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "  }" >> backend.tf
	@echo "}" >> backend.tf

# Initialize Terraform
.PHONY: init
init: copy-inputs create-backend
	@echo "Initializing Terraform..."
	@if [ ! -f "inputs.yaml" ]; then \
		echo "Error: inputs.yaml not found after copy. Something went wrong."; \
		exit 1; \
	fi
	@sed -i '' "s/my_ip:.*/my_ip: \"$(MY_IP)\/32\"/" inputs.yaml
	@terraform init

# Plan changes
.PHONY: plan
plan: 
	@echo "Planning Terraform changes..."
	terraform plan

# Apply changes
.PHONY: apply
apply: 
	@echo "Applying Terraform changes..."
	terraform apply -auto-approve

# Plan Terraform destroy
.PHONY: plan-destroy
plan-destroy: 
	@echo "Planning Terraform destroy..."
	terraform plan -destroy

# Destroy infrastructure
.PHONY: destroy
destroy: 
	@echo "Destroying Terraform resources..."
	terraform destroy -auto-approve

# Clean up
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f backend.tf
	rm -f inputs.yaml
	rm -rf .terraform
	rm -f .terraform.lock.hcl
	rm -f terraform.tfstate*
	rm -f *.zip

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  init         - Initialize Terraform (requires CUSTOMER_NAME, CUSTOMER_ORG, CUSTOMER_ENV)"
	@echo "  plan         - Plan Terraform changes"
	@echo "  apply        - Apply Terraform changes"
	@echo "  plan-destroy - Plan Terraform destroy"
	@echo "  destroy      - Destroy Terraform resources"
	@echo "  clean        - Clean up generated files"
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Init command requires parameters:"
	@echo "  CUSTOMER_NAME - Customer name"
	@echo "  CUSTOMER_ORG  - Customer organization"
	@echo "  CUSTOMER_ENV  - Customer environment"
	@echo ""
	@echo "Example:"
	@echo "  make init CUSTOMER_NAME=syc CUSTOMER_ORG=syc12 CUSTOMER_ENV=dev"
	@echo "  make plan"
	@echo "  make apply"