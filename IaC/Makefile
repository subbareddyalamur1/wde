# Variables
SHELL := /bin/bash

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
  INPUT_FILE := ../deployment_inputs/$(CUSTOMER_NAME)/$(CUSTOMER_ORG)/$(CUSTOMER_ENV)/inputs.yaml
else
  # For other targets, get values from existing inputs.yaml if it exists
  CUSTOMER_NAME := $(shell if [ -f inputs.yaml ]; then grep customer_name inputs.yaml | cut -d':' -f2 | tr -d ' '; fi)
  CUSTOMER_ORG := $(shell if [ -f inputs.yaml ]; then grep customer_org inputs.yaml | cut -d':' -f2 | tr -d ' '; fi)
  CUSTOMER_ENV := $(shell if [ -f inputs.yaml ]; then grep customer_env inputs.yaml | cut -d':' -f2 | tr -d ' '; fi)
  INPUT_FILE := ../deployment_inputs/$(CUSTOMER_NAME)/$(CUSTOMER_ORG)/$(CUSTOMER_ENV)/inputs.yaml
endif

# Default target
.PHONY: all
all: plan apply

# Copy inputs.yaml from deployment location
.PHONY: copy-inputs
copy-inputs:
	@if [ ! -f inputs.yaml ]; then \
		echo "Error: inputs.yaml not found. Please run 'make init' first with required parameters."; \
		exit 1; \
	fi
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
	@echo "terraform {" > backend.tf
	@echo "  backend \"s3\" {" >> backend.tf
	@echo "    bucket = \"$(shell grep tf_state_bucket_name inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "    key    = \"$(shell grep tf_state_path inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "    region = \"$(shell grep aws_region inputs.yaml | cut -d':' -f2 | tr -d ' ')\"" >> backend.tf
	@echo "  }" >> backend.tf
	@echo "}" >> backend.tf

# Initialize Terraform
.PHONY: init
init: create-backend
	@echo "Initializing Terraform..."
	terraform init

# Plan Terraform changes
.PHONY: plan
plan: copy-inputs
	@echo "Planning Terraform changes..."
	terraform plan

# Apply Terraform changes
.PHONY: apply
apply: copy-inputs
	@echo "Applying Terraform changes..."
	terraform apply -auto-approve

# Plan Terraform destroy
.PHONY: plan-destroy
plan-destroy: copy-inputs
	@echo "Planning Terraform destroy..."
	terraform plan -destroy

# Destroy Terraform resources
.PHONY: destroy
destroy: copy-inputs
	@echo "Destroying Terraform resources..."
	terraform destroy -auto-approve

# Clean up generated files
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f backend.tf
	rm -f inputs.yaml
	rm -rf .terraform
	rm -f .terraform.lock.hcl
	rm -f terraform.tfstate*

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