#!/bin/bash
# Cloud provider helper functions (AWS-specific)

cloud_put_secret() {
    local key="$1"
    local value="$2"
    local region="$3"
    local description="${4:-}"

    local cmd="aws ssm put-parameter \
        --region \"$region\" \
        --name \"$key\" \
        --type SecureString \
        --value \"$value\""

    if [ -n "$description" ]; then
        cmd="$cmd --description \"$description\""
    fi

    eval "$cmd"
}

cloud_update_secret() {
    local key="$1"
    local value="$2"
    local region="$3"

    aws ssm put-parameter \
        --region "$region" \
        --name "$key" \
        --type SecureString \
        --value "$value" \
        --overwrite
}

cloud_get_secret() {
    local key="$1"
    local region="$2"

    aws ssm get-parameter \
        --region "$region" \
        --name "$key" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null
}
