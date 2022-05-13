##############################################################################
# Resource Group
##############################################################################

module "resource_group" {
  source = "git::https://github.ibm.com/GoldenEye/resource-group-module.git?ref=1.0.1"
  # if an existing resource group is not set (null) create a new one using prefix
  resource_group_name          = var.resource_group == null ? "${var.prefix}-resource-group" : null
  existing_resource_group_name = var.resource_group
}

##############################################################################
# ACL Profile
##############################################################################

module "acl_profile" {
  source = "git::https://github.ibm.com/GoldenEye/acl-profile-ocp.git?ref=1.0.14"
}

##############################################################################
# VPC
##############################################################################

locals {
  vpc_cidr_bases = {
    private = "192.168.0.0/20",
    transit = "192.168.16.0/20",
    edge    = "192.168.32.0/20"
  }
}

module "vpc" {
  source            = "git::https://github.ibm.com/GoldenEye/vpc-module.git?ref=2.2.1"
  unique_name       = "${var.prefix}-vpc"
  ibm_region        = var.region
  resource_group_id = module.resource_group.resource_group_id
  cidr_bases        = local.vpc_cidr_bases
  acl_rules_map = {
    private = concat(
      module.acl_profile.base_acl,
      module.acl_profile.https_acl,
      module.acl_profile.deny_all_acl
    )
  }
  virtual_private_endpoints = {}
  vpc_tags                  = var.resource_tags
}

##############################################################################
# KMS Layer
# (Will be replaced by KMS module)
##############################################################################

resource "ibm_resource_instance" "kms_instance" {
  name              = "${var.prefix}-kms"
  service           = "kms"
  plan              = "tiered-pricing"
  location          = var.region
  resource_group_id = module.resource_group.resource_group_id
  service_endpoints = "public-and-private"
}

resource "ibm_kms_key_rings" "kms_key_ring" {
  instance_id = ibm_resource_instance.kms_instance.guid
  key_ring_id = "${var.prefix}-key-ring"
}

##############################################################################
# Observability Instances (LogDNA + Sysdig)
##############################################################################

module "observability_instances" {
  source                     = "git::https://github.ibm.com/GoldenEye/observability-instances-module?ref=4.1.2"
  region                     = var.region
  resource_group_id          = module.resource_group.resource_group_id
  activity_tracker_provision = false
  logdna_instance_name       = "${var.prefix}-logdna"
  sysdig_instance_name       = "${var.prefix}-sysdig"
  logdna_plan                = "7-day"
  sysdig_plan                = "graduated-tier"
  enable_platform_logs       = false
  enable_platform_metrics    = false
  logdna_tags                = var.resource_tags
  sysdig_tags                = var.resource_tags
}

##############################################################################
# Service Mesh Control Plane Profile
##############################################################################

locals {
  sample_app_namespace = "bookinfo"
}

module "service_mesh_profiles" {
  source              = "git::https://github.ibm.com/GoldenEye/ocp-service-mesh-module.git//ocp-service-mesh-profiles?ref=1.17.0"
  enrolled_namespaces = [local.sample_app_namespace]
}

##############################################################################
# OCP All Inclusive Module
##############################################################################
locals {
  # OCP private worker pool (default pool) requires minimum of 2 workers
  # If only single zone is used (such as for testing), force to 2, otherwise leave at 1 per zone
  private_worker_nodes_per_zone = length(var.cluster_zone_list) > 1 ? "1" : "2"
}

module "ocp_all_inclusive" {
  source                        = "../.."
  ibmcloud_api_key              = var.ibmcloud_api_key
  resource_group_id             = module.resource_group.resource_group_id
  region                        = var.region
  prefix                        = var.prefix
  vpc_id                        = module.vpc.vpc_id
  vpc_subnets                   = module.vpc.subnets
  cluster_zone_list             = var.cluster_zone_list
  private_worker_nodes_per_zone = local.private_worker_nodes_per_zone
  edge_worker_nodes_per_zone    = "1"
  transit_worker_nodes_per_zone = "1"
  ocp_version                   = var.ocp_version
  cluster_tags                  = var.resource_tags
  logdna_instance_name          = module.observability_instances.logdna_name
  logdna_ingestion_key          = module.observability_instances.logdna_ingestion_key
  sysdig_instance_name          = module.observability_instances.sysdig_name
  sysdig_access_key             = module.observability_instances.sysdig_access_key
  service_mesh_control_planes   = [module.service_mesh_profiles.public_ingress_egress_no_transit]
  kms_instance_id               = ibm_resource_instance.kms_instance.guid
  kms_key_ring_id               = ibm_kms_key_rings.kms_key_ring.key_ring_id
  kms_use_private_endpoint      = true
  create_kms_root_key           = true
}

##############################################################################
# Deploy BookInfo sample app
##############################################################################

resource "helm_release" "bookinfo" {
  depends_on = [module.ocp_all_inclusive]

  name                       = "bookinfo-sample-istio-app"
  chart                      = "sample-app-chart/bookinfo"
  namespace                  = local.sample_app_namespace
  create_namespace           = false
  timeout                    = 300
  cleanup_on_fail            = true
  wait                       = true
  disable_openapi_validation = false
}
