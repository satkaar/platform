terraform {
  backend "s3" {
    bucket   = "mairie-agglo-platform-tfstate"
    key      = "envs/prod/terraform.tfstate"
    region   = "fr-par"
    endpoint = "https://s3.fr-par.scw.cloud"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
