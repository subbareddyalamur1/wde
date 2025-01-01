terraform {
  backend "s3" {
    bucket = "tf-deployment-state-files-dev"
    key    = "Syc/syc12/dev/wde2/terraform.tfstate"
    region = "us-east-1"
  }
}
