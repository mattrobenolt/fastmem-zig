#!/usr/bin/env bash
# Write the bench credentials profile from the infra/iam outputs.
#
# Run after the human applies infra/iam:
#
#   infra/iam/write-credentials.sh
#
# The profile name is the IAM user name (tofu output "profile"). The script
# replaces an existing section with the same name in the shared credentials
# file and keeps all other sections. It also sets the region in the shared
# config file. It honors AWS_SHARED_CREDENTIALS_FILE and AWS_CONFIG_FILE.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

output() {
  tofu -chdir="${here}" output -raw "$1"
}

profile="$(output profile)"
key_id="$(output access_key_id)"
secret="$(output secret_access_key)"
region="$(output region)"

creds="${AWS_SHARED_CREDENTIALS_FILE:-${HOME}/.aws/credentials}"

# Every file that this script creates holds or sits next to the secret.
umask 077
mkdir -p "$(dirname "${creds}")"
touch "${creds}"

tmp="$(mktemp "${creds}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT

# Copy every section except [profile]. A section ends at the next header.
awk -v section="[${profile}]" '
  { line = $0; gsub(/[ \t\r]/, "", line) }
  line == section { skip = 1; next }
  /^[ \t]*\[/ { skip = 0 }
  !skip { print }
' "${creds}" >"${tmp}"

# Start the new section on its own line.
if [[ -s "${tmp}" && -n "$(tail -c 1 "${tmp}")" ]]; then
  echo >>"${tmp}"
fi

printf '[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
  "${profile}" "${key_id}" "${secret}" >>"${tmp}"

chmod 600 "${tmp}"
mv "${tmp}" "${creds}"
trap - EXIT

# The region is not a secret. The AWS CLI writes it to the shared config file.
# The harness and infra/base set the region themselves, so a failure here
# (for example, a read-only config file) is not fatal.
if ! aws configure set region "${region}" --profile "${profile}"; then
  echo "warning: could not set the region for [${profile}] in the config file" >&2
fi

echo "wrote [${profile}] to ${creds}"
echo "a new key can take about 10 seconds to become valid"
echo "verify: AWS_PROFILE=${profile} aws sts get-caller-identity"
