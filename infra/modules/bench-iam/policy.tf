# The EC2 policy for the bench user.
#
# The Project tag is the security boundary. The user can change only the
# resources that carry Project = var.project, and every resource that it
# creates must carry that tag. The policy grants no IAM, S3, or other service,
# so the user cannot escalate its own privileges. It also holds no
# iam:PassRole, so it cannot launch an instance with an instance profile.
#
# RunInstances authorizes one ARN for each resource in the request: instance,
# volume, network-interface, security-group, subnet, image, key-pair, and
# launch-template. Each resource type supports different condition keys, and
# a condition key that does not apply to a resource type is absent for it,
# which makes a plain StringEquals fail. So each RunInstances statement below
# covers only the resource types that support its condition keys.
#
# Condition keys come from the Service Authorization Reference for EC2:
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html

locals {
  # ARN prefix for the EC2 resources of this account and region. Image ARNs
  # have no account field, so they do not use this prefix.
  ec2 = "arn:aws:ec2:${var.region}:${var.account_id}"

  launch_templates = "${local.ec2}:launch-template/*"

  # ec2:LaunchTemplate is present on every resource type of a RunInstances
  # request that uses a launch template, and absent when the request uses no
  # launch template. Each RunInstances statement (except the one for the
  # launch template itself) requires it, so a request without a launch
  # template matches no statement.
  uses_launch_template = { "ec2:LaunchTemplate" = local.launch_templates }

  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only. Most Describe actions do not support resource-level
        # permissions, so the resource is "*". The AWS provider calls many of
        # them (DescribeVpcs, DescribeSecurityGroupRules,
        # DescribeLaunchTemplateVersions) and the harness calls
        # DescribeInstances. Get* adds GetConsoleOutput for boot debugging.
        Sid      = "Read"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:Get*"]
        Resource = "*"
      },
      {
        # The instance. aws:RequestTag/Project requires the request to tag
        # the instance with the project. The Null test requires an ExpiresAt
        # tag, which the TTL guard on the box reads. ec2:InstanceType limits
        # the families:
        # "c7i.*" matches c7i.xlarge and c7i.metal-48xl, but not
        # c7i-flex.large or c7gn.xlarge, because the family name must end at
        # the dot. ec2:Tenancy blocks dedicated tenancy, which costs extra.
        # IfExists: the key can be absent when the request does not set it.
        Sid      = "RunInstancesInstance"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:instance/*"
        Condition = {
          StringEquals         = { "aws:RequestTag/Project" = var.project }
          Null                 = { "aws:RequestTag/ExpiresAt" = "false" }
          StringLike           = { "ec2:InstanceType" = [for family in var.instance_families : "${family}.*"] }
          ArnLike              = local.uses_launch_template
          StringEqualsIfExists = { "ec2:Tenancy" = "default" }
        }
      },
      {
        # The EBS volumes. They must carry the project tag too. The type and
        # size limits stop a request that overrides the launch template
        # volume with a large or provisioned-IOPS volume. IfExists: the keys
        # can be absent when the volume comes from the launch template.
        Sid      = "RunInstancesVolume"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2}:volume/*"
        Condition = {
          StringEquals                  = { "aws:RequestTag/Project" = var.project }
          ArnLike                       = local.uses_launch_template
          StringEqualsIfExists          = { "ec2:VolumeType" = "gp3" }
          NumericLessThanEqualsIfExists = { "ec2:VolumeSize" = tostring(var.max_volume_gib) }
        }
      },
      {
        # The launch template. It must be one of the project templates. This
        # resource is optional in RunInstances, so this statement alone does
        # not force a launch template. uses_launch_template does that.
        Sid       = "RunInstancesLaunchTemplate"
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = local.launch_templates
        Condition = { StringEquals = { "aws:ResourceTag/Project" = var.project } }
      },
      {
        # The AMI. ec2:Owner allows only the NixOS publisher, which blocks
        # AMIs with license or Marketplace fees. ec2:IsLaunchTemplateResource
        # requires the AMI to come from the launch template, not from an
        # ImageId override in the request.
        Sid      = "RunInstancesImage"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:aws:ec2:${var.region}::image/*"
        Condition = {
          StringEquals = { "ec2:Owner" = var.image_owners }
          Bool         = { "ec2:IsLaunchTemplateResource" = "true" }
          ArnLike      = local.uses_launch_template
        }
      },
      {
        # The security group and the key pair. They must be project
        # resources, and they must come from the launch template.
        Sid    = "RunInstancesProjectResources"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "${local.ec2}:security-group/*",
          "${local.ec2}:key-pair/*",
        ]
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.project }
          Bool         = { "ec2:IsLaunchTemplateResource" = "true" }
          ArnLike      = local.uses_launch_template
        }
      },
      {
        # The subnet and the new network interface. The launch template sets
        # no subnet, so EC2 selects a default subnet, and
        # ec2:IsLaunchTemplateResource would be false. The security group
        # statement above already keeps the instance in the default VPC,
        # because a security group works only in its own VPC.
        Sid    = "RunInstancesNetwork"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "${local.ec2}:subnet/*",
          "${local.ec2}:network-interface/*",
        ]
        Condition = { ArnLike = local.uses_launch_template }
      },
      {
        # Tags in a create request. EC2 authorizes ec2:CreateTags for each
        # resource that a create action tags, with ec2:CreateAction set to
        # the create action. Without this statement, RunInstances with
        # TagSpecifications (or with tags from the launch template) fails,
        # and so do the the bench-base module creates, because the provider sends
        # default_tags in the create request. A Project tag, if present,
        # must have the project value.
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2}:*/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateSecurityGroup",
              "ImportKeyPair",
              "CreateLaunchTemplate",
            ]
          }
          StringEqualsIfExists = { "aws:RequestTag/Project" = var.project }
        }
      },
      {
        # Tags on existing project resources: `bench extend` rewrites
        # ExpiresAt, and tofu updates tags. The resource must already carry
        # the project tag, so the user cannot pull a foreign resource into
        # the boundary. The request cannot change the Project value.
        Sid      = "TagProjectResources"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2}:*/*"
        Condition = {
          StringEquals         = { "aws:ResourceTag/Project" = var.project }
          StringEqualsIfExists = { "aws:RequestTag/Project" = var.project }
        }
      },
      {
        # Tag removal on project resources, for tofu tag updates. The request
        # must name its tag keys (DeleteTags without keys deletes all tags),
        # and Project and ExpiresAt are not among them. So a resource cannot
        # leave the boundary, and an instance keeps its TTL.
        Sid      = "UntagProjectResources"
        Effect   = "Allow"
        Action   = "ec2:DeleteTags"
        Resource = "${local.ec2}:*/*"
        Condition = {
          StringEquals                   = { "aws:ResourceTag/Project" = var.project }
          "ForAllValues:StringNotEquals" = { "aws:TagKeys" = ["Project", "ExpiresAt"] }
          Null                           = { "aws:TagKeys" = "false" }
        }
      },
      {
        # Instance lifecycle for the harness: down, reap.
        Sid    = "InstanceLifecycle"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:StopInstances",
          "ec2:StartInstances",
        ]
        Resource  = "${local.ec2}:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/Project" = var.project } }
      },
      {
        # the bench-base module creates: the security group, the key pair, and the
        # launch templates. Each create request must tag the new resource
        # with the project. The key comes from tls_private_key, so the
        # provider uses ImportKeyPair, not CreateKeyPair.
        Sid    = "CreateBaseResources"
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:ImportKeyPair",
          "ec2:CreateLaunchTemplate",
        ]
        Resource = [
          "${local.ec2}:security-group/*",
          "${local.ec2}:key-pair/*",
          local.launch_templates,
        ]
        Condition = { StringEquals = { "aws:RequestTag/Project" = var.project } }
      },
      {
        # CreateSecurityGroup also authorizes the VPC. The VPC has no project
        # tag, so this statement names the default VPC by ARN.
        Sid      = "CreateSecurityGroupInDefaultVpc"
        Effect   = "Allow"
        Action   = "ec2:CreateSecurityGroup"
        Resource = "${local.ec2}:vpc/${data.aws_vpc.default.id}"
      },
      {
        # the bench-base module updates and deletes, on project resources only. The
        # provider revokes the default egress rule of a new security group
        # and then authorizes the rules of the configuration. A launch
        # template change creates a version and makes it the default.
        Sid    = "ManageBaseResources"
        Effect = "Allow"
        Action = [
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          "ec2:DeleteKeyPair",
          "ec2:CreateLaunchTemplateVersion",
          "ec2:ModifyLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
        ]
        Resource = [
          "${local.ec2}:security-group/*",
          "${local.ec2}:key-pair/*",
          local.launch_templates,
        ]
        Condition = { StringEquals = { "aws:ResourceTag/Project" = var.project } }
      },
      {
        # Authorize* can also authorize the new security-group-rule
        # resource. A new rule has no tags yet, so it cannot match a tag
        # condition. This statement grants nothing alone: the same request
        # also authorizes the parent security group, which
        # ManageBaseResources limits to project groups.
        Sid    = "SecurityGroupRules"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
        ]
        Resource = "${local.ec2}:security-group-rule/*"
      },
      {
        # Deny every action outside the fleet region. This catches the
        # Describe and Get actions, which have no region in their resource.
        # sts:GetCallerIdentity is global, and AWS allows it even with an
        # explicit deny. The exception makes that visible here.
        Sid       = "DenyOtherRegions"
        Effect    = "Deny"
        NotAction = ["sts:GetCallerIdentity"]
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
      },
    ]
  }
}
