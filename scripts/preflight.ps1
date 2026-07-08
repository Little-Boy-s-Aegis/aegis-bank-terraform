param(
  [ValidateSet("hackathon", "production", "both")]
  [string]$Profile = "both"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

terraform fmt -check -recursive
terraform validate -no-color

if ($Profile -eq "hackathon" -or $Profile -eq "both") {
  terraform plan "-var-file=environments/hackathon/terraform.tfvars" -refresh=false -input=false -no-color
}

if ($Profile -eq "production" -or $Profile -eq "both") {
  terraform plan "-var-file=environments/production/terraform.tfvars" -refresh=false -input=false -no-color
}
