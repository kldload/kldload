#!/usr/bin/env bash
# deploy_aws.sh
#
# Deploy OR destroy a Free Tier EC2 micro instance with strong defaults.
# - Creates/reuses a minimal Security Group
# - Requires IMDSv2
# - Amazon Linux 2023 (x86_64 or arm64) via SSM public params
# - Optionally SSHes in once the instance is running
# - Persists a small state file to cleanly destroy later
#
# Usage:
#   # Deploy (default):
#   ./deploy_aws.sh
#
#   # Deploy with options:
#   AWS_PROFILE=myprof AWS_REGION=us-west-2 INSTANCE_NAME=my-micro ./deploy_micro_ec2.sh
#
#   # Destroy what this script created last time:
#   ./deploy_aws.sh destroy
#
# Credentials:
#   Use env (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN), or AWS_PROFILE, or default chain.
# REQUIRES AWS commandline tool

set -euo pipefail

### ===================== User-tunable variables =====================
AWS_REGION="${AWS_REGION:-ca-central-1}"
AWS_PROFILE="${AWS_PROFILE:-}"                         # optional
INSTANCE_NAME="${INSTANCE_NAME:-my-micro}"

# Instance size & arch (Free Tier examples: t2.micro, t3.micro, t4g.micro for arm64)
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
ARCH="${ARCH:-x86_64}"                                 # x86_64 | arm64
OS_IMAGE="${OS_IMAGE:-al2023}"                         # only 'al2023' implemented
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-8}"		               # /root size
KMS_KEY_ID="${KMS_KEY_ID:-}"                           # optional CMK for EBS; else account default

# Networking
SUBNET_ID="${SUBNET_ID:-}"                             # if empty, uses default VPC's first subnet
ASSOC_PUBLIC_IP="${ASSOC_PUBLIC_IP:-auto}"             # auto|true|false (auto honors subnet default)
SG_NAME="${SG_NAME:-${INSTANCE_NAME}-sg}"              # apply security group
ENABLE_SSH="${ENABLE_SSH:-true}"                       # open 22 from your /32
OPEN_HTTP="${OPEN_HTTP:-false}"                        # open port 80
OPEN_HTTPS="${OPEN_HTTPS:-false}"                      # open port 443
SSH_CIDR="${SSH_CIDR:-}"                               # override your /32 (e.g., 203.0.113.7/32)

# Keys
KEY_NAME="${KEY_NAME:-${INSTANCE_NAME}-key}"           # name in EC2
PUBLIC_KEY_PATH="${PUBLIC_KEY_PATH:-}"                 # import an existing public key (recommended)
SAVE_GENERATED_KEY_TO="${SAVE_GENERATED_KEY_TO:-${KEY_NAME}.pem}"  # if script creates a new key pair
SSH_KEY_PATH="${SSH_KEY_PATH:-}"                       # private key to actually SSH with (optional)

# Auto-SSH into the box after it boots?
AUTO_SSH="${AUTO_SSH:-true}"                           # auto ssh
SSH_USER="${SSH_USER:-ec2-user}"                       # user

# Extra tags (comma-separated "K=V,K=V")
EXTRA_TAGS="${EXTRA_TAGS:-}"                           # e.g., "Owner=anthony,Env=dev"

# State file (so we can destroy later cleanly)
STATE_FILE="${STATE_FILE:-.${INSTANCE_NAME}.state}"

DEBUG="${DEBUG:-0}"                                    # 1 for bash -x
### ==================================================================

if [[ "$DEBUG" == "1" ]]; then set -x; fi

say() { printf '>> %s\n' "$*" >&2; }
err() { printf '!! %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
trap 'err "Script failed at line $LINENO"; exit 1' ERR

aws_cli() {
  if [[ -n "$AWS_PROFILE" ]]; then
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

require_tools() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found."
  command -v curl >/dev/null 2>&1 || say "curl not found; IP autodetect may fail (set SSH_CIDR)."
}

check_identity() {
  say "Checking AWS identity & region ..."
  aws_cli sts get-caller-identity >/dev/null || die "Cannot call STS. Check credentials/profile."
  say "Using region: $AWS_REGION"
}

get_default_vpc() {
  aws_cli ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text
}

pick_default_subnet() {
  local vpc_id="$1"
  aws_cli ec2 describe-subnets --filters Name=vpc-id,Values="$vpc_id" \
    --query 'Subnets[0].SubnetId' --output text
}

subnet_map_public() {
  local subnet_id="$1"
  aws_cli ec2 describe-subnets --subnet-ids "$subnet_id" \
    --query 'Subnets[0].MapPublicIpOnLaunch' --output text 2>/dev/null || echo "False"
}

ensure_sg() {
  local vpc_id="$1"
  local sg_id
  sg_id=$(aws_cli ec2 describe-security-groups \
      --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$vpc_id" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

  if [[ "$sg_id" == "None" || -z "$sg_id" ]]; then
    say "Creating security group: $SG_NAME in $vpc_id"
    sg_id=$(aws_cli ec2 create-security-group --vpc-id "$vpc_id" \
      --group-name "$SG_NAME" --description "Minimal SG for $INSTANCE_NAME" \
      --query 'GroupId' --output text)
    aws_cli ec2 create-tags --resources "$sg_id" --tags Key=Name,Value="$SG_NAME"
    echo -n "$sg_id,CREATED"
  else
    say "Reusing security group: $sg_id"
    echo -n "$sg_id,EXISTING"
  fi
}

my_ip_cidr() {
  if [[ -n "$SSH_CIDR" ]]; then
    echo "$SSH_CIDR"
    return
  fi
  local ip
  ip=$(curl -fsSL https://checkip.amazonaws.com || true)
  ip=${ip//$'\n'/}
  [[ -n "$ip" ]] && echo "${ip}/32" || echo ""
}

ensure_ingress_rule() {
  local sg_id="$1" port="$2" cidr="$3"
  [[ -z "$cidr" ]] && { err "No CIDR for port $port; skipping ingress."; return 0; }
  say "Authorizing inbound tcp/$port from $cidr on $sg_id"
  aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=\"$cidr\"}]" \
  || say "Ingress add failed (already exists or denied by policy)."
}

ensure_keypair() {
  if [[ -n "$PUBLIC_KEY_PATH" ]]; then
    [[ -r "$PUBLIC_KEY_PATH" ]] || die "PUBLIC_KEY_PATH '$PUBLIC_KEY_PATH' not readable."
    local exists
    exists=$(aws_cli ec2 describe-key-pairs --key-names "$KEY_NAME" \
              --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
    if [[ "$exists" == "$KEY_NAME" ]]; then
      say "Key pair '$KEY_NAME' exists; reusing."
      echo -n ",EXISTING,"
    else
      say "Importing public key as EC2 key pair: $KEY_NAME"
      aws_cli ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://$PUBLIC_KEY_PATH" >/dev/null
      echo -n ",CREATED,"
    fi
    echo -n ""   # no PEM path to return
  else
    local exists
    exists=$(aws_cli ec2 describe-key-pairs --key-names "$KEY_NAME" \
              --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
    if [[ "$exists" == "$KEY_NAME" ]]; then
      say "Key pair '$KEY_NAME' exists; reusing (no PEM export possible)."
      echo -n ",EXISTING,"
      echo -n ""
    else
      say "Creating new EC2 key pair: $KEY_NAME (saving PEM locally)"
      aws_cli ec2 create-key-pair --key-name "$KEY_NAME" \
        --key-type rsa --key-format pem \
        --query 'KeyMaterial' --output text > "$SAVE_GENERATED_KEY_TO"
      chmod 600 "$SAVE_GENERATED_KEY_TO"
      say "Saved private key: $SAVE_GENERATED_KEY_TO"
      echo -n ",CREATED,"
      echo -n "$SAVE_GENERATED_KEY_TO"
    fi
  fi
}

resolve_ami() {
  local param_path
  if [[ "$OS_IMAGE" == "al2023" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      param_path="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
    else
      param_path="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
    fi
  else
    die "Unsupported OS_IMAGE '$OS_IMAGE' (only 'al2023')."
  fi
  aws_cli ssm get-parameter --name "$param_path" --query 'Parameter.Value' --output text
}

build_tagspec_shorthand() {
  # Return CLI shorthand: ResourceType=instance,Tags=[{Key=Name,Value=...},{Key=K,Value=V},...]
  local items="{Key=Name,Value=${INSTANCE_NAME}}"
  if [[ -n "$EXTRA_TAGS" ]]; then
    IFS=',' read -r -a kvs <<< "$EXTRA_TAGS"
    for kv in "${kvs[@]}"; do
      local k="${kv%%=*}"; local v="${kv#*=}"
      [[ -n "$k" && -n "$v" ]] && items="${items},{Key=${k},Value=${v}}"
    done
  fi
  echo "ResourceType=instance,Tags=[${items}]"
}

launch_instance() {
  local ami_id="$1" sg_id="$2" subnet_id="$3" associate="$4" key_name="$5"
  local bdm kms_json
  if [[ -n "$KMS_KEY_ID" ]]; then
    kms_json="\"Encrypted\":true,\"KmsKeyId\":\"${KMS_KEY_ID}\""
  else
    kms_json="\"Encrypted\":true"
  fi
  bdm="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE_GB},\"VolumeType\":\"gp3\",${kms_json}}}]"

  local network_json
  if [[ "$associate" == "true" ]]; then
    network_json="[{\"DeviceIndex\":0,\"SubnetId\":\"${subnet_id}\",\"Groups\":[\"${sg_id}\"],\"AssociatePublicIpAddress\":true}]"
  elif [[ "$associate" == "false" ]]; then
    network_json="[{\"DeviceIndex\":0,\"SubnetId\":\"${subnet_id}\",\"Groups\":[\"${sg_id}\"],\"AssociatePublicIpAddress\":false}]"
  else
    network_json="[{\"DeviceIndex\":0,\"SubnetId\":\"${subnet_id}\",\"Groups\":[\"${sg_id}\"]}]"
  fi

  read -r -d '' USERDATA <<'EOF'
#!/bin/bash
set -euo pipefail
dnf -y update || true
# Example:
# dnf -y install nginx && systemctl enable --now nginx
EOF

  local tags
  tags="$(build_tagspec_shorthand)"

  say "Launching EC2 instance: ${INSTANCE_NAME} (${INSTANCE_TYPE}) ..."
  local instance_id
  instance_id=$(aws_cli ec2 run-instances \
    --image-id "$ami_id" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$key_name" \
    --block-device-mappings "$bdm" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "$tags" \
    --network-interfaces "$network_json" \
    --user-data "$USERDATA" \
    --query 'Instances[0].InstanceId' --output text)

  [[ -n "$instance_id" && "$instance_id" != "None" ]] || die "run-instances did not return an InstanceId."
  say "Instance ID: $instance_id"
  aws_cli ec2 wait instance-running --instance-ids "$instance_id"
  echo -n "$instance_id"
}

describe_ips() {
  local iid="$1"
  local pub_ip pub_dns priv_ip
  pub_ip=$(aws_cli ec2 describe-instances --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  pub_dns=$(aws_cli ec2 describe-instances --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
  priv_ip=$(aws_cli ec2 describe-instances --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  printf '%s;%s;%s\n' "${pub_ip:-<none>}" "${pub_dns:-<none>}" "${priv_ip:-<none>}"
}

wait_for_public_ip() {
  local iid="$1" tries=30
  for _ in $(seq 1 "$tries"); do
    local ip
    ip=$(aws_cli ec2 describe-instances --instance-ids "$iid" \
           --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    if [[ -n "$ip" && "$ip" != "None" ]]; then
      echo -n "$ip"; return 0
    fi
    sleep 2
  done
  echo -n "<none>"
}

infer_private_key_from_pub() {
  local pub="$1"
  if [[ -z "$pub" ]]; then echo ""; return 0; fi
  if [[ "${pub##*.}" == "pub" ]]; then
    local guess="${pub%.*}"
    [[ -r "$guess" ]] && { echo "$guess"; return 0; }
  fi
  echo ""
}

write_state() {
  local f="$STATE_FILE"
  : > "$f"
  {
    echo "AWS_REGION=$AWS_REGION"
    [[ -n "$AWS_PROFILE" ]] && echo "AWS_PROFILE=$AWS_PROFILE"
    echo "INSTANCE_ID=$1"
    echo "SG_ID=$2"
    echo "SUBNET_ID=$3"
    echo "KEY_NAME=$4"
    echo "PEM_PATH=$5"
    echo "CREATED_SG=$6"
    echo "CREATED_KEY=$7"
  } >> "$f"
  say "State written to $f"
}

destroy_from_state() {
  [[ -r "$STATE_FILE" ]] || die "No state file found ($STATE_FILE)."
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  say "Destroying instance: ${INSTANCE_ID}"
  aws_cli ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws_cli ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
  say "Instance terminated."

  if [[ "${CREATED_SG:-}" == "CREATED" ]]; then
    say "Deleting security group: ${SG_ID}"
    aws_cli ec2 delete-security-group --group-id "$SG_ID" >/dev/null || say "SG delete failed (in use?)."
  fi

  if [[ "${CREATED_KEY:-}" == "CREATED" ]]; then
    say "Deleting key pair: ${KEY_NAME}"
    aws_cli ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null || say "Key delete failed."
    [[ -n "${PEM_PATH:-}" && -f "${PEM_PATH:-}" ]] && rm -f "${PEM_PATH:?}" || true
  fi

  rm -f "$STATE_FILE"
  say "Destroyed and cleaned up."
}

main_deploy() {
  require_tools
  check_identity

  local vpc_id subnet_id
  vpc_id=$(get_default_vpc)
  [[ "$vpc_id" == "None" || -z "$vpc_id" ]] && die "No default VPC in $AWS_REGION."
  say "Default VPC: $vpc_id"

  if [[ -z "$SUBNET_ID" ]]; then
    subnet_id=$(pick_default_subnet "$vpc_id")
    [[ "$subnet_id" == "None" || -z "$subnet_id" ]] && die "No subnet found in default VPC."
    say "Using subnet: $subnet_id"
  else
    subnet_id="$SUBNET_ID"
    say "Using provided subnet: $subnet_id"
  fi

  # Security group
  local sg_out sg_id sg_flag
  sg_out=$(ensure_sg "$vpc_id")
  sg_id="${sg_out%,*}"
  sg_flag="${sg_out#*,}"          # CREATED or EXISTING
  say "Using security group: $sg_id"
  [[ -z "$sg_id" || "$sg_id" == "None" ]] && die "SG_ID is empty; aborting."

  # Ingress rules from your IP
  local cidr
  cidr="$(my_ip_cidr)"
  if [[ "$ENABLE_SSH" == "true" ]]; then
    if [[ -n "$cidr" ]]; then ensure_ingress_rule "$sg_id" 22 "$cidr"; else err "Could not detect your IP; SSH rule skipped."; fi
  fi
  [[ "$OPEN_HTTP" == "true"  && -n "$cidr" ]] && ensure_ingress_rule "$sg_id" 80  "$cidr"
  [[ "$OPEN_HTTPS" == "true" && -n "$cidr" ]] && ensure_ingress_rule "$sg_id" 443 "$cidr"

  # Key pair
  local key_flag pem_path
  key_flag=$(ensure_keypair)      # prints ",FLAG," then PEM (if created)
  # parse ",FLAG,PEM"
  key_flag="${key_flag#,}"; key_flag="${key_flag%%,*}"
  pem_path="${key_flag#*,}"       # not reliable; better:
  # Recompute PEM path from output by calling ensure_keypair twice is messy; instead infer:
  if [[ -z "$PUBLIC_KEY_PATH" && -f "$SAVE_GENERATED_KEY_TO" ]]; then
    pem_path="$SAVE_GENERATED_KEY_TO"
  else
    pem_path="${SSH_KEY_PATH:-$(infer_private_key_from_pub "$PUBLIC_KEY_PATH")}"
  fi

  # AMI
  local ami_id
  ami_id=$(resolve_ami)
  say "Using AMI: $ami_id (ARCH=$ARCH, OS_IMAGE=$OS_IMAGE)"

  # Public IP decision
  local map_pub assoc="$ASSOC_PUBLIC_IP"
  if [[ "$ASSOC_PUBLIC_IP" == "auto" ]]; then
    map_pub="$(subnet_map_public "$subnet_id")"
    say "Subnet MapPublicIpOnLaunch=${map_pub}"
    # If you asked for SSH but subnet doesn't auto-assign, enable association to make SSH work
    if [[ "$ENABLE_SSH" == "true" && "${map_pub,,}" != "true" ]]; then
      assoc="true"
    fi
  fi

  # Launch
  local iid
  iid=$(launch_instance "$ami_id" "$sg_id" "$subnet_id" "$assoc" "$KEY_NAME")

  # Describe IPs
  local public_ip public_dns private_ip
  public_ip="$(wait_for_public_ip "$iid")"
  IFS=';' read -r _ public_dns private_ip <<<"$(describe_ips "$iid")"

  say "Launched: $iid"
  say "Public IP:   $public_ip"
  say "Public DNS:  $public_dns"
  say "Private IP:  $private_ip"

  # Persist state for later destroy
  write_state "$iid" "$sg_id" "$subnet_id" "$KEY_NAME" "${pem_path:-}" "$sg_flag" "${key_flag:-EXISTING}"

  # Auto SSH
  if [[ "$AUTO_SSH" == "true" ]]; then
    if [[ "$public_ip" != "<none>" ]]; then
      local key_to_use=""
      if [[ -n "$SSH_KEY_PATH" && -r "$SSH_KEY_PATH" ]]; then
        key_to_use="$SSH_KEY_PATH"
      elif [[ -n "$pem_path" && -r "$pem_path" ]]; then
        key_to_use="$pem_path"
      else
        # last resort: try without -i (works if your agent has the key)
        say "No private key path found; attempting SSH via agent..."
      fi
      sleep 5

      say "Opening SSH session (user=$SSH_USER) ..."
      if [[ -n "$key_to_use" ]]; then
        exec ssh -o StrictHostKeyChecking=accept-new -i "$key_to_use" "${SSH_USER}@${public_ip}"
      else
        exec ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${public_ip}"
      fi
    else
      say "No public IP; skipping SSH. Use SSM instead:"
      say "aws ssm start-session --target ${iid} --region ${AWS_REGION} ${AWS_PROFILE:+--profile ${AWS_PROFILE}}"
    fi
  else
    echo "INSTANCE_ID=${iid} SG_ID=${sg_id} SUBNET_ID=${subnet_id} PUBLIC_IP=${public_ip} PRIVATE_IP=${private_ip}"
  fi
}

main_destroy() {
  require_tools
  check_identity
  destroy_from_state
}

# ---------------------------- Entry ----------------------------
ACTION="${1:-deploy}"
case "$ACTION" in
  deploy)  main_deploy ;;
  destroy) main_destroy ;;
  *) die "Unknown action '$ACTION'. Use: ./deploy_micro_ec2.sh [deploy|destroy]" ;;
esac
