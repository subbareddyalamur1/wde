data "archive_file" "windows_scripts" {
  source_dir  = "${path.module}/scripts/windows"
  output_path = "${path.module}/windows_scripts.zip"
  type        = "zip"
  excludes    = ["**/guacamole/*", "**/lambda/*"]   
}

resource "aws_s3_object" "scripts_zip" {
  bucket = local.config_s3_bucket   
  key    = "${local.resource_name}/windows_scripts.zip"
  source = data.archive_file.windows_scripts.output_path
  etag   = filemd5(data.archive_file.windows_scripts.output_path)
}
