# # How to deploy/create new WDE infra

### 1. Clone github repo
```
git clone https://github.com/subbareddyalamur1/wde.git
```
or
```
git clone git@github.com:subbareddyalamur1/wde.git
```
### 2. Create inputs.yaml file under deployment_inputs/CUSTOMER_NAME/CUSTOMER_ORG/CUSTOMER_ENV/
```
cat inputs.yaml

tf_state_bucket_name: "tf-deployment-state-files-dev"
tf_state_path: "Syc/syc12/dev/wde2/terraform.tfstate"

customer_name: "syc"
customer_org: "syc12"
customer_env: "dev"
app_name: "wde"
app_version: "1.1.0.0"
aws_region: "us-east-1"

vpc_config:
  vpc_id: "vpc-0b7257119a1b264a4"
  availability_zones:
    us-east-1a:
      private_subnet_id: "subnet-010b34e74203d4678" # Core-Subnet-1a-SCE-4.2.2.2-Syc-syc12-staging-Private
      public_subnet_id: "subnet-07abb906f0589ccb8"  # Public-Subnet-1a-SCE-4.2.2.2-Syc-syc12-staging-Public
    us-east-1b:
      private_subnet_id: "subnet-03776bd87836817f7" # Core-Subnet-1b-SCE-4.2.2.2-Syc-syc12-staging-Private
      public_subnet_id: "subnet-0ddee0daedf59c7b1"  # Public-Subnet-1b-SCE-4.2.2.2-Syc-syc12-staging-Public

server_config:
  guacamole:
      instance_type: "t2.micro"
      ami: "ami-0d5d9d301c853a04a"
      instance_volume_size: 50
      availability_zones: 
        - "us-east-1a"
        - "us-east-1b"
      sg_rules:
        ingress:
        - port: -1
          protocol: all
          cidr: "10.30.0.0/16"
        - port: 80
          protocol: tcp
          cidr: "0.0.0.0/0"
        - port: 443
          protocol: tcp
          cidr: "0.0.0.0/0"
        - port: 3389
          protocol: rdp
          cidr: "10.30.0.0/16"
        egress:
        - port: -1
          protocol: all
          cidr: "0.0.0.0/0"
  windows_server:
      instance_type: "t3.medium"
      ami: "ami-0d0e8b294f5fa3e60"
      instance_volume_size: 50
      asg_min_size: 1
      asg_max_size: 2
      asg_desired_capacity: 1
      availability_zones: 
        - "us-east-1a"
      sg_rules:
        ingress:
        - port: -1
          protocol: all
          cidr: "10.30.0.0/16"
        - port: 445
          protocol: tcp
          cidr: "10.30.0.0/16"
        - port: 389
          protocol: tcp
          cidr: "10.30.0.0/16"
        egress:
        - port: -1
          protocol: all
          cidr: "0.0.0.0/0"

windows_instance_type: "t2.micro"
windows_ami: "ami-0d5d9d301c853a04a"
windows_instance_volume_size: 50

tags: {
  "Application": "WDE",
  "VpcId": "vpc-0b7257119a1b264a4",
  "Environment": "dev",
  "Customer": "Syc",
  "ProjectCode": "SYC-SYC12-WDE",
  "Work Load": "WDE-1.2",
  "Cost Center": "SnGA"
}
```

### 3. Navigate to IaC directory and use makefile to init, plan and apply terraform code.
```
cd IaC
make init CUSTOMER_NAME=syc CUSTOMER_ORG=syc12 CUSTOMER_ENV=dev
```

### 4. Make sure above inputs.yaml file is copied into IaC directory and backend.tf file is generated

### 5. Execute make plan to generate terraform plan
```
make plan
```

### 6. Verify plan and apply terraform by
```
make apply
```

### 7. If you need to destroy the infra created
```
make plan-destroy # to generate destroy plan

make destroy # to destroy resource created.
```

### Cleanup IaC directory finally. To remove inputs.yaml and backend.tf from IaC directory
```
make clean
```

