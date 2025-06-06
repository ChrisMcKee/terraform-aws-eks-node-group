locals {
  # The heavy use of the ternary operator `? :` is because it is one of the few ways to avoid
  # evaluating expressions. The unused expression is not evaluated and so it does not have to be valid.
  # This allows us to refer to resources that are only conditionally created and avoid creating
  # dependencies on them that would not be avoided by using expressions like `join("",expr)`.
  #
  # We use this pattern with enabled for every boolean that begins with `need_` even though
  # it is sometimes redundant, to ensure that ever `need_` is false and every dependent
  # expression is not evaluated when enabled is false. Avoiding expression evaluations
  # is also why, even for boolean expressions, we use
  #   local.enabled ? expression : false
  # rather than
  #   local.enabled && expression
  #
  # The expression
  #   length(compact([var.launch_template_version])) > 0
  # is a shorter way of accomplishing the same test as
  #   var.launch_template_version != null && var.launch_template_version != ""
  # and as an idiom has the added benefit of being extensible:
  #   length(compact([x, y])) > 0
  # is the same as
  #   x != null && x != "" && y != null && y != ""

  # We now always use a launch template. The only question is whether or not we generate one.
  launch_template_configured = length(var.launch_template_id) == 1
  generate_launch_template   = local.enabled && local.launch_template_configured == false
  fetch_launch_template      = local.enabled && local.launch_template_configured

  launch_template_id = local.enabled ? (local.fetch_launch_template ? var.launch_template_id[0] : aws_launch_template.default[0].id) : ""
  launch_template_version = local.enabled ? (length(var.launch_template_version) == 1 ? var.launch_template_version[0] : (
    local.fetch_launch_template ? data.aws_launch_template.this[0].latest_version : aws_launch_template.default[0].latest_version
  )) : null

  launch_template_ami = local.ami_id

  associate_cluster_security_group = local.enabled && var.associate_cluster_security_group
  launch_template_vpc_security_group_ids = sort(compact(concat(
    local.associate_cluster_security_group ? data.aws_eks_cluster.this[*].vpc_config[0].cluster_security_group_id : [],
    module.ssh_access[*].id,
    var.associated_security_group_ids
  )))

  # Create a launch template configuration object to use for managing node group updates
  launch_template_config = {
    ebs_optimized         = var.ebs_optimized
    block_device_mappings = local.block_device_map
    image_id              = local.launch_template_ami
    key_name              = local.ec2_ssh_key_name
    tag_specifications    = var.resources_to_tag
    metadata_options = {
      # Despite being documented as "Optional", `http_endpoint` is required when `http_put_response_hop_limit` is set.
      # We set it to the default setting of "enabled".
      http_endpoint               = var.metadata_http_endpoint_enabled ? "enabled" : "disabled"
      http_put_response_hop_limit = var.metadata_http_put_response_hop_limit
      http_tokens                 = var.metadata_http_tokens_required ? "required" : "optional"
    }
    vpc_security_group_ids = local.launch_template_vpc_security_group_ids
    user_data              = local.userdata
    tags                   = local.node_group_tags
    cpu_options            = var.cpu_options
    placement              = var.placement
    enclave_options        = var.enclave_enabled ? ["true"] : []
    monitoring = {
      enabled = var.detailed_monitoring_enabled
    }
  }
}

resource "aws_launch_template" "default" {
  # We'll use this if we aren't provided with a launch template during invocation.
  # We would like to generate a new launch template every time the security group list changes
  # so that we can detach the network interfaces from the security groups that we no
  # longer need, so that the security groups can then be deleted, but we cannot guarantee
  # that because the security group IDs are not available at plan time. So instead
  # we have to rely on `create_before_destroy` and `depends_on` to arrange things properly.

  count = local.generate_launch_template ? 1 : 0

  ebs_optimized = local.launch_template_config.ebs_optimized

  dynamic "block_device_mappings" {
    for_each = local.launch_template_config.block_device_mappings

    content {
      device_name  = block_device_mappings.key
      no_device    = block_device_mappings.value.no_device
      virtual_name = block_device_mappings.value.virtual_name

      dynamic "ebs" {
        for_each = block_device_mappings.value.ebs == null ? [] : [block_device_mappings.value.ebs]

        content {
          delete_on_termination = ebs.value.delete_on_termination
          encrypted             = ebs.value.encrypted
          iops                  = ebs.value.iops
          kms_key_id            = ebs.value.kms_key_id
          snapshot_id           = ebs.value.snapshot_id
          throughput            = ebs.value.throughput
          volume_size           = ebs.value.volume_size
          volume_type           = ebs.value.volume_type
        }
      }
    }
  }

  name_prefix            = module.label.id
  update_default_version = true

  # Never include instance type in launch template because it is limited to just one
  # https://docs.aws.amazon.com/eks/latest/APIReference/API_CreateNodegroup.html#API_CreateNodegroup_RequestSyntax
  image_id = local.launch_template_config.image_id
  key_name = local.launch_template_config.key_name

  dynamic "tag_specifications" {
    for_each = local.launch_template_config.tag_specifications
    content {
      resource_type = tag_specifications.value
      tags          = local.node_tags
    }
  }

  # See https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
  # and https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html
  # Note in particular:
  #     If any containers that you deploy to the node group use the Instance Metadata Service Version 2,
  #     then make sure to set the Metadata response hop limit to at least 2 in your launch template.
  metadata_options {
    # Despite being documented as "Optional", `http_endpoint` is required when `http_put_response_hop_limit` is set.
    # We set it to the default setting of "enabled".

    http_endpoint               = local.launch_template_config.metadata_options.http_endpoint
    http_put_response_hop_limit = local.launch_template_config.metadata_options.http_put_response_hop_limit
    http_tokens                 = local.launch_template_config.metadata_options.http_tokens
  }

  vpc_security_group_ids = local.launch_template_config.vpc_security_group_ids
  user_data              = local.launch_template_config.user_data
  tags                   = local.launch_template_config.tags

  dynamic "cpu_options" {
    for_each = local.launch_template_config.cpu_options

    content {
      core_count       = lookup(cpu_options.value, "core_count", null)
      threads_per_core = lookup(cpu_options.value, "threads_per_core", null)
    }
  }

  dynamic "placement" {
    for_each = local.launch_template_config.placement

    content {
      affinity                = lookup(placement.value, "affinity", null)
      availability_zone       = lookup(placement.value, "availability_zone", null)
      group_name              = lookup(placement.value, "group_name", null)
      host_id                 = lookup(placement.value, "host_id", null)
      host_resource_group_arn = lookup(placement.value, "host_resource_group_arn", null)
      spread_domain           = lookup(placement.value, "spread_domain", null)
      tenancy                 = lookup(placement.value, "tenancy", null)
      partition_number        = lookup(placement.value, "partition_number", null)
    }
  }

  dynamic "enclave_options" {
    for_each = local.launch_template_config.enclave_options

    content {
      enabled = true
    }
  }

  monitoring {
    enabled = local.launch_template_config.monitoring.enabled
  }

  lifecycle {
    # See userdata.tf for authoritative details. This is here because it has to be on a resource, and no resources are defined in userdata.tf
    #
    # Supported OSes: AL2, AL2023, BOTTLEROCKET, WINDOWS
    # Userdata inputs: before_cluster_joining_userdata, kubelet_additional_options, bootstrap_additional_options, after_cluster_joining_userdata
    # We test local.userdata_vars because they have been massaged and perhaps augmented, and we want to
    # test the final form, even if it means giving a confusing error message at times.
    # We list supported OSes explicitly to catch any new ones that are added.
    precondition {
      condition     = contains(["AL2", "AL2023", "WINDOWS"], local.ami_os) || length(local.userdata_vars.before_cluster_joining_userdata) == 0 || (local.ami_os == "AL2" || local.ami_os == "WINDOWS")
      error_message = format("The input `before_cluster_joining_userdata` is not supported for %v.", title(lower(local.ami_os)))
    }
    precondition {
      condition     = contains(["AL2", "WINDOWS"], local.ami_os) || length(local.userdata_vars.bootstrap_extra_args) == 0
      error_message = format("The input `bootstrap_additional_options` is not supported for %v.", title(lower(local.ami_os)))
    }
    precondition {
      condition     = contains(["AL2", "AL2023", "WINDOWS"], local.ami_os) || length(local.userdata_vars.kubelet_extra_args) == 0 || (local.ami_os == "AL2" || local.ami_os == "WINDOWS")
      error_message = format("The input `kubelet_additional_options` is not supported for %v.", title(lower(local.ami_os)))
    }
    precondition {
      condition     = contains(["AL2", "WINDOWS"], local.ami_os) || length(local.userdata_vars.after_cluster_joining_userdata) == 0 || (local.ami_os == "AL2" || local.ami_os == "WINDOWS")
      error_message = format("The input `after_cluster_joining_userdata` is not supported for %v.", title(lower(local.ami_os)))
    }
    precondition {
      condition     = length(local.userdata_vars.after_cluster_joining_userdata) == 0 || length(var.ami_image_id) != 0 && length(local.userdata_vars.after_cluster_joining_userdata) > 0 && (local.ami_os == "AL2" || local.ami_os == "WINDOWS")
      error_message = format("The input `after_cluster_joining_userdata` is not supported for %v, a custom ami_image_id must be set for this functionality", title(lower(local.ami_os)))
    }
  }
}

data "aws_launch_template" "this" {
  count = local.fetch_launch_template ? 1 : 0

  id = var.launch_template_id[0]
}
