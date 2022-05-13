##############################################################################
# base-ocp-vpc-module
##############################################################################

locals {
  cluster_zones = formatlist("${var.region}-%s", var.cluster_zone_list)

  cluster_vpc_subnets = {
    private = [
      for zone in var.vpc_subnets.private :
      {
        id         = zone.id
        zone       = zone.zone
        cidr_block = zone.cidr_block
      } if contains(local.cluster_zones, zone.zone)
    ],
    edge = [
      for zone in var.vpc_subnets.edge :
      {
        id         = zone.id
        zone       = zone.zone
        cidr_block = zone.cidr_block
      } if contains(local.cluster_zones, zone.zone)
    ],
    transit = [
      for zone in var.vpc_subnets.transit :
      {
        id         = zone.id
        zone       = zone.zone
        cidr_block = zone.cidr_block
      } if contains(local.cluster_zones, zone.zone)
    ]
  }

  ocp_worker_pools = [
    {
      subnet_prefix = "private"
      # Default pool name cannot be renamed using ibm_container_vpc_cluster (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      pool_name        = "default"
      machine_type     = var.private_worker_machine_type
      workers_per_zone = var.private_worker_nodes_per_zone
      labels           = var.private_worker_labels
    },
    {
      subnet_prefix    = "edge"
      pool_name        = "edge"
      machine_type     = var.edge_worker_machine_type
      workers_per_zone = var.edge_worker_nodes_per_zone
      labels           = var.edge_worker_labels
    },
    {
      subnet_prefix    = "transit"
      pool_name        = "transit"
      machine_type     = var.transit_worker_machine_type
      workers_per_zone = var.transit_worker_nodes_per_zone
      labels           = var.transit_worker_labels
    }
  ]

  worker_pools_taints = {
    all = []
    transit = [
      {
        key   = "dedicated"
        value = "transit"
        # Pod is evicted from the node if it is already running on the node,
        # and is not scheduled onto the node if it is not yet running on the node.
        effect = "NoExecute"
      }
    ]
    edge = [
      {
        key   = "dedicated"
        value = "edge"
        # Pod is evicted from the node if it is already running on the node,
        # and is not scheduled onto the node if it is not yet running on the node.
        effect = "NoExecute"
      }
    ]
    default = []
  }

  kms_config = var.kms_instance_id == null ? null : {
    crk_id           = var.kms_root_key_id == null ? ibm_kms_key.kube_root_key[0].key_id : var.kms_root_key_id
    instance_id      = var.kms_instance_id
    private_endpoint = var.kms_use_private_endpoint
  }

  # Fail fast if create_kms_root_key is true and no instance ID provided
  kms_instance_validate_cdn = (var.create_kms_root_key && var.kms_instance_id != null) || (!var.create_kms_root_key)
  kms_instance_validate_msg = "'create_kms_root_key' is true and 'kms_instance_id' is null"
  # tflint-ignore: terraform_unused_declarations
  kms_instance_validate_check = regex("^${local.kms_instance_validate_msg}$", (local.kms_instance_validate_cdn ? local.kms_instance_validate_msg : ""))

  # Fail fast if create_kms_root_key is true and kms_root_key_id is also provided
  kms_key_validate_cdn = (var.create_kms_root_key && var.kms_root_key_id == null) || (!var.create_kms_root_key)
  kms_key_validate_msg = "'create_kms_root_key' is true and 'kms_root_key_id' was not null"
  # tflint-ignore: terraform_unused_declarations
  kms_key_validate_check = regex("^${local.kms_key_validate_msg}$", (local.kms_key_validate_cdn ? local.kms_key_validate_msg : ""))
}

module "ocp_base" {
  depends_on = [
    ibm_kms_key_policies.kube_root_key_policy[0]
  ]
  source                          = "git::https://github.ibm.com/GoldenEye/base-ocp-vpc-module.git?ref=1.12.1"
  cluster_name                    = "${var.prefix}-cluster"
  ocp_version                     = var.ocp_version
  resource_group_id               = var.resource_group_id
  region                          = var.region
  tags                            = var.cluster_tags
  force_delete_storage            = var.force_delete_storage
  vpc_id                          = var.vpc_id
  vpc_subnets                     = local.cluster_vpc_subnets
  worker_pools                    = local.ocp_worker_pools
  cluster_ready_when              = var.cluster_ready_when
  worker_pools_taints             = local.worker_pools_taints
  cos_name                        = "${var.prefix}-cos"
  ocp_entitlement                 = var.ocp_entitlement
  disable_public_endpoint         = var.disable_public_endpoint
  ignore_worker_pool_size_changes = var.ignore_worker_pool_size_changes
  kms_config                      = local.kms_config
}

##############################################################################
# cluster-proxy-module
##############################################################################

locals {
  # Force cluster-proxy pods to run on nodes with public access (aka edge nodes)
  cluster_proxy_node_selectors = [{
    label  = "ibm-cloud.kubernetes.io/worker-pool-name"
    values = ["edge"]
  }]

  cluster_proxy_tolerations = [{
    key    = "dedicated"
    value  = "edge"
    effect = "NoExecute"
  }]

  # Force cluster-proxy-node-config pods to run on nodes without public access
  cluster_proxy_node_config_node_selectors = [{
    label  = "ibm-cloud.kubernetes.io/worker-pool-name"
    values = ["default", "transit"]
  }]

  # Default (private) pool has no taints, so no need to add any tolerations to run there
  cluster_proxy_node_config_tolerations = [
    {
      key    = "dedicated"
      value  = "transit"
      effect = "NoExecute"
  }]
}

module "cluster_proxy" {
  source                                   = "git::https://github.ibm.com/GoldenEye/cluster-proxy-module.git?ref=2.4.12"
  cluster_id                               = module.ocp_base.cluster_id
  cluster_proxy_node_selectors             = local.cluster_proxy_node_selectors
  cluster_proxy_tolerations                = local.cluster_proxy_tolerations
  cluster_proxy_node_config_node_selectors = local.cluster_proxy_node_config_node_selectors
  cluster_proxy_node_config_tolerations    = local.cluster_proxy_node_config_tolerations
}

##############################################################################
# observability-agents-module
##############################################################################

locals {
  # Locals
  run_observability_agents_module = (local.provision_logdna_agent == true || local.provision_sysdig_agent || local.provision_logdna_sts_agent) ? true : false
  provision_logdna_agent          = var.logdna_instance_name != null ? true : false
  provision_sysdig_agent          = var.sysdig_instance_name != null ? true : false
  provision_logdna_sts_agent      = var.logdna_sts_instance_name != null ? true : false
  logdna_resource_group_id        = var.logdna_resource_group_id != null ? var.logdna_resource_group_id : var.resource_group_id
  sysdig_resource_group_id        = var.sysdig_resource_group_id != null ? var.sysdig_resource_group_id : var.resource_group_id
  logdna_sts_resource_group_id    = var.logdna_sts_resource_group_id != null ? var.logdna_sts_resource_group_id : var.resource_group_id

  # Some inout variable validation (approach based on https://stackoverflow.com/a/66682419)
  logdna_validate_condition = var.logdna_instance_name != null && var.logdna_ingestion_key == null
  logdna_validate_msg       = "A value for var.logdna_ingestion_key must be passed when providing a value for var.logdna_instance_name"
  # tflint-ignore: terraform_unused_declarations
  logdna_validate_check     = regex("^${local.logdna_validate_msg}$", (!local.logdna_validate_condition ? local.logdna_validate_msg : ""))
  sysdig_validate_condition = var.sysdig_instance_name != null && var.sysdig_access_key == null
  sysdig_validate_msg       = "A value for var.sysdig_access_key must be passed when providing a value for var.sysdig_instance_name"
  # tflint-ignore: terraform_unused_declarations
  sysdig_validate_check         = regex("^${local.sysdig_validate_msg}$", (!local.sysdig_validate_condition ? local.sysdig_validate_msg : ""))
  logdna_sts_validate_condition = var.logdna_sts_instance_name != null && var.logdna_sts_ingestion_key == null
  logdna_sts_validate_msg       = "A value for var.logdna_sts_ingestion_key must be passed when providing a value for var.logdna_sts_instance_name"
  # tflint-ignore: terraform_unused_declarations
  logdna_sts_validate_check = regex("^${local.logdna_sts_validate_msg}$", (!local.logdna_sts_validate_condition ? local.logdna_sts_validate_msg : ""))
}

module "observability_agents" {
  # cluster-proxy required so observability images can be pulled from public registry
  depends_on = [module.cluster_proxy]

  count                        = local.run_observability_agents_module == true ? 1 : 0
  source                       = "git::https://github.ibm.com/GoldenEye/observability-agents-module?ref=2.1.14"
  cluster_id                   = module.ocp_base.cluster_id
  cluster_resource_group_id    = var.resource_group_id
  logdna_enabled               = local.provision_logdna_agent
  logdna_instance_name         = var.logdna_instance_name
  logdna_ingestion_key         = var.logdna_ingestion_key
  logdna_resource_group_id     = local.logdna_resource_group_id
  sysdig_enabled               = local.provision_sysdig_agent
  sysdig_instance_name         = var.sysdig_instance_name
  sysdig_access_key            = var.sysdig_access_key
  sysdig_resource_group_id     = local.sysdig_resource_group_id
  logdna_sts_provision         = local.provision_logdna_sts_agent
  logdna_sts_instance_name     = var.logdna_sts_instance_name
  logdna_sts_ingestion_key     = var.logdna_sts_ingestion_key
  logdna_sts_resource_group_id = local.logdna_sts_resource_group_id
}

##############################################################################
# ocp-console-patch-module
##############################################################################

module "ocp_console_patch" {
  # Explicit dependency required so edge worker nodes are created before patching the console pods
  depends_on = [module.ocp_base]

  source     = "git::https://github.ibm.com/GoldenEye/ocp-console-patch-module?ref=1.0.13"
  cluster_id = module.ocp_base.cluster_id
}

##############################################################################
# ocp-edge-ingress-module
##############################################################################

module "ocp_edge_ingress" {
  # Explicit dependency required so edge worker nodes are created before patching the console pods
  depends_on = [module.ocp_base]

  source           = "git::https://github.ibm.com/GoldenEye/ocp-edge-ingress-module?ref=1.0.4"
  cluster_id       = module.ocp_base.cluster_id
  ibmcloud_api_key = var.ibmcloud_api_key # pragma: allowlist secret
}

##############################################################################
# namespace-module
##############################################################################

locals {
  # Iterate through all control plane configs, and extract out all namespaces.
  # Generate map of namespaces in order to use for_each during namespace creation.
  namespaces = merge([
    for cp in var.service_mesh_control_planes :
    {
      for ns in cp.enrolled_namespaces :
      ns => {
        name      = cp.name
        namespace = ns
      }
    }
  ]...) # <-- the dots are important! Don't remove them
}

module "namespace" {
  # Explicit dependency required to workaround RBAC sync delay issue (https://github.com/IBM-Cloud/terraform-provider-ibm/issues/3171)
  depends_on = [module.ocp_base]

  for_each = local.namespaces
  source   = "git::https://github.ibm.com/GoldenEye/namespace-module.git?ref=1.0.0"
  namespaces = [
    {
      name = each.value.namespace
      metadata = {
        labels = {
          "istio-injection" = "enabled"
        }
        annotations = {
        }
      }
    }
  ]
}

##############################################################################
# ocp-service-mesh-module
##############################################################################

locals {
  run_service_mesh_module = var.service_mesh_control_planes != [] ? true : false
}

module "service_mesh" {
  count                       = local.run_service_mesh_module == true ? 1 : 0
  source                      = "git::https://github.ibm.com/GoldenEye/ocp-service-mesh-module?ref=1.17.1"
  depends_on                  = [module.cluster_proxy, module.namespace]
  cluster_id                  = module.ocp_base.cluster_id
  service_mesh_control_planes = var.service_mesh_control_planes
  lb_subnet_ids               = [for subnet in lookup(var.vpc_subnets, "edge") : lookup(subnet, "id")]
}

##############################################################################
# KMS Layer
##############################################################################

locals {
  kms_key_ring_id = var.kms_key_ring_id == null ? "default" : var.kms_key_ring_id
}

resource "ibm_kms_key" "kube_root_key" {
  count        = var.create_kms_root_key ? 1 : 0
  instance_id  = var.kms_instance_id
  key_name     = "kube-key-${var.prefix}"
  key_ring_id  = local.kms_key_ring_id
  standard_key = false
}

resource "ibm_kms_key_policies" "kube_root_key_policy" {
  count       = var.create_kms_root_key ? 1 : 0
  instance_id = var.kms_instance_id
  key_id      = ibm_kms_key.kube_root_key[0].key_id
  rotation {
    interval_month = 1
  }
  dual_auth_delete {
    enabled = false
  }
}
